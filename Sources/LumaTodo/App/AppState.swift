import AppKit
import Observation
import ServiceManagement
import SwiftUI
import OSLog

@MainActor @Observable
final class AppState {
    let preferences: Preferences
    let store: TaskStore
    let notifications: NotificationManager
    let shortcut = GlobalShortcut()

    private(set) var mini: Bool
    var settingsTab: SettingsTab = .appearance
    var collapsedGroups: Set<TaskGroup> {
        didSet { preferences.defaults.set(collapsedGroups.map(\.rawValue).sorted(), forKey: "panel.collapsedGroups") }
    }
    var search = "" {
        didSet { if search != oldValue { updateVisibleSections() } }
    }
    var searchFocus = 0
    private(set) var listing: PanelListing
    private(set) var visibleSections: [PanelSection] = []
    private struct CompletionHold {
        let task: PanelTask
        let group: TaskGroup
        let index: Int
        let resultingID: UUID?
        let done: Bool
    }
    private var completionHolds: [UUID: CompletionHold] = [:]
    private(set) var departingRows: Set<UUID> = []
    private(set) var arrivingRows: Set<UUID> = []
    private var completionUndoSnapshot: TaskUndo?
    @ObservationIgnored private var completionBatch: Task<Void, Never>?
    @ObservationIgnored private var completionBatchAnimationStart: ContinuousClock.Instant?
    var panelDisplayHeight: CGFloat = .greatestFiniteMagnitude
    var panelManualHeight: CGFloat?
    var searching = false
    var editor: EditorTarget?
    var editorExpanded = false
    var editorPreferredHeight = PanelLayout.editorMinimumHeight
    var editorHasUnsavedChanges = false
    var selectedTask: UUID?
    var pendingSnooze: NoticeAction?
    private(set) var undoAction: TaskUndo?
    private(set) var pendingDeletionID: UUID?
    var confirmsDiscard = false
    var message: String?
    var today = Date.now
    var loginStatus = SMAppService.mainApp.status
    @ObservationIgnored private var undoExpiry: Task<Void, Never>?
    @ObservationIgnored var panelScrollOffset: CGFloat = 0
    @ObservationIgnored private(set) var panelSnapshotRevision: UInt64 = 0
    #if DEBUG
    @ObservationIgnored var listMetrics: PanelListMetrics?
    @ObservationIgnored var windowHeightForDiagnostics: (() -> CGFloat)?
    private static let layoutLog = Logger(subsystem: "io.lumatodo.mac", category: "list-layout")
    #endif

    @ObservationIgnored var showWindow: (() -> Void)?
    @ObservationIgnored var revealEditor: (() -> Void)?
    @ObservationIgnored var showSettings: (() -> Void)?
    @ObservationIgnored var tuckWindow: (() -> Void)?
    @ObservationIgnored var onLayoutChange: ((CGFloat, Bool) -> Void)?
    @ObservationIgnored var setMiniWindow: ((Bool) -> Void)?
    @ObservationIgnored var setDefaultSize: (() -> Void)?

    init(store: TaskStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
        mini = preferences.defaults.bool(forKey: "panel.mini")
        collapsedGroups = preferences.defaults.stringArray(forKey: "panel.collapsedGroups")
            .map { Set($0.compactMap(TaskGroup.init(rawValue:))) } ?? [.completed]
        listing = PanelListing(items: store.items, now: .now, order: preferences.values.sort,
                               attachmentCount: store.attachmentCount(for:))
        notifications = NotificationManager(store: store, preferences: preferences)
        updateVisibleSections()
        notifications.onAction = { [weak self] action in self?.handle(action) }
        notifications.onTestInteraction = { [weak self] in
            self?.settingsTab = .reminders
            self?.showSettings?()
        }
    }

    var words: Words { preferences.words }

    var dialog: PanelDialog? {
        if let message { return .message(message) }
        if let pendingDeletionID { return .deletion(pendingDeletionID) }
        if confirmsDiscard { return .discard }
        if pendingSnooze != nil { return .snooze }
        return nil
    }

    @discardableResult
    func dismissDialog() -> Bool {
        guard let dialog else { return false }
        switch dialog {
        case .message: message = nil
        case .deletion: pendingDeletionID = nil
        case .discard: confirmsDiscard = false
        case .snooze: pendingSnooze = nil
        }
        return true
    }

    func setMini(_ enabled: Bool) {
        guard enabled != mini else { return }
        mini = enabled
        preferences.defaults.set(enabled, forKey: "panel.mini")
        setMiniWindow?(enabled)
    }

    func newTask() {
        guard dialog == nil else { return }
        showWindow?()
        guard editor == nil else { return }
        setMini(false)
        edit(nil)
    }

    func edit(_ id: UUID?) {
        guard dialog == nil else { return }
        revealEditor?()
        guard editor == nil else { return }
        editorExpanded = false
        editorPreferredHeight = PanelLayout.editorMinimumHeight
        editorHasUnsavedChanges = false
        editor = EditorTarget(taskID: id)
    }

    func closeEditor() {
        editor = nil
        confirmsDiscard = false
        editorExpanded = false
        editorHasUnsavedChanges = false
    }

    func openSearch() {
        guard dialog == nil else { return }
        showWindow?()
        guard editor == nil else { return }
        setMini(false)
        searching = true
        searchFocus += 1
    }

    func closeSearch() {
        searching = false
        search = ""
    }

    func updateListing() {
        today = .now
        listing = PanelListing(items: store.items, now: today, order: preferences.values.sort,
                               attachmentCount: store.attachmentCount(for:))
        updateVisibleSections()
    }

    func isCollapsed(_ group: TaskGroup) -> Bool {
        collapsedGroups.contains(group) && search.isEmpty
    }

    func preferredPanelHeight(notice: Bool) -> CGFloat {
        let prefs = preferences.values
        return PanelLayout.height(sections: sectionSizes, searching: searching, notice: notice, undo: presentedUndo != nil,
                                  limit: prefs.windowHeight, available: .greatestFiniteMagnitude)
    }

    private var sectionSizes: [PanelLayout.SectionSize] {
        visibleSections.map { $0.size(compact: preferences.values.compact, collapsed: isCollapsed($0.group)) }
    }

    var presentedUndo: TaskUndo? {
        completionHolds.isEmpty ? undoAction : completionUndoSnapshot
    }

    func listShouldScroll(notice: Bool) -> Bool {
        let viewport = min(panelDisplayHeight, panelManualHeight ?? preferredPanelHeight(notice: notice))
            - PanelLayout.chromeHeight(searching: searching, notice: notice, undo: presentedUndo != nil)
        return PanelLayout.listContentHeight(sections: sectionSizes) > viewport + 0.5
    }

    func observeList(_ metrics: PanelListMetrics) {
        panelScrollOffset = metrics.offset
        #if DEBUG
        if listMetrics?.content != metrics.content || listMetrics?.viewport != metrics.viewport ||
            listMetrics?.scrolling != metrics.scrolling {
            let height = windowHeightForDiagnostics?() ?? 0
            Self.layoutLog.debug("layout content=\(metrics.content) viewport=\(metrics.viewport) window=\(height) scrollEnabled=\(metrics.scrolling) indicator=\(metrics.scrolling ? "auto" : "hidden", privacy: .public)")
        }
        listMetrics = metrics
        #endif
    }

    private func updateVisibleSections() {
        panelSnapshotRevision &+= 1
        let sections = listing.sections(matching: search)
        guard !completionHolds.isEmpty else { visibleSections = sections; return }
        let heldIDs = Set(completionHolds.keys).union(completionHolds.values.compactMap(\.resultingID))
        let rowsByGroup = Dictionary(uniqueKeysWithValues: sections.map { ($0.group, $0.tasks) })
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleSections = TaskGroup.allCases.compactMap { group in
            var rows = rowsByGroup[group, default: []].filter { !heldIDs.contains($0.id) }
            let holds = completionHolds.values.filter { $0.group == group && $0.task.matches(term) }
                .sorted { $0.index < $1.index }
            for hold in holds {
                rows.insert(hold.task, at: min(rows.count, hold.index))
            }
            return rows.isEmpty ? nil : PanelSection(group: group, tasks: rows)
        }
    }

    func completionFeedback(for id: UUID) -> Bool? { completionHolds[id]?.done }

    var featuredDuringMotion: PanelTask? {
        let featured = listing.featured
        return completionHolds.values.first(where: \.done)?.task ?? featured
    }

    private func completionAnchor(_ id: UUID) -> (PanelTask, TaskGroup, Int)? {
        guard preferences.values.animations, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return nil }
        for section in visibleSections where mini || !isCollapsed(section.group) {
            if let index = section.tasks.firstIndex(where: { $0.id == id }) {
                return (section.tasks[index], section.group, index)
            }
        }
        return nil
    }

    private func showCompletion(_ anchor: (PanelTask, TaskGroup, Int)?, done: Bool, resultingID: UUID? = nil) {
        guard let (task, group, index) = anchor else { return }
        let id = task.id
        let hold = CompletionHold(task: task, group: group, index: index, resultingID: resultingID, done: done)
        completionHolds[id] = hold
        departingRows.remove(id)
        arrivingRows.removeAll()
        updateVisibleSections()
        completionBatch?.cancel()
        let now = ContinuousClock.now
        let started = completionBatchAnimationStart ?? now
        completionBatchAnimationStart = started
        let endOfFeedback = min(now.advanced(by: Motion.completionHold), started.advanced(by: .milliseconds(360)))
        completionBatch = Task { [weak self] in
            do { try await Task.sleep(until: endOfFeedback, clock: .continuous) }
            catch { return }
            guard let self else { return }
            departingRows = Set(completionHolds.keys)
            do { try await Task.sleep(for: Motion.rowDeparture) }
            catch { return }
            // Replace the topology and the undo chrome together, with no retained
            // removal views. The destination rows animate their own opacity.
            arrivingRows = Set(completionHolds.keys).union(completionHolds.values.compactMap(\.resultingID))
            completionHolds.removeAll()
            departingRows.removeAll()
            completionBatchAnimationStart = nil
            completionUndoSnapshot = nil
            updateVisibleSections()
            do { try await Task.sleep(for: Motion.rowArrival) }
            catch { return }
            arrivingRows.removeAll()
        }
    }

    func save(_ draft: TaskDraft, id: UUID?, attachments: AttachmentChanges = AttachmentChanges()) -> Bool {
        do {
            if let id, store.item(id) == nil { throw TaskError.invalidOccurrence }
            let item = try store.save(draft, editing: id.flatMap(store.item), attachments: attachments)
            let hasReminders = item.hasReminders
            if hasReminders, notifications.authorization == .notDetermined {
                Task { await authorizeNotifications() }
            }
            return true
        } catch {
            report(error)
            return false
        }
    }

    func quickAdd(_ title: String) -> Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return save(TaskDraft(title: title), id: nil)
    }

    func complete(_ task: TaskItem, occurrence: Date? = nil, feedback: Bool = false) {
        if feedback, completionHolds[task.id] != nil { return }
        let anchor = feedback ? completionAnchor(task.id) : nil
        let previousUndo = presentedUndo
        do {
            let completed = try store.complete(task, occurrence: occurrence)
            store.finalizeDeletion()
            if anchor != nil, completionHolds.isEmpty { completionUndoSnapshot = previousUndo }
            presentUndo(.completion(completed.id))
            showCompletion(anchor, done: true, resultingID: completed.id)
        }
        catch { report(error) }
    }

    func undoLastAction() {
        guard dialog == nil else { return }
        switch undoAction {
        case .completion(let id):
            if let task = store.item(id) { restore(task, feedback: true, fromUndo: true) }
        case .deletion(let id):
            do {
                try store.undoDeletion(id)
                if let task = store.item(id) {
                    collapsedGroups.remove(TaskGroup.group(for: task, now: today))
                }
                dismissUndo()
            } catch { report(error) }
        case nil: break
        }
    }

    func restore(_ task: TaskItem, feedback: Bool = false, fromUndo: Bool = false) {
        if feedback, !fromUndo, completionHolds[task.id] != nil { return }
        let current = fromUndo ? completionHolds.values.first(where: { $0.resultingID == task.id }) : nil
        let anchor = current.map { ($0.task, $0.group, $0.index) } ?? (feedback ? completionAnchor(task.id) : nil)
        let previousUndo = presentedUndo
        do {
            let id = task.id
            try store.restore(task)
            if anchor != nil, completionHolds.isEmpty { completionUndoSnapshot = previousUndo }
            if let current { completionHolds.removeValue(forKey: current.task.id) }
            if undoAction == .completion(id) { dismissUndo() }
            showCompletion(anchor, done: false)
        } catch { report(error) }
    }

    func requestDeletion(_ id: UUID) {
        guard dialog == nil, store.item(id) != nil, !TaskPanel.hasActiveComposition else { return }
        pendingDeletionID = id
    }

    func confirmDeletion(_ id: UUID) {
        guard pendingDeletionID == id else { return }
        pendingDeletionID = nil
        guard let task = store.item(id) else { return }
        do {
            try store.deleteForUndo(task)
            if editor?.taskID == id { closeEditor() }
            if selectedTask == id { selectedTask = nil }
            presentUndo(.deletion(id))
        } catch { report(error) }
    }

    func dismissUndo() {
        undoExpiry?.cancel()
        undoExpiry = nil
        if case .deletion = undoAction { store.finalizeDeletion() }
        undoAction = nil
    }

    private func presentUndo(_ action: TaskUndo) {
        undoExpiry?.cancel()
        undoAction = action
        undoExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(9)) }
            catch { return }
            self?.dismissUndo()
        }
    }

    func authorizeNotifications() async {
        do { try await notifications.requestPermission() }
        catch { report(error) }
    }

    func snooze(_ action: NoticeAction, minutes: Int) {
        guard let task = store.item(action.taskID), notifications.isCurrent(action) else { return }
        do {
            try store.snooze(task, occurrence: action.occurrence, minutes: minutes,
                             independentReminderID: action.independentReminderID)
        }
        catch { report(error) }
    }

    func refreshSystemState(updateTasks: Bool = true) {
        if updateTasks { updateListing() }
        loginStatus = SMAppService.mainApp.status
        notifications.reconcile()
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { report(error) }
        loginStatus = SMAppService.mainApp.status
    }

    private func handle(_ action: NoticeAction) {
        guard let task = store.item(action.taskID) else { return }
        switch action.action {
        case NotificationManager.complete:
            if notifications.isCurrent(action) {
                complete(task, occurrence: action.independentReminderID == nil ? action.occurrence : nil)
            }
        case NotificationManager.snooze:
            guard notifications.isCurrent(action) else { return }
            showWindow?()
            setMini(false)
            pendingSnooze = action
        default:
            showWindow?()
            setMini(false)
            if let editor {
                revealEditor?()
                if editor.taskID != task.id {
                    message = words("请先保存或取消当前编辑，再打开通知中的任务。",
                                    "Save or cancel the current edit before opening the task from the notification.")
                }
                return
            }
            searching = false
            search = ""
            collapsedGroups.remove(TaskGroup.group(for: task, now: .now))
            selectedTask = task.id
            edit(task.id)
        }
    }

    private func report(_ error: Error) {
        let detail: String
        if error is NoticeError {
            detail = words("请在系统设置中允许 LumaTodo 显示通知。", "Allow LumaTodo notifications in System Settings.")
        } else if error is TaskError {
            detail = words("请检查标题或任务是否仍存在。", "Check the title and whether the task still exists.")
        } else {
            detail = error.localizedDescription
        }
        message = detail
    }
}

struct EditorTarget: Identifiable {
    let id = UUID()
    let taskID: UUID?
}

enum TaskUndo: Equatable {
    case completion(UUID), deletion(UUID)

    var isDeletion: Bool {
        if case .deletion = self { return true }
        return false
    }
}

enum PanelDialog: Hashable {
    case deletion(UUID), discard, snooze, message(String)
}

enum TaskGroup: String, CaseIterable, Identifiable {
    case overdue, today, upcoming, completed
    var id: Self { self }

    func label(_ words: Words) -> String {
        switch self {
        case .overdue: words("逾期", "Overdue")
        case .today: words("今天", "Today")
        case .upcoming: words("即将到来", "Upcoming")
        case .completed: words("已完成", "Completed")
        }
    }

    @MainActor
    static func group(for task: TaskItem, now: Date, calendar: Calendar = .current) -> Self {
        group(isCompleted: task.isCompleted, due: dateForGrouping(task, calendar: calendar), now: now, calendar: calendar)
    }

    static func group(isCompleted: Bool, due: Date?, now: Date, calendar: Calendar) -> Self {
        if isCompleted { return .completed }
        guard let due else { return .upcoming }
        if due < now { return .overdue }
        if calendar.isDate(due, inSameDayAs: now) { return .today }
        return .upcoming
    }

}
