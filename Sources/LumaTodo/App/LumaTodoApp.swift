import AppKit

@main
enum LumaTodoApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var state: AppState?
    private var window: FloatingWindow?
    private var statusItem: NSStatusItem?
    private var rollover: Timer?
    private let statusMenu = NSMenu()

    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            let prefs = Preferences()
            let store = try TaskStore(url: TaskStore.applicationStoreURL())
            let state = AppState(store: store, preferences: prefs)
            self.state = state
            let window = FloatingWindow(state: state)
            self.window = window
            state.showWindow = { [weak self] in self?.window?.show() }
            state.tuckWindow = { [weak window] in window?.tuck() }
            state.onLayoutChange = { [weak window] height, editing in window?.updateLayout(height: height, editing: editing) }
            state.revealEditor = { [weak window] in window?.revealEditor() }
            state.showSettings = { [weak self] in self?.window?.openSettings() }
            state.setMiniWindow = { [weak self] in self?.window?.setMini($0) }
            state.setDefaultSize = { [weak self] in self?.window?.restoreDefaultSize() }
            state.shortcut.onPress = { [weak self] in self?.window?.toggle() }
            prefs.onChange = { [weak self] old in self?.preferencesChanged(from: old) }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "无法打开 LumaTodo 待办数据库"
            alert.informativeText = "任务数据已保留。\n\(error.localizedDescription)"
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let state else { return }
        state.store.onChange = { [weak self] in self?.refresh() }
        state.notifications.onQueueChange = { [weak self] in self?.scheduleRefresh() }
        makeMenu()
        updateStatusItem()
        state.shortcut.register(state.preferences.values.shortcut)
        statusMenu.delegate = self
        window?.restoreAtLaunch()
        refresh()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
        let center = NotificationCenter.default
        for event in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            center.addObserver(self, selector: #selector(refresh), name: event, object: nil)
        }
        center.addObserver(self, selector: #selector(screenChanged),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func applicationDidBecomeActive(_ notification: Notification) { refresh() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let state, state.editorHasUnsavedChanges {
            let w = state.words
            let alert = NSAlert()
            alert.messageText = w("退出前要保留正在编辑的任务吗？", "Keep editing this task?")
            alert.informativeText = w("退出后，本次未保存的编辑和新增附件会被丢弃。",
                                      "Quitting discards unsaved changes and newly added attachments.")
            alert.addButton(withTitle: w("返回编辑", "Keep Editing"))
            alert.addButton(withTitle: w("舍弃并退出", "Discard and Quit"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        guard let notifications = state?.notifications, notifications.isSyncing else { return .terminateNow }
        Task {
            await notifications.finishPendingSynchronization()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { state?.dismissUndo() }

    private func preferencesChanged(from old: PreferencesValues) {
        guard let state else { return }
        let values = state.preferences.values
        if old.shortcut != values.shortcut { state.shortcut.register(values.shortcut) }
        if old.menuBar != values.menuBar || old.language != values.language { updateStatusItem() }
        if old.language != values.language {
            makeMenu()
            state.notifications.registerCategories()
        }
        if old.sound != values.sound || old.language != values.language { state.notifications.reconcile() }
        if old.alwaysOnTop != values.alwaysOnTop || old.allSpaces != values.allSpaces ||
            old.appearance != values.appearance || old.rememberPosition != values.rememberPosition {
            window?.applyPreferences()
        }
        if old.sort != values.sort { state.updateListing() }
    }

    @objc private func refresh() {
        guard let state else { return }
        state.refreshSystemState()
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard let state else { return }
        rollover?.invalidate()
        let now = Date.now
        let nextDeadline = state.listing.nextDeadline
        let nextDay = Calendar.current.dateInterval(of: .day, for: now)?.end ?? now.addingTimeInterval(3600)
        let hasReminders = state.listing.hasReminders
        let healthCheck = now.addingTimeInterval(state.notifications.failures.isEmpty ? 15 * 60 : 60)
        var next = min(nextDeadline ?? nextDay, nextDay)
        if hasReminders { next = min(next, healthCheck) }
        if let refill = state.notifications.refillAfter { next = min(next, refill) }
        rollover = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow + 0.2), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshForTimer() }
        }
        rollover?.tolerance = 0.5
    }

    private func refreshForTimer() {
        guard let state else { return }
        let now = Date.now
        let midnight = !Calendar.current.isDate(state.today, inSameDayAs: now)
        let deadlinePassed = state.listing.nextDeadline.map { $0 <= now } ?? false
        state.refreshSystemState(updateTasks: midnight || deadlinePassed)
        scheduleRefresh()
    }

    @objc private func screenChanged() { window?.screensChanged() }

    private func updateStatusItem() {
        guard let state else { return }
        if !state.preferences.values.menuBar {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let button = item.button
        button?.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "LumaTodo")
        button?.target = self
        button?.action = #selector(statusPressed)
        button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button?.toolTip = state.words("LumaTodo · 右键打开菜单", "LumaTodo · Right-click for menu")
        statusItem = item
    }

    @objc private func statusPressed() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true,
           let statusItem, let button = statusItem.button {
            statusItem.menu = statusMenu
            button.performClick(nil)
            statusItem.menu = nil
        } else { window?.toggle() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let state else { return }
        let w = state.words
        let visible = window?.isVisible == true
        menu.removeAllItems()
        menu.addItem(makeItem(visible ? w("收起／展开待办", "Tuck / Expand Tasks") : w("显示待办", "Show Tasks"),
                              #selector(toggleWindow)))
        menu.addItem(makeItem(w("新建任务", "New Task"), #selector(newTask)))
        menu.addItem(.separator())
        let pin = makeItem(w("始终置顶", "Always on Top"), #selector(togglePin))
        pin.state = state.preferences.values.alwaysOnTop ? .on : .off
        menu.addItem(pin)
        menu.addItem(makeItem(w("设置…", "Settings…"), #selector(settings)))
        menu.addItem(.separator())
        menu.addItem(makeItem(w("退出 LumaTodo", "Quit LumaTodo"), #selector(NSApplication.terminate(_:)), "q", target: NSApp))
    }

    private func makeMenu() {
        guard let state else { return }
        let w = state.words
        let root = NSMenu()
        let app = NSMenu(title: "LumaTodo")
        app.addItem(makeItem(w("关于 LumaTodo", "About LumaTodo"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp))
        app.addItem(.separator())
        app.addItem(makeItem(w("设置…", "Settings…"), #selector(settings), ","))
        app.addItem(.separator())
        app.addItem(makeItem(w("退出 LumaTodo", "Quit LumaTodo"), #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        let tasks = NSMenu(title: w("任务", "Tasks"))
        tasks.addItem(makeItem(w("新建任务", "New Task"), #selector(newTask), "n"))
        tasks.addItem(makeItem(w("查找任务", "Find Tasks"), #selector(findTasks), "f"))
        tasks.addItem(makeItem(w("收起或展开待办", "Tuck or Expand Tasks"), #selector(toggleWindow), "w"))
        let edit = NSMenu(title: w("编辑", "Edit"))
        edit.addItem(makeItem(w("撤销", "Undo"), #selector(undo), "z"))
        for (label, selector, key) in [(w("剪切", "Cut"), "cut:", "x"),
                                       (w("复制", "Copy"), "copy:", "c"), (w("粘贴", "Paste"), "paste:", "v"),
                                       (w("全选", "Select All"), "selectAll:", "a")] {
            edit.addItem(withTitle: label, action: Selector(selector), keyEquivalent: key)
        }
        for menu in [app, tasks, edit] {
            let item = NSMenuItem()
            item.submenu = menu
            root.addItem(item)
        }
        NSApp.mainMenu = root
    }

    private func makeItem(_ label: String, _ action: Selector, _ key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: label, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    @objc private func undo() {
        guard !TaskPanel.hasActiveComposition, state?.dialog == nil else { return }
        if let undoManager = NSApp.keyWindow?.firstResponder?.undoManager, undoManager.canUndo {
            undoManager.undo()
        } else {
            state?.undoLastAction()
        }
    }

    @objc private func toggleWindow() { window?.toggle() }
    @objc private func togglePin() { state?.preferences.values.alwaysOnTop.toggle() }
    @objc private func newTask() { state?.newTask() }
    @objc private func findTasks() { state?.openSearch() }
    @objc private func settings() { window?.openSettings() }
}
