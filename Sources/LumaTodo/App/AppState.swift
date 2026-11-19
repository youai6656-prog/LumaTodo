import AppKit
import Observation
import ServiceManagement

@MainActor @Observable
final class AppState {
    let preferences: Preferences
    let store: TaskStore
    let notifications: NotificationManager
    let shortcut = GlobalShortcut()

    var mini = false
    var settingsTab: SettingsTab = .appearance
    var collapsedGroups: Set<TaskGroup> = [.completed]
    var search = "" {
        didSet { if search != oldValue { updateVisibleSections() } }
    }
    var searchFocus = 0
    private(set) var listing: PanelListing
    private(set) var visibleSections: [PanelSection] = []
    var searching = false
    var editor: EditorTarget?
    var editorExpanded = false
    var editorPreferredHeight = PanelLayout.editorMinimumHeight
    var editorHasUnsavedChanges = false
    var selectedTask: UUID?
    var pendingSnooze: NoticeAction?
    var undoTaskID: UUID?
    var message: String?
    var today = Date.now
    var loginStatus = SMAppService.mainApp.status

    @ObservationIgnored var showWindow: (() -> Void)?
    @ObservationIgnored var revealEditor: (() -> Void)?
    @ObservationIgnored var showSettings: (() -> Void)?
    @ObservationIgnored var tuckWindow: (() -> Void)?
    @ObservationIgnored var onLayoutChange: ((CGFloat, Bool) -> Void)?
    @ObservationIgnored var hideWindow: (() -> Void)?
    @ObservationIgnored var setMiniWindow: ((Bool) -> Void)?
    @ObservationIgnored var setDefaultSize: (() -> Void)?

    init(store: TaskStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
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

    func setMini(_ enabled: Bool) {
        guard enabled != mini else { return }
        mini = enabled
        setMiniWindow?(enabled)
    }

    func newTask() {
        showWindow?()
        guard editor == nil else { return }
        setMini(false)
        edit(nil)
    }

    func edit(_ id: UUID?) {
        revealEditor?()
        guard editor == nil else { return }
        editorExpanded = false
        editorPreferredHeight = PanelLayout.editorMinimumHeight
        editorHasUnsavedChanges = false
        editor = EditorTarget(taskID: id)
    }

    func closeEditor() {
        editor = nil
        editorExpanded = false
        editorHasUnsavedChanges = false
    }

    func openSearch() {
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
        let sizes = visibleSections.map { $0.size(compact: prefs.compact, collapsed: isCollapsed($0.group)) }
        return PanelLayout.height(sections: sizes, searching: searching, notice: notice, undo: undoTaskID != nil,
                                  limit: prefs.windowHeight, available: .greatestFiniteMagnitude)
    }

    private func updateVisibleSections() {
        visibleSections = listing.sections(matching: search)
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

    func complete(_ task: TaskItem, occurrence: Date? = nil) {
        do { undoTaskID = try store.complete(task, occurrence: occurrence).id }
        catch { report(error) }
    }

    func undoCompletion() {
        guard let id = undoTaskID, let task = store.item(id) else { return }
        restore(task)
    }

    func restore(_ task: TaskItem) {
        do {
            let id = task.id
            try store.restore(task)
            if undoTaskID == id { undoTaskID = nil }
        } catch { report(error) }
    }

    func delete(_ task: TaskItem) {
        do {
            let id = task.id
            try store.delete(task)
            if undoTaskID == id { undoTaskID = nil }
        } catch { report(error) }
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
