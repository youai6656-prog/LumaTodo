import SwiftUI

struct TaskPanelView: View {
    @Bindable var state: AppState
    @Bindable private var preferences: Preferences
    @State private var quickTitle = ""
    @State private var quickFocused = false
    @State private var undoTimer: Task<Void, Never>?
    private var appearance = PanelAppearance()

    init(state: AppState) {
        self.state = state
        preferences = state.preferences
    }

    private var w: Words { state.words }
    private var prefs: PreferencesValues { preferences.values }
    private var animation: Animation? { appearance.animation(prefs) }
    private var noticesUnavailable: Bool {
        state.notifications.authorization != nil &&
            (!state.notifications.authorized || !state.notifications.alertsEnabled) && state.listing.hasReminders
    }

    var body: some View {
        Group {
            if let target = state.editor {
                TaskEditorView(state: state, task: target.taskID.flatMap(state.store.item))
                    .id(target.id)
            } else if state.mini {
                mini
            } else {
                full
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(FrostedSurface(values: prefs, radius: state.mini ? 23 : 26, editor: state.editor != nil))
        .tint(appearance.accent)
        .environment(\.locale, w.locale)
        .confirmationDialog(w("稍后提醒", "Snooze reminder"),
                            isPresented: Binding(get: { state.pendingSnooze != nil },
                                                 set: { if !$0 { state.pendingSnooze = nil } }),
                            titleVisibility: .visible, presenting: state.pendingSnooze) { action in
            ForEach([prefs.defaultSnooze] + [5, 10, 30].filter { $0 != prefs.defaultSnooze }, id: \.self) { minutes in
                Button(w("\(minutes) 分钟", "\(minutes) min")) { state.snooze(action, minutes: minutes) }
            }
            Button(w("取消", "Cancel"), role: .cancel) { state.pendingSnooze = nil }
        } message: { action in
            Text(state.store.item(action.taskID)?.title ?? "")
        }
        .alert("LumaTodo", isPresented: Binding(get: { state.message != nil },
                                               set: { if !$0 { state.message = nil } })) {
            Button(w("好", "OK"), role: .cancel) { state.message = nil }
        } message: { Text(state.message ?? "") }
        .onChange(of: sizing, initial: true) { _, size in state.onLayoutChange?(size.height, size.editing) }
        .onChange(of: state.undoTaskID) { _, id in
            undoTimer?.cancel()
            if id != nil {
                undoTimer = Task {
                    try? await Task.sleep(for: .seconds(9))
                    if !Task.isCancelled { withAnimation(animation) { state.undoTaskID = nil } }
                }
            }
        }
    }

    private struct Sizing: Equatable {
        let height: CGFloat
        let editing: Bool
    }

    private var sizing: Sizing {
        if state.editor != nil { return Sizing(height: state.editorPreferredHeight, editing: true) }
        return Sizing(height: state.preferredPanelHeight(notice: noticesUnavailable), editing: false)
    }

    private var full: some View {
        VStack(spacing: 0) {
            header
            if state.searching { searchBar }
            if noticesUnavailable { noticeBanner }
            ScrollViewReader { proxy in
                ScrollView {
                    if state.visibleSections.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: PanelLayout.sectionGap) {
                            ForEach(state.visibleSections) { section in taskSection(section) }
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, PanelLayout.listInsets / 2)
                    }
                }
                .defaultScrollAnchor(.top)
                .onChange(of: state.selectedTask) { _, id in
                    if let id { withAnimation(animation) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            if state.undoTaskID != nil { undoBanner.transition(.opacity) }
            quickEntry
                .padding(.horizontal, 13)
                .frame(height: PanelLayout.footerHeight)
        }
    }

    private var header: some View {
        let done = state.listing.completedToday
        let total = done + state.listing.remainingToday
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.today, format: .dateTime.month().day().weekday(.wide).locale(w.locale))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appearance.secondary)
                    .lineLimit(1)
                Text(w("今天", "Today"))
                    .font(.system(size: 25, weight: .semibold))
                    .tracking(-0.85)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 5) {
                    if total > 0 {
                        ZStack {
                            Circle().strokeBorder(appearance.line, lineWidth: 1.5)
                            Circle().trim(from: 0, to: CGFloat(done) / CGFloat(total))
                                .stroke(appearance.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .padding(0.75)
                        }
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    }
                    Text(total > 0 ? w("已完成 \(done)/\(total) 项", "\(done) of \(total) completed")
                                    : w("今天没有到期任务", "Nothing due today"))
                        .font(.system(size: 11))
                        .foregroundStyle(appearance.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WindowGrip())
            GlassEffectContainer(spacing: 5) {
                HStack(spacing: 6) {
                    if appearance.usesGlass(prefs) {
                        addButton.buttonStyle(.glassProminent).buttonBorderShape(.circle)
                        tuckButton.buttonStyle(.glass).buttonBorderShape(.circle).tint(nil as Color?)
                        actionsMenu.menuStyle(.borderlessButton).buttonStyle(.glass)
                    } else {
                        addButton.buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                        tuckButton.buttonStyle(.bordered).buttonBorderShape(.circle)
                        actionsMenu.menuStyle(.borderlessButton).buttonStyle(.bordered)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 13)
        .frame(height: PanelLayout.headerHeight, alignment: .top)
        .overlay(alignment: .bottom) {
            Rectangle().fill(appearance.line).frame(height: 0.5).padding(.horizontal, 15)
        }
    }

    private var addButton: some View {
        Button { state.newTask() } label: {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
        }
        .help(w("新建任务（⌘N）", "New task (⌘N)"))
        .accessibilityLabel(w("新建任务", "New task"))
    }

    private var tuckButton: some View {
        Button { state.tuckWindow?() } label: {
            Image(systemName: "rectangle.rightthird.inset.filled").font(.system(size: 11, weight: .medium))
        }
        .help(w("收起到屏幕边缘", "Tuck to screen edge"))
        .accessibilityLabel(w("收起窗口", "Tuck window"))
    }

    private var actionsMenu: some View {
        Menu {
            Button { state.searching ? state.closeSearch() : state.openSearch() } label: {
                Label(w("搜索任务", "Search tasks"), systemImage: "magnifyingglass")
            }
            Picker(w("排序", "Sort"), selection: $preferences.values.sort) {
                Text(w("按日期", "By date")).tag(TaskOrder.date)
                Text(w("按优先级", "By priority")).tag(TaskOrder.priority)
            }
            Divider()
            Toggle(w("始终置顶", "Always on top"), isOn: $preferences.values.alwaysOnTop)
            Button { state.setMini(true) } label: {
                Label(w("迷你模式", "Mini mode"), systemImage: "arrow.down.right.and.arrow.up.left")
            }
            Button { state.showSettings?() } label: { Label(w("设置…", "Settings…"), systemImage: "gearshape") }
            Button { state.hideWindow?() } label: { Label(w("隐藏窗口", "Hide window"), systemImage: "eye.slash") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                .frame(width: 19, height: 22)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(w("更多选项", "More options"))
        .accessibilityLabel(w("更多选项", "More options"))
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(appearance.secondary).accessibilityHidden(true)
            NativeTaskField(prompt: w("搜索标题、描述或标签", "Search titles, notes or tags"), text: $state.search,
                            focusRequest: state.searchFocus, submit: {}, escape: state.closeSearch)
                .frame(height: 21)
            Button(action: state.closeSearch) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(appearance.secondary)
                .accessibilityLabel(w("关闭搜索", "Close search"))
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.primary.opacity(0.055), in: .rect(cornerRadius: 9))
        .padding(.horizontal, 15)
        .frame(height: PanelLayout.searchHeight)
    }

    private var noticeBanner: some View {
        Button {
            if state.notifications.authorization == .notDetermined { Task { await state.authorizeNotifications() } }
            else { state.notifications.openSystemSettings() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bell.slash")
                Text(state.notifications.authorization == .notDetermined
                     ? w("允许 macOS 发送任务提醒", "Allow macOS task notifications")
                     : w("桌面通知受限，检查系统设置", "Desktop alerts limited. Check System Settings."))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "arrow.up.right")
            }
            .padding(.horizontal, 9)
            .frame(height: 25)
            .background(.orange.opacity(appearance.dark ? 0.15 : 0.10), in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: .medium))
        .padding(.horizontal, 15)
        .frame(height: PanelLayout.noticeHeight)
    }

    private var emptyState: some View {
        HStack(spacing: 11) {
            Image(systemName: state.search.isEmpty ? "checkmark.circle" : "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(appearance.accent)
                .frame(width: 34, height: 34)
                .background(appearance.accent.opacity(0.09), in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.search.isEmpty ? w("还没有任务", "No tasks yet") : w("没有匹配的任务", "No matching tasks"))
                    .font(.system(size: 13, weight: .semibold))
                Text(state.search.isEmpty ? w("在下方输入第一项待办。", "Add your first task below.")
                                          : w("试试其他关键词。", "Try a different search."))
                    .foregroundStyle(appearance.secondary)
                    .font(.system(size: 11))
            }
            Spacer(minLength: 0)
            if state.search.isEmpty {
                Button(w("新建", "New"), action: state.newTask)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .padding(.horizontal, 17)
        .frame(height: PanelLayout.emptyHeight)
    }

    private func taskSection(_ section: PanelSection) -> some View {
        let group = section.group
        let closed = state.isCollapsed(group)
        return LazyVStack(spacing: PanelLayout.rowGap) {
            Button {
                withAnimation(animation) {
                    if closed { state.collapsedGroups.remove(group) }
                    else { state.collapsedGroups.insert(group) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: closed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 9)
                    Text(group.label(w)).font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(section.tasks.count.formatted(.number.locale(w.locale)))
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                }
                .foregroundStyle(group == .overdue ? Color(nsColor: .systemRed) : appearance.secondary)
                .padding(.horizontal, 8)
                .frame(height: PanelLayout.sectionHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(closed ? w("已折叠", "Collapsed") : w("已展开", "Expanded"))
            .disabled(!state.search.isEmpty)
            if !closed {
                ForEach(section.tasks) { task in
                    TaskRow(state: state, task: task, overdue: group == .overdue, animation: animation)
                        .id(task.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
        }
    }

    private var quickEntry: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(appearance.accent).accessibilityHidden(true)
            NativeTaskField(prompt: w("快速添加任务…", "Quick add a task…"), text: $quickTitle,
                            focused: { quickFocused = $0 }, submit: quickAdd) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            .frame(height: 22)
            Button(action: quickAdd) {
                Image(systemName: "return").font(.system(size: 10, weight: .semibold))
                    .frame(width: 25, height: 22)
                    .background(.primary.opacity(0.055), in: .rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appearance.secondary)
            .disabled(quickTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(w("保存快速任务", "Save quick task"))
            .help(w("按回车添加", "Press Return to add"))
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .modifier(GlassInputSurface(values: prefs, focused: quickFocused))
    }

    private func quickAdd() {
        guard !TaskPanel.hasActiveComposition else { return }
        withAnimation(animation) {
            if state.quickAdd(quickTitle) {
                state.collapsedGroups.remove(.upcoming)
                state.search = ""
                quickTitle = ""
            }
        }
    }

    private var undoBanner: some View {
        HStack(spacing: 7) {
            Label(w("任务已完成", "Task completed"), systemImage: "checkmark")
            Spacer()
            Button(w("撤销", "Undo")) { withAnimation(animation) { state.undoCompletion() } }
                .buttonStyle(.link)
            Button { state.undoTaskID = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel(w("关闭", "Dismiss"))
        }
        .font(.system(size: 11))
        .padding(.horizontal, 17)
        .frame(height: PanelLayout.undoHeight)
        .foregroundStyle(appearance.secondary)
    }

    private var mini: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(w("接下来", "Up next"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(appearance.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(WindowGrip())
                if state.undoTaskID != nil {
                    Button { withAnimation(animation) { state.undoCompletion() } } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help(w("撤销完成", "Undo completion"))
                        .accessibilityLabel(w("撤销完成", "Undo completion"))
                }
                Button { state.tuckWindow?() } label: { Image(systemName: "rectangle.rightthird.inset.filled") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(w("收起窗口", "Tuck window"))
                Button { state.setMini(false) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless)
                    .help(w("展开窗口", "Expand window"))
                    .accessibilityLabel(w("展开窗口", "Expand window"))
            }
            if let task = state.listing.featured {
                HStack(spacing: 8) {
                    CompleteButton(title: task.title, done: false, words: w) {
                        if let item = state.store.item(task.id) { withAnimation(animation) { state.complete(item) } }
                    }
                    Button { state.setMini(false); state.edit(task.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            if let due = task.due {
                                TimelineView(.everyMinute) { context in
                                    Text(miniDeadline(task, due: due, now: context.date))
                                        .font(.system(size: 11)).foregroundStyle(appearance.secondary).lineLimit(1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(w("编辑任务", "Edit task"))
                }
                .padding(.horizontal, 7)
                .frame(height: 50)
                .background(.primary.opacity(0.035), in: .rect(cornerRadius: 12))
            } else {
                quickEntry
            }
        }
        .padding(.horizontal, 13)
    }

    private func miniDeadline(_ task: PanelTask, due: Date, now: Date) -> String {
        if task.hasTime, due > now, due.timeIntervalSince(now) < 3600 {
            let minutes = max(1, Int(ceil(due.timeIntervalSince(now) / 60)))
            return w("还剩 \(minutes) 分钟", "Due in \(minutes) min")
        }
        return dateLabel(due, timed: task.hasTime, words: w, timeZone: task.hasTime ? nil : task.timeZone)
    }
}

struct EdgeTabView: View {
    let state: AppState
    let edge: ScreenEdge
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Image(systemName: edge == .left ? "chevron.right" : "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .modifier(FrostedSurface(values: state.preferences.values, radius: 13))
        .help(state.words("展开 LumaTodo", "Expand LumaTodo"))
        .accessibilityLabel(state.words("展开 LumaTodo", "Expand LumaTodo"))
    }
}

struct WindowGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Grip() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Grip: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
