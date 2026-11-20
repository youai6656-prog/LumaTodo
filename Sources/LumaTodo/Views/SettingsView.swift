import SwiftUI
import ServiceManagement

enum SettingsTab: Hashable { case appearance, window, reminders, system }

struct SettingsView: View {
    @Bindable var state: AppState
    @Bindable private var preferences: Preferences

    init(state: AppState) {
        self.state = state
        preferences = state.preferences
    }
    @State private var recording = false
    @State private var captureMonitor: Any?
    @State private var shortcutMessage: String?
    @State private var feedback: String?

    private var w: Words { state.words }

    var body: some View {
        TabView(selection: $state.settingsTab) {
            appearance.tabItem { Label(w("外观", "Appearance"), systemImage: "circle.lefthalf.filled") }.tag(SettingsTab.appearance)
            window.tabItem { Label(w("窗口", "Window"), systemImage: "macwindow") }.tag(SettingsTab.window)
            reminders.tabItem { Label(w("提醒", "Reminders"), systemImage: "bell") }.tag(SettingsTab.reminders)
            system.tabItem { Label(w("系统", "System"), systemImage: "gearshape") }.tag(SettingsTab.system)
        }
        .padding(15)
        .frame(width: 560, height: 530)
        .environment(\.locale, w.locale)
        .onAppear { state.refreshSystemState() }
        .onDisappear { stopRecording() }
        .alert("LumaTodo", isPresented: Binding(get: { feedback != nil }, set: { if !$0 { feedback = nil } })) {
            Button(w("好", "OK"), role: .cancel) { feedback = nil }
        } message: { Text(feedback ?? "") }
    }

    private var appearance: some View {
        Form {
            Section(w("界面", "Interface")) {
                Picker(w("系统外观", "Appearance"), selection: $preferences.values.appearance) {
                    Text(w("跟随系统", "System")).tag(AppearanceChoice.system)
                    Text(w("浅色", "Light")).tag(AppearanceChoice.light)
                    Text(w("深色", "Dark")).tag(AppearanceChoice.dark)
                }
                Toggle(w("Liquid Glass 玻璃材质", "Liquid Glass material"), isOn: $preferences.values.glass)
                Toggle(w("使用不透明背景，提高清晰度", "Use an opaque background for readability"),
                       isOn: $preferences.values.opaque)
                Toggle(w("紧凑任务列表", "Compact task list"), isOn: $preferences.values.compact)
                Toggle(w("界面与窗口动画", "Interface and window animations"), isOn: $preferences.values.animations)
                Picker(w("动画强度", "Motion intensity"), selection: $preferences.motionIntensity) {
                    Text(w("标准", "Standard")).tag(MotionIntensity.standard)
                    Text(w("柔和", "Gentle")).tag(MotionIntensity.gentle)
                }
                .disabled(!preferences.values.animations)
            }
        }
        .formStyle(.grouped)
    }

    private var window: some View {
        Form {
            Section(w("悬浮行为", "Floating behavior")) {
                Toggle(w("始终置顶", "Always on top"), isOn: $preferences.values.alwaysOnTop)
                Toggle(w("在所有适用桌面空间显示", "Show on all eligible Spaces"), isOn: $preferences.values.allSpaces)
                Toggle(w("吸附屏幕左右边缘", "Snap to left or right screen edge"), isOn: $preferences.values.snapToEdge)
                Toggle(w("贴边后收起为侧边按钮", "Collapse to a tab after snapping"), isOn: $preferences.values.autoHide)
                    .disabled(!state.preferences.values.snapToEdge)
                Picker(w("收起方向", "Tuck side"), selection: $preferences.tuckSide) {
                    ForEach(TuckSide.allCases) { side in Text(side.label(w)).tag(side) }
                }
                Toggle(w("记住窗口位置与尺寸", "Remember window position and size"), isOn: $preferences.values.rememberPosition)
            }
            Section(w("自动尺寸", "Automatic size")) {
                Stepper(w("宽度 \(Int(state.preferences.values.windowWidth)) pt", "Width \(Int(state.preferences.values.windowWidth)) pt"),
                        value: $preferences.values.windowWidth, in: 320...800, step: 10)
                Stepper(w("高度上限 \(Int(state.preferences.values.windowHeight)) pt", "Height limit \(Int(state.preferences.values.windowHeight)) pt"),
                        value: $preferences.values.windowHeight, in: 300...900, step: 10)
                Button(w("恢复自动尺寸", "Restore automatic sizing")) { state.setDefaultSize?() }
            }
        }
        .formStyle(.grouped)
    }

    private var reminders: some View {
        Form {
            Section(w("macOS 通知", "macOS notifications")) {
                LabeledContent(w("权限状态", "Permission"), value: state.notifications.permissionLabel(w))
                if state.notifications.authorization == .notDetermined {
                    Text(w("授权后，macOS 能在关闭待办窗口时发送任务通知。",
                           "Grant permission so macOS can deliver reminders with the task window closed."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(w("允许通知…", "Allow notifications…")) {
                        Task {
                            do { try await state.notifications.requestPermission() }
                            catch { feedback = error.localizedDescription }
                        }
                    }
                } else {
                    Button(w("打开系统通知设置", "Open System Notification Settings")) { state.notifications.openSystemSettings() }
                }
                Button(w("发送测试通知（5 秒）", "Send test notification (5 seconds)")) {
                    Task {
                        do { try await state.notifications.testNotification() }
                        catch NoticeError.unavailable {
                            feedback = w("请在系统设置中允许 LumaTodo 发送通知。", "Allow LumaTodo notifications in System Settings.")
                        } catch NoticeError.notConfirmed {
                            feedback = w("未能在 macOS 队列中确认测试请求。", "The test request could not be confirmed in the macOS queue.")
                        } catch { feedback = error.localizedDescription }
                    }
                }
                .disabled(state.notifications.testStatus == .submitting)
                if let status = state.notifications.testStatus {
                    Label(testStatusText(status), systemImage: testStatusSymbol(status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(w("声音、横幅与通知中心显示由 macOS 通知设置和专注模式控制。",
                       "macOS notification settings and Focus control sounds, banners and Notification Center."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(w("系统提醒队列", "System reminder queue")) {
                let queue = state.notifications.queue
                LabeledContent(w("已确认排队", "Confirmed pending"),
                               value: "\(queue.pendingCount) / \(NotificationManager.notificationLimit)")
                LabeledContent(w("等待补充的任务", "Tasks awaiting refill"), value: "\(queue.deferred.count)")
                LabeledContent(w("待重试的任务", "Tasks awaiting retry"), value: "\(queue.failures.count)")
                if let date = queue.next {
                    LabeledContent(w("最近一次提醒", "Next reminder"), value: dateLabel(date, timed: true, words: w))
                }
                if let check = queue.lastCheck {
                    LabeledContent(w("最近核对", "Last checked"), value: dateLabel(check, timed: true, words: w))
                }
                Button(w("重新核对", "Reconcile now")) { state.notifications.reconcile() }
                    .disabled(state.notifications.isSyncing)
                Text(w("应用运行时会补充后续提醒。关窗后仍会补充，退出期间由 macOS 投递已排队的提醒。",
                       "LumaTodo refills the queue while running, including with the panel hidden. macOS delivers queued reminders after quit."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(w("默认提醒", "Reminder defaults")) {
                Picker(w("提前时间", "Lead time"), selection: $preferences.values.defaultLead) {
                    ForEach([0, 5, 10, 30, 60], id: \.self) { Text(minutesLabel($0, words: w)).tag($0) }
                }
                Toggle(w("提醒声音", "Reminder sound"), isOn: $preferences.values.sound)
                Picker(w("稍后提醒默认时长", "Default snooze"), selection: $preferences.values.defaultSnooze) {
                    ForEach([5, 10, 30], id: \.self) { Text(w("\($0) 分钟", "\($0) min")).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var system: some View {
        Form {
            Section(w("应用", "Application")) {
                Toggle(w("登录时启动", "Launch at login"), isOn: Binding(
                    get: { [.enabled, .requiresApproval].contains(state.loginStatus) },
                    set: { value in
                        state.setLogin(value)
                        if let message = state.message { feedback = message; state.message = nil }
                    }
                ))
                if state.loginStatus == .requiresApproval {
                    Button(w("打开登录项设置", "Open Login Items Settings")) { SMAppService.openSystemSettingsLoginItems() }
                }
                Toggle(w("显示菜单栏图标", "Show menu bar icon"), isOn: $preferences.values.menuBar)
                Picker(w("语言", "Language"), selection: $preferences.values.language) {
                    Text("简体中文").tag(AppLanguage.chinese)
                    Text("English").tag(AppLanguage.english)
                }
            }
            Section(w("全局快捷键", "Global shortcut")) {
                LabeledContent(w("显示或隐藏待办", "Show or hide tasks")) {
                    Text(state.preferences.values.shortcut?.display ?? w("关闭", "Off"))
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Button(recording ? w("取消录制", "Cancel recording") : w("录制快捷键", "Record shortcut")) {
                        if recording { stopRecording() }
                        else { beginRecording() }
                    }
                    Button(w("恢复默认", "Reset")) { applyShortcut(Shortcut()) }
                    Button(w("关闭", "Disable")) {
                        stopRecording()
                        state.preferences.values.shortcut = nil
                        shortcutMessage = nil
                    }
                    .disabled(state.preferences.values.shortcut == nil)
                }
                if recording {
                    Text(w("按下包含 ⌘、⌥ 或 ⌃ 的组合键。按 Esc 取消。",
                           "Press a combination with ⌘, ⌥ or ⌃. Press Escape to cancel."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let problem = shortcutMessage ?? state.shortcut.error.map(shortcutError) {
                    Label(problem, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    private func testStatusText(_ status: TestReminderStatus) -> String {
        switch status {
        case .submitting: w("正在提交测试通知…", "Submitting test notification…")
        case .submitted(let date):
            w("macOS 已接受请求（\(dateLabel(date, timed: true, words: w, includeDay: false))）。点击通知以确认交互。",
              "macOS accepted the request at \(dateLabel(date, timed: true, words: w, includeDay: false)). Click the notification to confirm interaction.")
        case .interacted(let date):
            w("已收到通知交互（\(dateLabel(date, timed: true, words: w, includeDay: false))）。",
              "Notification interaction received at \(dateLabel(date, timed: true, words: w, includeDay: false)).")
        }
    }

    private func testStatusSymbol(_ status: TestReminderStatus) -> String {
        if case .interacted = status { return "checkmark.circle.fill" }
        return "bell"
    }

    private func beginRecording() {
        shortcutMessage = nil
        recording = true
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated {
                guard recording else { return false }
                if event.keyCode == 53 { stopRecording(); return true }
                guard let shortcut = Shortcut(event: event) else {
                    shortcutMessage = w("请使用有效的组合键。", "Use a valid key combination.")
                    return true
                }
                applyShortcut(shortcut)
                return true
            }
            return consumed ? nil : event
        }
    }

    private func stopRecording() {
        if let captureMonitor { NSEvent.removeMonitor(captureMonitor) }
        captureMonitor = nil
        recording = false
    }

    private func applyShortcut(_ shortcut: Shortcut) {
        if state.shortcut.change(to: shortcut) {
            shortcutMessage = nil
            state.preferences.values.shortcut = shortcut
            stopRecording()
        } else if let error = state.shortcut.error {
            shortcutMessage = shortcutError(error)
        }
    }

    private func shortcutError(_ code: OSStatus) -> String {
        w("快捷键无法注册，可能已被占用（\(code)）。", "Shortcut unavailable or already in use (\(code)).")
    }
}
