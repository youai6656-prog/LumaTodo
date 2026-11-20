import SwiftUI

struct CompleteButton: View {
    let title: String
    let done: Bool
    let words: Words
    let intensity: MotionIntensity
    let animated: Bool
    let perform: () -> Void
    @State private var hover = false
    private var appearance = PanelAppearance()

    init(title: String, done: Bool, words: Words, intensity: MotionIntensity, animated: Bool,
         perform: @escaping () -> Void) {
        self.title = title
        self.done = done
        self.words = words
        self.intensity = intensity
        self.animated = animated
        self.perform = perform
    }

    var body: some View {
        Button {
            if let event = NSApp.currentEvent, event.type == .leftMouseUp, event.clickCount > 1 { return }
            perform()
        } label: {
            ZStack {
                Circle().strokeBorder(hover || done ? appearance.accent : appearance.secondary, lineWidth: 1.35)
                Circle().fill(appearance.accent)
                    .scaleEffect(done ? 1 : 0.18)
                    .opacity(done ? 1 : 0)
                    .animation(animated ? .easeOut(duration: 0.105) : nil, value: done)
                CompletionCheck().trim(from: 0, to: done ? 1 : 0)
                    .stroke(appearance.dark ? Color(white: 0.13) : .white,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .animation(animated ? .easeOut(duration: done ? Motion.completionDraw : Motion.completionErase)
                        .delay(done ? Motion.completionDrawDelay : 0) : nil, value: done)
                if hover && !done {
                    CompletionCheck()
                        .stroke(appearance.accent.opacity(0.64), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: 17, height: 17)
            .frame(width: 25, height: 27)
            .contentShape(.rect)
        }
        .buttonStyle(CompletionPressStyle(intensity: intensity, animated: animated))
        .onHover { hover = $0 }
        .help(done ? words("恢复任务", "Restore task") : words("完成任务", "Complete task"))
        .accessibilityLabel(done ? words("恢复 \(title)", "Restore \(title)") : words("完成 \(title)", "Complete \(title)"))
    }
}

private struct CompletionPressStyle: ButtonStyle {
    let intensity: MotionIntensity
    let animated: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && animated ? 1 - 0.065 * intensity.decoration : 1)
            .animation(animated ? .easeOut(duration: 0.085) : nil, value: configuration.isPressed)
    }
}

private struct CompletionCheck: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.width * 0.27, y: rect.height * 0.50))
            path.addLine(to: CGPoint(x: rect.width * 0.44, y: rect.height * 0.66))
            path.addLine(to: CGPoint(x: rect.width * 0.73, y: rect.height * 0.36))
        }
    }
}

struct TaskRow: View {
    let state: AppState
    let task: PanelTask
    let overdue: Bool
    let animation: Animation?
    let snapshot: Bool
    @State private var hovered = false
    @State private var arrivalShown = false
    @FocusState private var rowFocused: Bool
    private var appearance = PanelAppearance()

    init(state: AppState, task: PanelTask, overdue: Bool, animation: Animation?, snapshot: Bool = false) {
        self.state = state
        self.task = task
        self.overdue = overdue
        self.animation = animation
        self.snapshot = snapshot
    }

    private var w: Words { state.words }
    private var compact: Bool { state.preferences.values.compact }
    private var highlight: Bool { hovered || rowFocused || state.selectedTask == task.id }
    private var feedback: Bool? { state.completionFeedback(for: task.id) }
    private var displayedDone: Bool { feedback ?? task.isCompleted }
    private var departing: Bool { !snapshot && state.departingRows.contains(task.id) }
    private var arriving: Bool { !snapshot && state.arrivingRows.contains(task.id) }

    var body: some View {
        HStack(spacing: 5) {
            CompleteButton(title: task.title, done: displayedDone, words: w, intensity: state.preferences.motionIntensity,
                           animated: appearance.allowsMotion(state.preferences.values), perform: toggle)
                .disabled(feedback != nil)
            Button { state.edit(task.id) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(task.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(displayedDone ? appearance.secondary : .primary)
                            .overlay {
                                Rectangle().fill(appearance.secondary).frame(height: 0.75)
                                    .scaleEffect(x: displayedDone ? 1 : 0, anchor: .leading)
                                    .allowsHitTesting(false)
                            }
                            .animation(animation, value: displayedDone)
                            .help(task.title)
                        if task.priority != .none {
                            Image(systemName: "flag.fill").font(.system(size: 8))
                                .foregroundStyle(priorityColor)
                                .accessibilityLabel(w("优先级 \(task.priority.label(w))", "\(task.priority.label(w)) priority"))
                        }
                    }
                    if !compact && !task.notes.isEmpty {
                        Text(task.notes).lineLimit(1).font(.system(size: 11)).foregroundStyle(appearance.secondary)
                    }
                    if task.hasMetadata { metadata }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .focused($rowFocused)
            .accessibilityHint(w("编辑任务", "Edit task"))
            if snapshot {
                Image(systemName: "ellipsis").frame(width: 23).opacity(highlight ? 1 : 0)
            } else {
                Menu { rowActions } label: { Image(systemName: "ellipsis").frame(width: 17) }
                    .menuIndicator(.hidden)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .opacity(highlight ? 1 : 0)
                    .accessibilityLabel(w("任务操作", "Task actions"))
            }
        }
        .padding(.horizontal, 5)
        .frame(height: task.height(compact: compact))
        .background(highlight ? appearance.accent.opacity(appearance.dark ? 0.10 : 0.07) : .clear,
                    in: .rect(cornerRadius: 9))
        .overlay(alignment: .bottom) {
            Rectangle().fill(appearance.line.opacity(0.65)).frame(height: 0.5)
                .padding(.leading, 34).padding(.trailing, 5).allowsHitTesting(false)
        }
        .onHover { hovered = $0 }
        .opacity(departing || (arriving && !arrivalShown) ? 0 : 1)
        .animation(Motion.rowDepartureAnimation, value: departing)
        .task(id: arriving) {
            guard arriving else { arrivalShown = false; return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(Motion.rowArrivalAnimation) { arrivalShown = true }
        }
        .contextMenu { rowActions }
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            if let date = task.due {
                Text(dateLabel(date, timed: task.hasTime, words: w, timeZone: task.hasTime ? nil : task.timeZone))
                    .foregroundStyle(overdue ? Color(nsColor: .systemRed) : appearance.secondary)
                    .lineLimit(1)
            }
            if task.repeatKind != .none {
                Image(systemName: "repeat").help(task.repeatKind.label(w))
                    .accessibilityLabel(task.repeatKind.label(w))
            }
            if task.reminderEnabled {
                Image(systemName: reminderSymbol).help(reminderStatus)
                    .accessibilityLabel(reminderStatus)
            }
            if task.attachmentCount > 0 {
                Label(task.attachmentCount.formatted(.number.locale(w.locale)), systemImage: "paperclip")
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
                    .help(w("\(task.attachmentCount) 个附件", "\(task.attachmentCount) attachments"))
                    .accessibilityLabel(w("\(task.attachmentCount) 个附件", "\(task.attachmentCount) attachments"))
            }
            if !task.tags.isEmpty { Text(task.tags).lineLimit(1) }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(appearance.secondary)
    }

    private var priorityColor: Color {
        if appearance.highContrast { return .primary }
        return switch task.priority {
        case .high: appearance.dark ? Color(red: 0.94, green: 0.64, blue: 0.64) : Color(red: 0.61, green: 0.23, blue: 0.26)
        case .medium: appearance.dark ? Color(red: 0.85, green: 0.73, blue: 0.51) : Color(red: 0.49, green: 0.34, blue: 0.14)
        default: appearance.accent
        }
    }

    private var hasPendingReminder: Bool { state.notifications.queue.pending[task.id]?.version == task.scheduleID }

    private var reminderSymbol: String {
        if !state.notifications.authorized || !state.notifications.alertsEnabled { return "bell.slash" }
        if hasPendingReminder, !state.notifications.failures.contains(task.id) { return "bell" }
        return "bell.badge"
    }

    private var reminderStatus: String {
        let manager = state.notifications
        if !manager.authorized || !manager.alertsEnabled { return w("桌面通知受限", "Desktop alerts limited") }
        if manager.isSyncing && !hasPendingReminder { return w("正在核对系统队列", "Checking the system queue") }
        if manager.failures.contains(task.id) { return w("部分提醒提交失败，应用将重试", "Some reminders failed to schedule. LumaTodo will retry.") }
        if manager.queue.deferred.contains(task.id) { return w("后续提醒等待队列补充", "Later reminders are waiting for queue space") }
        if hasPendingReminder { return w("已安排系统提醒", "System reminders scheduled") }
        return w("没有未来的待触发提醒", "No upcoming reminders")
    }

    @ViewBuilder private var rowActions: some View {
        Button(w("编辑", "Edit")) { state.edit(task.id) }
        Button(task.isCompleted ? w("恢复", "Restore") : w("完成", "Complete"), action: toggle)
        Divider()
        Button(w("删除…", "Delete…"), role: .destructive) { state.requestDeletion(task.id) }
    }

    private func toggle() {
        guard feedback == nil, let item = state.store.item(task.id), item.isCompleted == task.isCompleted else { return }
        if task.isCompleted { state.restore(item, feedback: true) }
        else { state.complete(item, feedback: true) }
    }
}
