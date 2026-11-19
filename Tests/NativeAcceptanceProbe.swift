import AppKit
import UserNotifications

@main
enum NativeAcceptanceProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let checkNotifications = CommandLine.arguments.contains("--notifications")
        Task { @MainActor in
            do {
                try await verify(checkNotifications: checkNotifications)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }

    @MainActor private static func verify(checkNotifications: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "io.lumatodo.mac.native-probe.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure("QA defaults unavailable") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.values.animations = false
        let store = try TaskStore(url: folder.appending(path: "Tasks.store"))
        let state = AppState(store: store, preferences: preferences)
        try await verifyWindows(state, defaults: defaults)
        if checkNotifications {
            try await verifyNotifications(state)
        }
    }

    @MainActor private static func verifyWindows(_ state: AppState, defaults: UserDefaults) async throws {
        let window = FloatingWindow(state: state)
        state.onLayoutChange = { [weak window] height, editing in window?.updateLayout(height: height, editing: editing) }
        state.setMiniWindow = { [weak window] enabled in window?.setMini(enabled) }
        state.showWindow = { [weak window] in window?.show() }
        state.store.onChange = { [weak state] in state?.updateListing() }
        window.show()
        guard let panel = NSApp.windows.first(where: { $0.title == "LumaTodo" }),
              let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        else { throw Failure("A desktop display and native LumaTodo window are required") }

        try await expect("Unexpected empty frame: \(panel.frame)") { approximately(panel.frame.height, 244) }
        let empty = panel.frame
        for index in 1...3 {
            try check(state.quickAdd("窗口回归任务 \(index)"), "Quick add did not save a valid title")
        }
        try await expect("Three tasks did not expand the window") { approximately(panel.frame.height, 316) }
        try check(approximately(panel.frame.maxY, empty.maxY) && approximately(panel.frame.maxX, empty.maxX),
                  "Growing the list moved its anchor")
        try check(defaults.string(forKey: "window.manualSize") == nil, "An automatic resize was recorded as manual")
        let full = panel.frame
        state.openSearch()
        state.search = "回归任务 2"
        try check(state.visibleSections.flatMap(\.tasks).map(\.title) == ["窗口回归任务 2"],
                  "Searching by title did not narrow the visible tasks")
        state.closeSearch()
        try await expect("Leaving search changed the list frame") { panel.frame == full }
        state.setMini(true)
        try await expect("Mini mode has the wrong frame") { panel.frame.size == PanelLayout.miniSize }
        window.tuck()
        try await expect("Tucking did not leave a tab") { !panel.isVisible && window.isVisible }
        window.show()
        try await expect("Restoring the tab did not restore mini mode") { panel.isVisible && panel.frame.size == PanelLayout.miniSize }
        state.setMini(false)
        try await expect("Leaving mini mode changed the list frame") { panel.frame == full }

        state.store.onChange = nil
        for index in 4...50 { try state.store.save(TaskDraft(title: "窗口回归任务 \(index)")) }
        state.updateListing()
        try await expect("The large list exceeded its height limit") { approximately(panel.frame.height, min(580, visible.height)) }
        let largeList = panel.frame
        state.newTask()
        try await expect("The initial editor is outside its expected range: \(panel.frame)") {
            (380...460).contains(panel.frame.width) && (420...560).contains(panel.frame.height)
        }
        let editor = panel.frame
        try check(visible.insetBy(dx: -1, dy: -1).contains(editor), "The editor extends outside the visible display")
        state.editorExpanded = true
        try await Task.sleep(for: .milliseconds(150))
        try await expect("The expanded editor shrank or extended off-screen") {
            panel.frame.height >= editor.height && approximately(panel.frame.height, min(visible.height, state.editorPreferredHeight))
                && visible.insetBy(dx: -1, dy: -1).contains(panel.frame)
        }
        state.closeEditor()
        try await expect("Closing the editor moved or resized the list") { panel.frame == largeList }

        state.preferences.values.alwaysOnTop = false
        window.applyPreferences()
        try check(panel.level == .normal, "Turning off pinning left the floating level active")
        state.preferences.values.alwaysOnTop = true
        window.applyPreferences()
        try check(panel.level == .floating, "Turning on pinning did not restore the floating level")
        window.hide()
        try check(!window.isVisible, "Hiding left a window visible")
        print("PASS: native empty/short/long list bounds, quick add and search, compact editor and list restore, mini and tuck, plus pin levels.")
    }

    @MainActor private static func verifyNotifications(_ state: AppState) async throws {
        guard Bundle.main.bundleIdentifier == "io.lumatodo.mac.roundtwo.qa" else {
            throw Failure("Native notification tests require the isolated QA bundle identifier")
        }
        let store = state.store
        let manager = state.notifications
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try await center.requestAuthorization(options: [.alert])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional else {
            throw Failure("Notifications are unavailable for LumaTodo QA. Enable that test app in System Settings.")
        }
        defer {
            // The enclosing app has a dedicated QA identifier and its database is temporary.
            center.removeAllPendingNotificationRequests()
        }

        let utc = TimeZone(secondsFromGMT: 0)!
        let now = Date.now
        var draft = TaskDraft(title: "QA timed task")
        draft.due = now.addingTimeInterval(4 * 3600)
        draft.hasTime = true
        draft.leads = [0]
        let timed = try store.save(draft)
        let initial = await pending(manager, center)
        try check(initial.count == 1, "The timed task did not produce exactly one system request")
        draft.due = draft.due?.addingTimeInterval(600)
        try store.save(draft, editing: timed)
        let edited = await pending(manager, center)
        try check(edited.count == 1 && edited != initial, "Editing did not replace the old timed request")
        try check(await pending(manager, center) == edited, "Reconciliation duplicated the edited request")
        try store.complete(timed)
        try check(await pending(manager, center).isEmpty, "Completion did not cancel the timed request")
        try store.restore(timed)
        try check(await pending(manager, center) == edited, "Undo did not restore the timed request")
        try store.delete(timed)

        draft.title = "QA weekly recurrence"
        draft.rule = RepeatRule(kind: .weekly)
        let recurring = try store.save(draft, timeZone: utc)
        let occurrences = await pending(manager, center)
        try check(occurrences.count >= 2 && occurrences.allSatisfy { $0.contains(recurring.id.uuidString) },
                  "Weekly recurrence did not produce multiple distinct requests")
        try store.delete(recurring)
        try check(await pending(manager, center).isEmpty, "Deleting the recurrence left pending requests")

        var independent = TaskDraft(title: "QA reminder with no deadline")
        let fire = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60 + 8 * 3600)
        let reminder = IndependentReminder(fire: fire)
        independent.independentReminders = [reminder]
        let untimed = try store.save(independent)
        let original = await pending(manager, center)
        try check(untimed.due == nil && original.count == 1 && original.first?.contains(untimed.id.uuidString) == true,
                  "A task without a deadline did not produce its independent reminder")
        try store.snooze(untimed, occurrence: fire, minutes: 5, now: now, independentReminderID: reminder.id)
        let snoozed = await pending(manager, center)
        try check(snoozed.contains { $0.contains(".snooze.") }, "Snoozing an independent notification did not schedule a snooze")
        try store.delete(untimed)
        try check(await pending(manager, center).isEmpty, "Deleting the untimed task left its reminder or snooze")
        print("PASS: native notification scheduling, edit reconciliation, completion and undo, weekly recurrence, independent times and snooze.")
    }

    @MainActor private static func pending(_ manager: NotificationManager, _ center: UNUserNotificationCenter) async -> Set<String> {
        manager.reconcile()
        await manager.finishPendingSynchronization()
        return Set(await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(NotificationEvent.prefix) })
    }

    @MainActor private static func expect(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<25 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(80))
        }
        try check(condition(), message)
    }

    private static func approximately(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1 }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
