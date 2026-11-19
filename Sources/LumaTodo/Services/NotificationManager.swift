import AppKit
import Observation
@preconcurrency import UserNotifications

struct NoticeAction: Sendable {
    let action: String
    let taskID: UUID
    let scheduleID: UUID
    let occurrence: Date
    let requestID: String
    let independentReminderID: UUID?

    init?(request: UNNotificationRequest, action: String = "") {
        let info = request.content.userInfo
        guard let task = info["task"] as? String, let taskID = UUID(uuidString: task),
              let version = info["version"] as? String, let scheduleID = UUID(uuidString: version),
              let occurrence = info["occurrence"] as? Double else { return nil }
        self.action = action
        self.taskID = taskID
        self.scheduleID = scheduleID
        self.occurrence = Date(timeIntervalSince1970: occurrence)
        requestID = request.identifier
        independentReminderID = (info["independentReminder"] as? String).flatMap(UUID.init(uuidString:))
    }

    var deliveryKey: ReminderDeliveryKey { ReminderDeliveryKey(id: requestID, version: scheduleID) }
}

struct PendingTaskReminders: Equatable {
    let version: UUID
    var count = 0
    var next: Date?
    var late = 0

    mutating func include(fire: Date, now: Date) {
        count += 1
        if fire > now { next = min(next ?? fire, fire) }
        else { late += 1 }
    }
}

struct ReminderQueueStatus: Equatable {
    var pending: [UUID: PendingTaskReminders] = [:]
    var deferred: Set<UUID> = []
    var failures: Set<UUID> = []
    var lastCheck: Date?
    var pendingCount = 0
    var next: Date?
}

enum TestReminderStatus: Equatable {
    case submitting
    case submitted(Date)
    case interacted(Date)
}

@MainActor @Observable
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let complete = "lumatodo.complete"
    nonisolated static let view = "lumatodo.view"
    nonisolated static let snooze = "lumatodo.snooze"
    nonisolated static let testID = "lumatodo.test"
    nonisolated static let confirmTest = "lumatodo.test.confirm"
    static let notificationLimit = 60

    private(set) var authorization: UNAuthorizationStatus?
    private(set) var alertsEnabled = true
    private(set) var queue = ReminderQueueStatus()
    private(set) var refillAfter: Date?
    private(set) var isSyncing = false
    private(set) var testStatus: TestReminderStatus?
    @ObservationIgnored var onAction: ((NoticeAction) -> Void)?
    @ObservationIgnored var onTestInteraction: (() -> Void)?
    @ObservationIgnored var onQueueChange: (() -> Void)?
    @ObservationIgnored private let center: UNUserNotificationCenter
    @ObservationIgnored private let store: TaskStore
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var synchronization: Task<Void, Never>?
    @ObservationIgnored private var requestingPermission = false
    @ObservationIgnored private var delivered: [ReminderDeliveryKey] = []

    init(store: TaskStore, preferences: Preferences) {
        center = .current()
        self.store = store
        self.preferences = preferences
        super.init()
        if let data = preferences.defaults.data(forKey: "reminders.recently-delivered") {
            delivered = (try? JSONDecoder().decode([ReminderDeliveryKey].self, from: data)) ?? []
        }
        if let date = preferences.defaults.object(forKey: "reminders.test.interacted") as? Date {
            testStatus = .interacted(date)
        } else if let date = preferences.defaults.object(forKey: "reminders.test.submitted") as? Date {
            testStatus = .submitted(date)
        }
        center.delegate = self
        registerCategories()
    }

    var authorized: Bool {
        switch authorization {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    var failures: Set<UUID> { queue.failures }

    func permissionLabel(_ words: Words) -> String {
        switch authorization {
        case nil: words("查询中", "Checking")
        case .notDetermined: words("尚未请求", "Not requested")
        case .denied: words("未允许", "Denied")
        default: alertsEnabled ? words("通知提示已启用", "Alerts enabled") : words("桌面通知提示已关闭", "Desktop alerts disabled")
        }
    }

    func pending(for task: TaskItem) -> PendingTaskReminders? {
        guard let status = queue.pending[task.id], status.version == task.scheduleID, !task.isCompleted else { return nil }
        return status
    }

    func registerCategories() {
        let words = preferences.words
        let complete = UNNotificationAction(identifier: Self.complete, title: words("完成", "Complete"))
        let view = UNNotificationAction(identifier: Self.view, title: words("查看任务", "View task"), options: [.foreground])
        let snooze = UNNotificationAction(identifier: Self.snooze, title: words("稍后提醒…", "Snooze…"),
                                          options: [.foreground])
        let tasks = UNNotificationCategory(identifier: Self.view, actions: [complete, snooze, view],
                                           intentIdentifiers: [], options: [])
        let confirm = UNNotificationAction(identifier: Self.confirmTest, title: words("确认收到", "Confirm receipt"),
                                           options: [.foreground])
        let test = UNNotificationCategory(identifier: Self.testID, actions: [confirm], intentIdentifiers: [], options: [])
        center.setNotificationCategories([tasks, test])
    }

    func requestPermission() async throws {
        guard !requestingPermission else { return }
        requestingPermission = true
        defer { requestingPermission = false }
        await refreshPermission()
        if authorization == .notDetermined {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        await refreshPermission()
        reconcile()
    }

    private func refreshPermission() async {
        let settings = await center.notificationSettings()
        if authorization != settings.authorizationStatus { authorization = settings.authorizationStatus }
        let enabled = settings.alertSetting == .enabled
        if alertsEnabled != enabled { alertsEnabled = enabled }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func testNotification() async throws {
        guard testStatus != .submitting else { return }
        let previousStatus = testStatus
        testStatus = .submitting
        let defaults = preferences.defaults
        do {
            try await requestPermission()
            guard authorized else { throw NoticeError.unavailable }
            let words = preferences.words
            let token = UUID().uuidString
            let content = UNMutableNotificationContent()
            content.title = words("LumaTodo 测试提醒", "LumaTodo test reminder")
            content.body = words("点击此通知或选择「确认收到」。", "Click this notification or choose Confirm Receipt.")
            content.categoryIdentifier = Self.testID
            content.userInfo = ["testToken": token]
            if preferences.values.sound { content.sound = .default }
            try await center.add(UNNotificationRequest(identifier: Self.testID, content: content,
                                                       trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
            let requests = await center.pendingNotificationRequests()
            guard requests.contains(where: {
                $0.identifier == Self.testID && $0.content.userInfo["testToken"] as? String == token
            }) else { throw NoticeError.notConfirmed }
            let now = Date.now
            defaults.set(token, forKey: "reminders.test.token")
            defaults.set(now, forKey: "reminders.test.submitted")
            defaults.removeObject(forKey: "reminders.test.interacted")
            testStatus = .submitted(now)
        } catch {
            testStatus = previousStatus
            throw error
        }
    }

    func reconcile() {
        dirty = true
        guard synchronization == nil else { return }
        isSyncing = true
        synchronization = Task { [weak self] in
            guard let self else { return }
            while dirty {
                dirty = false
                await synchronize()
            }
            synchronization = nil
            isSyncing = false
            onQueueChange?()
        }
    }

    func finishPendingSynchronization() async {
        await synchronization?.value
    }

    private func synchronize() async {
        await refreshPermission()
        guard !dirty else { return }
        let pending = await center.pendingNotificationRequests()
        let posted = await center.deliveredNotifications()
        guard !dirty else { return }
        recordDeliveries(posted.sorted { $0.date < $1.date }.compactMap { NoticeAction(request: $0.request)?.deliveryKey })
        cleanDelivered(posted)
        let managed = pending.filter { $0.identifier.hasPrefix(NotificationEvent.prefix) }
        let now = Date.now
        guard authorized else {
            if !managed.isEmpty { center.removePendingNotificationRequests(withIdentifiers: managed.map(\.identifier)) }
            queue = ReminderQueueStatus(lastCheck: now)
            refillAfter = nil
            return
        }

        let recent = Set(delivered)
        // A request that became due during sleep may still belong to the system's delivery pipeline.
        let late = managed.compactMap { request -> QueuedReminder? in
            guard let entry = QueuedReminder(request), LateReminder.shouldKeep(
                fire: entry.fire, now: now, current: isCurrent(entry.notice), alreadyDelivered: recent.contains(entry.notice.deliveryKey)
            ) else { return nil }
            return entry
        }.sorted { $0.fire < $1.fire }.prefix(Self.notificationLimit)
        let plan = NotificationPlan.make(tasks: store.items, now: now,
                                         limit: max(0, Self.notificationLimit - late.count), delivered: recent)
        let desired = plan.events.map(request(for:))
        let desiredFingerprints = Dictionary(desired.map { ($0.identifier, fingerprint($0)) }, uniquingKeysWith: { left, _ in left })
        let priorFingerprints = Dictionary(managed.map { ($0.identifier, fingerprint($0)) }, uniquingKeysWith: { left, _ in left })
        let lateIDs = Set(late.map { $0.notice.requestID })
        let diff = ReminderQueueDiff(existing: priorFingerprints, desired: desiredFingerprints, preserving: lateIDs)
        if !diff.remove.isEmpty { center.removePendingNotificationRequests(withIdentifiers: Array(diff.remove)) }

        var failures = Set<UUID>()
        for (event, request) in zip(plan.events, desired) where diff.submit.contains(event.id) {
            guard !dirty else { return }
            guard event.fire.roundedForNotification > .now else { continue }
            do { try await center.add(request) }
            catch {
                failures.insert(event.taskID)
                NSLog("LumaTodo notification submission failed: %@", error.localizedDescription)
            }
        }

        let verified = diff.remove.isEmpty && diff.submit.isEmpty ? managed : await center.pendingNotificationRequests()
        guard !dirty else { return }
        let checkedAt = Date.now
        var status = ReminderQueueStatus(deferred: plan.deferredTaskIDs, failures: failures, lastCheck: checkedAt)
        let accepted = verified.compactMap { request -> QueuedReminder? in
            guard let entry = QueuedReminder(request),
                  desiredFingerprints[request.identifier] == fingerprint(request) || lateIDs.contains(request.identifier) else { return nil }
            return entry
        }
        let acceptedIDs = Set(accepted.map { $0.notice.requestID })
        for event in plan.events where event.fire.roundedForNotification > checkedAt && !acceptedIDs.contains(event.id) {
            status.failures.insert(event.taskID)
        }
        for entry in accepted {
            let id = entry.notice.taskID
            status.pending[id, default: PendingTaskReminders(version: entry.notice.scheduleID)].include(fire: entry.fire, now: checkedAt)
        }
        status.pendingCount = accepted.count
        status.next = accepted.lazy.map(\.fire).filter { $0 > checkedAt }.min()
        queue = status
        refillAfter = nextRecheck(status: status, hasLateRequests: !late.isEmpty, now: checkedAt)
    }

    private func nextRecheck(status: ReminderQueueStatus, hasLateRequests: Bool, now: Date) -> Date? {
        var next = status.next?.addingTimeInterval(2)
        if hasLateRequests || !status.failures.isEmpty {
            let retry = now.addingTimeInterval(60)
            next = min(next ?? retry, retry)
        }
        if !status.deferred.isEmpty, next == nil { next = now.addingTimeInterval(60) }
        return next
    }

    private func fingerprint(_ request: UNNotificationRequest) -> String {
        request.content.userInfo["fingerprint"] as? String ?? ""
    }

    // Recheck actions at execution time because a task can change while a notification menu is open.
    func isCurrent(_ notice: NoticeAction) -> Bool {
        guard let task = store.item(notice.taskID), !task.isCompleted, task.scheduleID == notice.scheduleID else { return false }
        if let reminderID = notice.independentReminderID {
            guard task.independentReminders.contains(where: { $0.id == reminderID && $0.fire == notice.occurrence }) else {
                return false
            }
            if !notice.requestID.contains(".snooze.") {
                return notice.requestID == NotificationEvent.identifier(taskID: task.id, occurrence: notice.occurrence,
                                                                        independentReminderID: reminderID)
            }
        } else if !store.isCurrent(task, scheduleID: notice.scheduleID, occurrence: notice.occurrence) {
            return false
        }
        if notice.requestID.contains(".snooze.") {
            return task.snoozes.contains { snooze in
                snooze.occurrence == notice.occurrence && snooze.independentReminderID == notice.independentReminderID &&
                notice.requestID == NotificationEvent.identifier(taskID: task.id, occurrence: notice.occurrence, snoozeID: snooze.id)
            }
        }
        return task.leads.contains { lead in
            notice.requestID == NotificationEvent.identifier(taskID: task.id, occurrence: notice.occurrence, lead: lead)
        }
    }

    private func cleanDelivered(_ posted: [UNNotification]) {
        let obsolete = posted.compactMap { notification -> String? in
            let request = notification.request
            guard request.identifier.hasPrefix(NotificationEvent.prefix) else { return nil }
            if let notice = NoticeAction(request: request), isCurrent(notice) { return nil }
            return request.identifier
        }
        if !obsolete.isEmpty { center.removeDeliveredNotifications(withIdentifiers: obsolete) }
    }

    private func recordDeliveries(_ entries: [ReminderDeliveryKey]) {
        var known = Set(delivered)
        let additions = entries.filter { known.insert($0).inserted }
        guard !additions.isEmpty else { return }
        delivered = Array((delivered + additions).suffix(1024))
        if let data = try? JSONEncoder().encode(delivered) {
            preferences.defaults.set(data, forKey: "reminders.recently-delivered")
        }
    }

    private func request(for event: NotificationEvent) -> UNNotificationRequest {
        let words = preferences.words
        let content = UNMutableNotificationContent()
        content.title = event.title
        let due = dateLabel(event.occurrence, timed: true, words: words)
        if event.independentReminderID != nil {
            content.body = event.snoozeID == nil
                ? words("独立提醒 · \(due)", "Independent reminder · \(due)")
                : words("稍后提醒 · \(due)", "Snoozed reminder · \(due)")
        } else {
            let reason = event.lead.map { minutesLabel($0, words: words) } ?? words("稍后提醒", "Snoozed reminder")
            content.body = words("\(reason) · 截止 \(due)", "\(reason) · Due \(due)")
        }
        content.categoryIdentifier = Self.view
        content.threadIdentifier = event.taskID.uuidString
        if preferences.values.sound { content.sound = .default }
        let fire = event.fire.roundedForNotification
        let fingerprint = [event.scheduleID.uuidString, String(fire.timeIntervalSince1970), content.title, content.body,
                           content.categoryIdentifier, String(preferences.values.sound)].joined(separator: "\u{1f}")
        content.userInfo = ["task": event.taskID.uuidString, "version": event.scheduleID.uuidString,
                            "occurrence": event.occurrence.timeIntervalSince1970, "fingerprint": fingerprint,
                            "fire": fire.timeIntervalSince1970]
        if let independentID = event.independentReminderID { content.userInfo["independentReminder"] = independentID.uuidString }
        let zone = TimeZone(secondsFromGMT: 0)!
        let calendar = OccurrenceCalendar.calendar(in: zone)
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
        components.calendar = calendar
        components.timeZone = zone
        return UNNotificationRequest(identifier: event.id, content: content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }

    private func confirmTest(token: String) {
        guard token == preferences.defaults.string(forKey: "reminders.test.token") else { return }
        let now = Date.now
        preferences.defaults.set(now, forKey: "reminders.test.interacted")
        testStatus = .interacted(now)
        onTestInteraction?()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if let notice = NoticeAction(request: notification.request) {
            await MainActor.run { recordDeliveries([notice.deliveryKey]) }
        }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let request = response.notification.request
        let action = response.actionIdentifier
        if request.identifier == Self.testID {
            guard action == Self.confirmTest || action == UNNotificationDefaultActionIdentifier,
                  let token = request.content.userInfo["testToken"] as? String else { return }
            await MainActor.run { confirmTest(token: token) }
        } else if let notice = NoticeAction(request: request, action: action) {
            await MainActor.run {
                recordDeliveries([notice.deliveryKey])
                if isCurrent(notice), notice.action != UNNotificationDismissActionIdentifier { onAction?(notice) }
            }
        }
    }
}

private struct QueuedReminder {
    let notice: NoticeAction
    let fire: Date

    init?(_ request: UNNotificationRequest) {
        let info = request.content.userInfo
        guard let notice = NoticeAction(request: request) else { return nil }
        let date: Date?
        if let value = info["fire"] as? Double {
            date = Date(timeIntervalSince1970: value)
        } else if let components = (request.trigger as? UNCalendarNotificationTrigger)?.dateComponents {
            date = components.calendar?.date(from: components)
        } else {
            date = nil
        }
        guard let date else { return nil }
        self.notice = notice
        fire = date
    }
}

enum NoticeError: Error { case unavailable, notConfirmed }
