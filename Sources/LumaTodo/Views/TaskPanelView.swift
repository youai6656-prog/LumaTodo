import SwiftUI

struct TaskPanelView: View {
    @Bindable var state: AppState
    @Bindable private var preferences: Preferences
    @State private var quickTitle = ""
    @State private var quickFocused = false
    @FocusState private var dialogCancelFocused: Bool
    private let onDialogChange: () -> Void
    private let snapshot: Bool
    private var appearance = PanelAppearance()

    init(state: AppState, snapshot: Bool = false, onDialogChange: @escaping () -> Void = {}) {
        self.state = state
        preferences = state.preferences
        self.snapshot = snapshot
        self.onDialogChange = onDialogChange
    }

    private var w: Words { state.words }
    private var prefs: PreferencesValues { preferences.values }
    private var animation: Animation? { appearance.animation(prefs, intensity: preferences.motionIntensity) }
    private var noticesUnavailable: Bool {
        state.notifications.authorization != nil &&
            (!state.notifications.authorized || !state.notifications.alertsEnabled) && state.listing.hasReminders
    }

    var body: some View {
        if snapshot {
            contents.tint(appearance.accent).environment(\.locale, w.locale)
        } else {
            contents
                .disabled(state.dialog != nil)
                .allowsHitTesting(state.dialog == nil)
                .accessibilityHidden(state.dialog != nil)
                .modifier(FrostedSurface(values: prefs, radius: cornerRadius, editor: state.editor != nil))
                .overlay {
                    if let dialog = state.dialog { dialogOverlay(dialog) }
                }
                .tint(appearance.accent)
                .environment(\.locale, w.locale)
                .onChange(of: sizing, initial: true) { _, size in state.onLayoutChange?(size.height, size.editing) }
                .onChange(of: state.dialog) {
                    dialogCancelFocused = false
                    onDialogChange()
                }
        }
    }

    private var contents: some View {
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
    }

    private var cornerRadius: CGFloat { state.mini ? 23 : 26 }

    private func dialogOverlay(_ dialog: PanelDialog) -> some View {
        let compact = state.mini && state.editor == nil
        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.black.opacity(appearance.dark ? 0.32 : 0.16))
                .accessibilityHidden(true)
            VStack(spacing: compact ? 6 : 10) {
                dialogMessage(dialog)
                HStack(spacing: 7) { dialogButtons(dialog) }
                    .controlSize(.small)
            }
            .padding(compact ? 10 : 15)
            .frame(maxWidth: 308)
            .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 17))
            .overlay {
                RoundedRectangle(cornerRadius: 17).strokeBorder(appearance.line)
                    .allowsHitTesting(false)
            }
            .padding(compact ? 8 : 16)
            .accessibilityElement(children: .contain)
        }
        .task(id: dialog) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            dialogCancelFocused = true
        }
    }

    private func dialogMessage(_ dialog: PanelDialog) -> some View {
        let title: String
        let detail: String
        switch dialog {
        case .deletion(let id):
            title = w("删除这项任务？", "Delete this task?")
            detail = state.store.item(id)?.title ?? ""
        case .discard:
            title = w("放弃未保存的更改？", "Discard unsaved changes?")
            detail = w("本次编辑和新添加的附件将被放弃。", "Your edits and newly imported attachments will be discarded.")
        case .snooze:
            title = w("稍后提醒", "Snooze reminder")
            detail = state.pendingSnooze.flatMap { state.store.item($0.taskID)?.title } ?? ""
        case .message(let message):
            title = "LumaTodo"
            detail = message
        }
        return VStack(spacing: 4) {
            Text(title).font(.system(size: 14, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(appearance.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(state.mini ? 2 : 4)
            }
        }
    }

    @ViewBuilder private func dialogButtons(_ dialog: PanelDialog) -> some View {
        let cancel: String = switch dialog {
        case .discard: w("继续编辑", "Keep Editing")
        case .message: w("好", "OK")
        default: w("取消", "Cancel")
        }
        Button(cancel, role: .cancel) { state.dismissDialog() }
            .buttonStyle(.bordered)
            .tint(Color(nsColor: .secondaryLabelColor))
            .focused($dialogCancelFocused)
            .keyboardShortcut(.cancelAction)
        switch dialog {
        case .deletion(let id):
            Button(w("删除", "Delete"), role: .destructive) {
                withAnimation(animation) { state.confirmDeletion(id) }
            }
            .buttonStyle(.bordered)
            .tint(Color(nsColor: .systemRed))
        case .discard:
            Button(w("放弃更改", "Discard Changes"), role: .destructive) { state.closeEditor() }
                .buttonStyle(.bordered)
                .tint(Color(nsColor: .systemRed))
        case .snooze:
            if let action = state.pendingSnooze {
                ForEach([prefs.defaultSnooze] + [5, 10, 30].filter { $0 != prefs.defaultSnooze }, id: \.self) { minutes in
                    Button(w("\(minutes) 分钟", "\(minutes) min")) {
                        state.pendingSnooze = nil
                        state.snooze(action, minutes: minutes)
                    }
                    .buttonStyle(.bordered)
                }
            }
        case .message: EmptyView()
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
            if snapshot {
                snapshotList
            } else {
                let scrolling = state.listShouldScroll(notice: noticesUnavailable)
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
                    .scrollDisabled(!scrolling)
                    .scrollIndicators(scrolling ? .visible : .hidden, axes: .vertical)
                    .onScrollGeometryChange(for: PanelListMetrics.self) {
                        PanelListMetrics(content: $0.contentSize.height, viewport: $0.containerSize.height,
                                         offset: max(0, $0.contentOffset.y + $0.contentInsets.top), scrolling: scrolling)
                    } action: { _, metrics in state.observeList(metrics) }
                    .onChange(of: state.selectedTask) { _, id in
                        if let id { withAnimation(animation) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
            if let undo = state.presentedUndo { undoBanner(undo) }
            quickEntry
                .padding(.horizontal, 13)
                .frame(height: PanelLayout.footerHeight)
        }
    }

    private struct SnapshotLine: Identifiable {
        let section: PanelSection
        let task: PanelTask?
        let top: CGFloat
        var id: String { task?.id.uuidString ?? section.group.rawValue }
    }

    private var snapshotList: some View {
        GeometryReader { viewport in
            if state.visibleSections.isEmpty {
                emptyState
            } else {
                ZStack(alignment: .topLeading) {
                    ForEach(snapshotLines(height: viewport.size.height)) { line in
                        Group {
                            if let task = line.task {
                                TaskRow(state: state, task: task, overdue: line.section.group == .overdue,
                                        animation: nil, snapshot: true)
                            } else {
                                sectionHeading(line.section)
                            }
                        }
                        .frame(width: max(0, viewport.size.width - 26))
                        .offset(x: 13, y: line.top)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            }
        }
    }

    private func snapshotLines(height: CGFloat) -> [SnapshotLine] {
        let offset = state.panelScrollOffset
        var y = PanelLayout.listInsets / 2
        var lines: [SnapshotLine] = []
        for section in state.visibleSections {
            if y + PanelLayout.sectionHeight > offset && y < offset + height {
                lines.append(SnapshotLine(section: section, task: nil, top: y - offset))
            }
            y += PanelLayout.sectionHeight
            if !state.isCollapsed(section.group) {
                for task in section.tasks {
                    y += PanelLayout.rowGap
                    guard y < offset + height else { return lines }
                    let rowHeight = task.height(compact: prefs.compact)
                    if y + rowHeight > offset {
                        lines.append(SnapshotLine(section: section, task: task, top: y - offset))
                    }
                    y += rowHeight
                }
            }
            y += PanelLayout.sectionGap
        }
        return lines
    }

    private var header: some View {
        let done = state.listing.completedToday
        let total = done + state.listing.remainingToday
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if snapshot {
                    Image(systemName: "rectangle.rightthird.inset.filled")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 19, height: 19)
                        .background(.primary.opacity(0.09), in: Circle())
                } else if appearance.usesGlass(prefs) {
                    tuckButton.buttonStyle(.glass).buttonBorderShape(.circle).tint(nil as Color?)
                } else {
                    tuckButton.buttonStyle(.bordered).buttonBorderShape(.circle)
                }
                Text(state.today, format: .dateTime.month().day().weekday(.wide).locale(.autoupdatingCurrent))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appearance.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay { if !snapshot { WindowGrip() } }
                TimelineView(.everyMinute) { context in
                    Text(context.date, format: Date.FormatStyle(date: .omitted, time: .shortened,
                                                                locale: .autoupdatingCurrent, timeZone: .autoupdatingCurrent))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(appearance.secondary)
                        .fixedSize()
                        .frame(minWidth: 58, alignment: .trailing)
                }
                if snapshot {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 19, weight: .medium))
                        Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                            .frame(width: 19, height: 22)
                    }
                    .foregroundStyle(appearance.accent)
                } else {
                    headerActions
                }
            }
            .controlSize(.small)
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(w("今天", "Today"))
                    .font(.system(size: 24, weight: .semibold))
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
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay { if !snapshot { WindowGrip() } }
        }
        .padding(.horizontal, 15)
        .padding(.top, 10)
        .frame(height: PanelLayout.headerHeight, alignment: .top)
        .overlay(alignment: .bottom) {
            Rectangle().fill(appearance.line).frame(height: 0.5).padding(.horizontal, 15)
        }
    }

    private var headerActions: some View {
        GlassEffectContainer(spacing: 5) {
            HStack(spacing: 6) {
                if appearance.usesGlass(prefs) {
                    addButton.buttonStyle(.glassProminent).buttonBorderShape(.circle)
                    actionsMenu.menuStyle(.borderlessButton).buttonStyle(.glass)
                } else {
                    addButton.buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                    actionsMenu.menuStyle(.borderlessButton).buttonStyle(.bordered)
                }
            }
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
            Button { state.tuckWindow?() } label: {
                Label(w("收起窗口", "Tuck window"), systemImage: "rectangle.rightthird.inset.filled")
            }
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
            Group {
                if snapshot {
                    Text(state.search.isEmpty ? w("搜索标题、描述或标签", "Search titles, notes or tags") : state.search)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    NativeTaskField(prompt: w("搜索标题、描述或标签", "Search titles, notes or tags"), text: $state.search,
                                    focusRequest: state.searchFocus, submit: {}, escape: state.closeSearch)
                }
            }
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
        LazyVStack(spacing: PanelLayout.rowGap) {
            sectionHeading(section)
            if !state.isCollapsed(section.group) {
                ForEach(section.tasks) { task in
                    TaskRow(state: state, task: task, overdue: section.group == .overdue, animation: animation)
                        .id(task.id)
                        .transition(.opacity)
                }
            }
        }
    }

    private func sectionHeading(_ section: PanelSection) -> some View {
        let group = section.group
        let closed = state.isCollapsed(group)
        return Button {
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
    }

    private var quickEntry: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(appearance.accent).accessibilityHidden(true)
            Group {
                if snapshot {
                    Text(w("快速添加任务…", "Quick add a task…"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    NativeTaskField(prompt: w("快速添加任务…", "Quick add a task…"), text: $quickTitle,
                                    focused: { quickFocused = $0 }, submit: quickAdd) {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                }
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
        .modifier(GlassInputSurface(values: prefs, focused: quickFocused && state.dialog == nil))
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

    private func undoBanner(_ action: TaskUndo) -> some View {
        HStack(spacing: 7) {
            Label(action.isDeletion ? w("任务已删除", "Task deleted") : w("任务已完成", "Task completed"),
                  systemImage: action.isDeletion ? "trash" : "checkmark")
            Spacer()
            Button(w("撤销", "Undo"), action: state.undoLastAction)
                .buttonStyle(.link)
            Button { state.dismissUndo() } label: { Image(systemName: "xmark") }
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
                    .overlay { if !snapshot { WindowGrip() } }
                if let undo = state.undoAction {
                    let label = undo.isDeletion ? w("撤销删除", "Undo deletion") : w("撤销完成", "Undo completion")
                    Button(action: state.undoLastAction) { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help(label)
                        .accessibilityLabel(label)
                }
                Button { state.tuckWindow?() } label: { Image(systemName: "rectangle.rightthird.inset.filled") }
                    .buttonStyle(.borderless)
                    .help(w("收起到屏幕边缘", "Tuck to screen edge"))
                    .accessibilityLabel(w("收起窗口", "Tuck window"))
                Button { state.setMini(false) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless)
                    .help(w("展开窗口", "Expand window"))
                    .accessibilityLabel(w("展开窗口", "Expand window"))
            }
            if let task = state.featuredDuringMotion {
                HStack(spacing: 8) {
                    CompleteButton(title: task.title, done: state.completionFeedback(for: task.id) ?? false, words: w,
                                   intensity: preferences.motionIntensity, animated: appearance.allowsMotion(prefs)) {
                        if let item = state.store.item(task.id) { state.complete(item, feedback: true) }
                    }
                    .disabled(state.completionFeedback(for: task.id) != nil)
                    Button { state.setMini(false); state.edit(task.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                .strikethrough(state.completionFeedback(for: task.id) == true)
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
    let interaction: EdgeTabInteraction
    let edge: ScreenEdge
    let open: () -> Void
    @State private var hovering = false
    private var appearance = PanelAppearance()

    init(state: AppState, interaction: EdgeTabInteraction, edge: ScreenEdge, open: @escaping () -> Void) {
        self.state = state
        self.interaction = interaction
        self.edge = edge
        self.open = open
    }

    var body: some View {
        let animated = appearance.allowsMotion(state.preferences.values)
        Button(action: open) {
            Image(systemName: edge == .left ? "chevron.right" : "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? appearance.accent : appearance.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(FrostedSurface(values: state.preferences.values, radius: EdgePlacement.size.width / 2))
                .overlay {
                    Capsule()
                        .fill(.radialGradient(colors: [.white.opacity(hovering ? 0.13 : 0), .clear],
                                              center: UnitPoint(x: edge == .left ? 0.72 : 0.28, y: 0.5),
                                              startRadius: 0, endRadius: 27))
                        .overlay { Capsule().strokeBorder(.white.opacity(hovering ? 0.24 : 0), lineWidth: 0.75) }
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, 0.7)
                .padding(.vertical, 2)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(animated ? .easeOut(duration: 0.12) : nil, value: hovering)
        .accessibilityHidden(interaction.isPreview)
        .help(state.words("点按展开，按住可同时向内和上下拖动", "Click to open, or pull inward and move up or down together"))
        .accessibilityLabel(state.words("展开 LumaTodo", "Expand LumaTodo"))
        .accessibilityHint(state.words("按住可同时向内和上下拖动", "Pull inward and move up or down together"))
    }
}

struct WindowGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Grip() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Grip: NSView {
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            (window as? TaskPanel)?.grips.remove(self)
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            (window as? TaskPanel)?.grips.add(self)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
