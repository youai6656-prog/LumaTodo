import AppKit
import UserNotifications

@main
enum NativeAcceptanceProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let checkNotifications = CommandLine.arguments.contains("--notifications")
        let recordingDirectory = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("--record=") })
            .map { URL(fileURLWithPath: String($0.dropFirst("--record=".count)), isDirectory: true) }
        Task { @MainActor in
            do {
                try await verify(checkNotifications: checkNotifications, recordingDirectory: recordingDirectory)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }

    @MainActor private static func verify(checkNotifications: Bool, recordingDirectory: URL?) async throws {
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
        if let recordingDirectory {
            try await NativeMotionRecording.verify(state, directory: recordingDirectory)
            return
        }
        try await verifyCompletionCommit(state, database: folder.appending(path: "Tasks.store"))
        try await verifyWindows(state, defaults: defaults)
        if checkNotifications {
            try await verifyNotifications(state)
        }
    }

    @MainActor private static func verifyCompletionCommit(_ state: AppState, database: URL) async throws {
        state.preferences.values.animations = true
        defer { state.preferences.values.animations = false }
        let task = try state.store.save(TaskDraft(title: "Commit while animating"))
        let id = task.id
        state.updateListing()
        state.store.onChange = { [weak state] in state?.updateListing() }
        state.complete(task, feedback: true)
        try check(try TaskStore(url: database).item(id)?.isCompleted == true, "Completion waited for animation before saving")
        state.undoLastAction()
        try check(try TaskStore(url: database).item(id)?.isCompleted == false, "Immediate undo did not reach disk")
        try check(state.visibleSections.flatMap(\.tasks).filter { $0.id == id }.count == 1, "Immediate undo duplicated the row")
        try await expect("Completion feedback did not clear") { state.completionFeedback(for: id) == nil }
        try state.store.delete(task)
        print("PASS: completion and immediate undo committed before either animation settled.")
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
        try await verifyEdgeMotion(window, panel: panel, visible: visible, state: state, defaults: defaults)
        try await verifyCompletionLayout(state, panel: panel)
        window.hide()
        try check(!window.isVisible, "Hiding left a window visible")
        print("PASS: native empty/short/long list bounds, quick add and search, compact editor and list restore, mini and tuck, plus pin levels.")
    }

    @MainActor private static func verifyCompletionLayout(_ state: AppState, panel: NSWindow) async throws {
        let store = state.store
        let source = FileManager.default.temporaryDirectory.appending(path: "LumaTodo-\(UUID()).txt")
        let payload = Data("Completion layout attachment".utf8)
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        var completions = 0
        var restores = 0
        for count in [1, 2, 10, 80] {
            state.selectedTask = nil
            state.collapsedGroups = []
            state.dismissUndo()
            store.onChange = nil
            for old in store.items { try store.delete(old) }
            let imported = await store.attachmentManager.importFiles([source])
            try check(imported.imported.count == 1, "Unable to add the completion test attachment")
            var draft = TaskDraft(title: "Scheduled attachment")
            draft.due = .now.addingTimeInterval(10_800)
            draft.hasTime = true
            draft.leads = [10]
            let task = try store.save(draft, attachments: .init(adding: imported.imported))
            let savedDue = task.due
            for index in 1..<count { try store.save(TaskDraft(title: "Unscheduled task \(index)")) }
            state.updateListing()
            store.onChange = { [weak state] in state?.updateListing() }
            try await Task.sleep(for: .milliseconds(180))
            if count == 80 {
                try await expect("The long list does not permit scrolling") { state.listMetrics?.scrolling == true }
                state.selectedTask = state.visibleSections.last?.tasks.last?.id
                try await expect("The long list could not actually scroll") { (state.listMetrics?.offset ?? 0) > 10 }
                print("LAYOUT: 80 tasks scroll offset=\(state.listMetrics?.offset ?? 0)")
                state.selectedTask = task.id
            }
            for index in 0..<5 {
                state.collapsedGroups = index.isMultiple(of: 2) ? [.completed] : []
                try await Task.sleep(for: .milliseconds(60))
                try await sampleCompletionLayout(state, panel: panel, count: count, label: "complete") {
                    state.complete(task, feedback: true)
                    try check(task.isCompleted, "Completion failed to commit immediately")
                }
                completions += 1
                try await sampleCompletionLayout(state, panel: panel, count: count, label: "restore") {
                    if index.isMultiple(of: 2) { state.undoLastAction() }
                    else { state.restore(task, feedback: true) }
                    try check(!task.isCompleted, "Restore failed to commit immediately")
                }
                restores += 1
                let ids = state.visibleSections.flatMap(\.tasks).map(\.id)
                try check(Set(ids).count == count && ids.count == count && task.due == savedDue && task.leads == [10],
                          "Completion and restoration lost a task, duplicated a row, or changed its reminder")
                guard let attachment = store.attachments(for: task.id).first else { throw Failure("Missing attachment") }
                try check(try Data(contentsOf: store.attachmentManager.url(for: attachment)) == payload,
                          "Completion and restoration changed an attachment")
            }
        }
        let pair = Array(store.items.filter { $0.due == nil }.prefix(2))
        try check(pair.count == 2, "Missing rapid completion fixtures")
        try await sampleCompletionLayout(state, panel: panel, count: 80, label: "rapid complete") {
            for task in pair { state.complete(task, feedback: true) }
            try check(pair.allSatisfy(\.isCompleted), "A rapid completion was lost")
        }
        try await sampleCompletionLayout(state, panel: panel, count: 80, label: "rapid restore") {
            for task in pair { state.restore(task, feedback: true) }
            try check(pair.allSatisfy { !$0.isCompleted }, "A rapid restoration was lost")
        }
        let ids = state.visibleSections.flatMap(\.tasks).map(\.id)
        try check(Set(ids).count == 80 && ids.count == 80, "Rapid changes lost or duplicated rows")
        print("PASS: \(completions + pair.count) completions and \(restores + pair.count) restores across short, medium, capped, and collapsed lists, with reminder fields and attachment bytes retained.")
        store.onChange = nil
        for task in store.items { try store.delete(task) }
        state.updateListing()
    }

    @MainActor private static func sampleCompletionLayout(_ state: AppState, panel: NSWindow, count: Int,
                                                         label: String, action: () throws -> Void) async throws {
        var lastHeight = panel.frame.height
        var heightChanges = 0
        try action()
        for _ in 0..<32 {
            if !approximately(lastHeight, panel.frame.height) {
                lastHeight = panel.frame.height
                heightChanges += 1
            }
            if count <= 2 {
                try check(state.listMetrics?.scrolling == false, "A short list enabled scrolling during \(label)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let metrics = state.listMetrics else { throw Failure("No SwiftUI list geometry received") }
        let ids = state.visibleSections.flatMap(\.tasks)
        try check(ids.allSatisfy { state.completionFeedback(for: $0.id) == nil }, "Completion presentation did not settle")
        try check(heightChanges <= 1, "The NSWindow resized \(heightChanges) times during \(label), count=\(count)")
        if count <= 2 {
            try check(metrics.content <= metrics.viewport + 1, "The settled short list exceeds the actual viewport")
        }
        print("LAYOUT: tasks=\(count) action=\(label) content=\(metrics.content) viewport=\(metrics.viewport) window=\(lastHeight) heightChanges=\(heightChanges) scrollEnabled=\(metrics.scrolling) indicator=\(metrics.scrolling ? "auto" : "hidden")")
    }

    @MainActor private static func verifyEdgeMotion(_ window: FloatingWindow, panel: NSWindow, visible: NSRect,
                                                    state: AppState, defaults: UserDefaults) async throws {
        guard let tab = NSApp.windows.first(where: { $0.title == "LumaTodo Edge" }) else {
            throw Failure("The native edge panel is missing")
        }
        state.preferences.values.animations = true
        let motion = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let rest = panel.frame
        var frames: [CFTimeInterval] = []
        window.onTransitionFrame = { frames.append($0) }
        defer { window.onTransitionFrame = nil }
        for side: TuckSide in [.left, .right] {
            state.preferences.tuckSide = side
            window.tuck()
            if motion {
                try await expect("The panel did not move and narrow toward the \(side.rawValue) edge") {
                    guard let frame = window.transitionFrame, !panel.isVisible, !tab.isVisible else { return false }
                    let moved = side == .left ? frame.midX < rest.midX - 1 : frame.midX > rest.midX + 1
                    return moved && frame.width < rest.width - 1 && frame.height < rest.height - 1
                }
            }
            try await expect("Tucking failed to finish with only the edge tab visible") { tab.isVisible && !panel.isVisible }
            try check(visible.contains(tab.frame), "The edge tab left the display's visible area")
            try check(side == .left ? tab.frame.minX == visible.minX : tab.frame.maxX == visible.maxX,
                      "The edge tab did not use the selected side")
            try check(defaults.bool(forKey: "window.collapsed"), "The collapsed state was not saved")
            window.show()
            if motion {
                try check(!panel.isVisible && window.transitionFrame == tab.frame,
                          "Expansion did not start at the edge in the shared transition panel")
            }
            try await expect("Expansion did not restore the original frame") { panel.isVisible && panel.frame == rest && panel.alphaValue == 1 }
        }
        if motion {
            window.tuck()
            try await expect("Could not reach an intermediate frame for reversal") {
                (window.transitionFrame?.width ?? 0) > tab.frame.width &&
                (window.transitionFrame?.width ?? rest.width) < rest.width - 5
            }
            let before = window.transitionFrame
            window.toggle()
            try check(window.transitionFrame == before, "Reversing jumped the presentation frame")
            try await expect("Reversing the morph did not restore the window") {
                panel.isVisible && !tab.isVisible && window.transitionFrame == nil && panel.frame == rest
            }
        }
        print("DISPLAY LINK: \(frameIntervals(frames)) without capture.")
        print("PASS: native glass morph narrows toward both edges, uses exclusive endpoints and reverses without a frame jump (motion enabled: \(motion)).")
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
        state.complete(timed, feedback: true)
        try check(await pending(manager, center).isEmpty, "Completion did not cancel the timed request")
        state.undoLastAction()
        try check(await pending(manager, center) == edited, "Undo did not restore the timed request")
        try store.delete(timed)

        draft.title = "QA weekly recurrence"
        draft.rule = RepeatRule(kind: .weekly)
        let recurring = try store.save(draft, timeZone: utc)
        let occurrences = await pending(manager, center)
        try check(occurrences.count >= 2 && occurrences.allSatisfy { $0.contains(recurring.id.uuidString) },
                  "Weekly recurrence did not produce multiple distinct requests")
        let recurringID = recurring.id
        try store.deleteForUndo(recurring)
        try check(await pending(manager, center).isEmpty, "Deleting the recurrence left pending requests")
        try store.undoDeletion(recurringID)
        try check(await pending(manager, center) == occurrences, "Undo lost or duplicated recurrence requests")
        guard let restored = store.item(recurringID) else { throw Failure("Undo did not restore the recurring task") }
        try store.delete(restored)

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
