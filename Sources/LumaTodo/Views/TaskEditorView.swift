import SwiftUI

struct TaskEditorView: View {
    let state: AppState
    let taskID: UUID?
    private let sessionID: UUID?
    @State private var draft: TaskDraft
    @State private var originalDraft: TaskDraft
    @State private var attachments: TaskAttachmentDraft
    @State private var titleFocused = false
    @State private var customLead = ""
    @State private var validation: String?
    private var appearance = PanelAppearance()

    init(state: AppState, task: TaskItem?) {
        self.state = state
        taskID = task?.id
        sessionID = state.editor?.id
        let baseline = task.map(TaskDraft.init(task:)) ?? TaskDraft()
        _draft = State(initialValue: baseline)
        _originalDraft = State(initialValue: baseline)
        let saved = task.map { state.store.attachments(for: $0.id) } ?? []
        _attachments = State(initialValue: TaskAttachmentDraft(manager: state.store.attachmentManager, saved: saved))
    }

    private var w: Words { state.words }
    private let presets = [0, 5, 10, 30, 60]
    private let headerHeight: CGFloat = 54
    private let footerHeight: CGFloat = 53
    private var suggestedDue: Date { .now.addingTimeInterval(3600) }
    private var trimmedTitle: String { draft.title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDirty: Bool { draft != originalDraft || !customLead.isEmpty || attachments.isDirty }
    private var date: Binding<Date> {
        Binding(get: { draft.due ?? suggestedDue }, set: { draft.due = $0 })
    }

    private var expanded: Binding<Bool> {
        Binding(get: { state.editorExpanded }, set: { state.editorExpanded = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            separator
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    titleField
                    TaskAttachmentsView(notes: $draft.notes, attachments: attachments, words: w,
                                        onCancel: requestClose, onSave: save)
                    attachmentIssues
                    deadline
                    DisclosureGroup(w("高级设置", "Advanced settings"), isExpanded: expanded) {
                        advanced.padding(.top, 8)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(9)
                    .background(sectionFill, in: .rect(cornerRadius: 10))
                    if let validation {
                        Label(validation, systemImage: "exclamationmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 13)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    guard height > 0 else { return }
                    let ideal = max(420, ceil(height) + headerHeight + footerHeight + 1)
                    if state.editorPreferredHeight != ideal { state.editorPreferredHeight = ideal }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            separator
            footer
        }
        .onChange(of: isDirty, initial: true) { _, dirty in state.editorHasUnsavedChanges = dirty }
        .onDisappear {
            if state.editor?.id != sessionID { attachments.discard() }
        }
        .onExitCommand(perform: requestClose)
    }

    private var separator: some View {
        Rectangle().fill(appearance.line).frame(height: 0.5).padding(.horizontal, 15)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: requestClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 25, height: 25)
                    .contentShape(.circle)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(w("返回待办", "Back to tasks"))
            Text(taskID == nil ? w("新建任务", "New task") : w("编辑任务", "Edit task"))
                .font(.system(size: 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .overlay(WindowGrip())
            Spacer()
            if let taskID, state.store.item(taskID) != nil {
                Button(role: .destructive) { state.requestDeletion(taskID) } label: {
                    Image(systemName: "trash").font(.system(size: 12)).frame(width: 23, height: 23)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(appearance.secondary)
                .accessibilityLabel(w("删除任务", "Delete task"))
                .help(w("删除任务", "Delete task"))
                .disabled(attachments.importing)
            }
        }
        .padding(.horizontal, 13)
        .frame(height: headerHeight)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button(w("取消", "Cancel"), action: requestClose).buttonStyle(.bordered)
            if appearance.usesGlass(state.preferences.values) {
                saveButton.buttonStyle(.glassProminent)
            } else {
                saveButton.buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 15)
        .frame(height: footerHeight)
    }

    private var saveButton: some View {
        Button(w("保存任务", "Save Task"), action: save)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(trimmedTitle.isEmpty || attachments.importing)
            .help(w("保存任务（⌘↩）", "Save task (⌘Return)"))
    }

    private var titleField: some View {
        NativeTaskField(prompt: w("任务标题", "Task title"), text: $draft.title,
                        focusRequest: 1, focused: { titleFocused = $0 }, submit: save, escape: requestClose)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(sectionFill, in: .rect(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(titleFocused && state.dialog == nil ? appearance.accent.opacity(0.76) : appearance.line,
                                  lineWidth: titleFocused && state.dialog == nil ? 1.15 : 0.65)
                    .allowsHitTesting(false)
            }
    }

    @ViewBuilder
    private var attachmentIssues: some View {
        if !attachments.issues.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(w("附件提示", "Attachment issues"), systemImage: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button { attachments.clearIssues() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(w("关闭附件提示", "Dismiss attachment issues"))
                }
                ForEach(attachments.issues.prefix(4)) { issue in
                    Text(issue.text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
                if attachments.issues.count > 4 {
                    Text(w("另有 \(attachments.issues.count - 4) 个文件未能导入。",
                           "\(attachments.issues.count - 4) more files could not be imported."))
                        .font(.caption)
                }
            }
            .padding(8)
            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
        }
    }

    private var deadline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { draft.due != nil }, set: { enabled in setDate(enabled) })) {
                Label(w("截止日期", "Due date"), systemImage: "calendar")
                    .font(.system(size: 12, weight: .semibold))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            if draft.due != nil {
                Divider()
                HStack(spacing: 6) {
                    dateShortcut(w("今天", "Today"), offset: 0)
                    dateShortcut(w("明天", "Tomorrow"), offset: 1)
                    Spacer(minLength: 3)
                    DatePicker(w("截止日期", "Due date"), selection: date, displayedComponents: .date)
                        .datePickerStyle(.field)
                        .labelsHidden()
                }
                HStack {
                    Toggle(w("指定时间", "Set time"), isOn: Binding(get: { draft.hasTime }, set: { enabled in setTime(enabled) }))
                    Spacer()
                    if draft.hasTime {
                        DatePicker(w("截止时间", "Due time"), selection: date, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.field)
                            .labelsHidden()
                    }
                }
                .font(.system(size: 11))
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(sectionFill, in: .rect(cornerRadius: 10))
    }

    private func dateShortcut(_ title: String, offset: Int) -> some View {
        let calendar = Calendar.current
        let target = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: .now))
        let selected = draft.due.flatMap { due in target.map { calendar.isDate(due, inSameDayAs: $0) } } ?? false
        return Button(title) {
            guard let target else { return }
            let clock = calendar.dateComponents([.hour, .minute], from: draft.due ?? suggestedDue)
            draft.due = calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: target) ?? target
        }
        .font(.system(size: 11))
        .buttonStyle(.bordered)
        .foregroundStyle(selected ? appearance.accent : .primary)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Picker(w("优先级", "Priority"), selection: $draft.priority) {
                    ForEach(Priority.allCases) { Text($0.label(w)).tag($0) }
                }
                .fixedSize()
                TextField(w("分类或标签", "Category or tags"), text: $draft.tags)
                    .textFieldStyle(.roundedBorder)
            }
            if draft.due != nil {
                Picker(w("重复", "Repeat"), selection: $draft.rule.kind) {
                    ForEach(RepeatKind.allCases) { Text($0.label(w)).tag($0) }
                }
                if draft.rule.kind.isCustom {
                    Stepper(w("每 \(draft.rule.interval) 个单位", "Every \(draft.rule.interval) units"),
                            value: $draft.rule.interval, in: 1...365)
                }
            }
            Divider()
            deadlineReminders
            Divider()
            independentReminders
            reminderSummary
        }
        .controlSize(.small)
        .font(.system(size: 11))
    }

    private var deadlineReminders: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(w("截止提醒", "Deadline reminders")).font(.system(size: 12, weight: .semibold))
            if draft.hasTime && draft.due != nil {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 5) {
                    ForEach(presets, id: \.self) { lead in
                        Toggle(minutesLabel(lead, words: w), isOn: Binding(get: { draft.leads.contains(lead) }, set: { include in
                            if include { draft.leads.append(lead) }
                            else { draft.leads.removeAll { $0 == lead } }
                        }))
                    }
                }
                ForEach(draft.leads.filter { !presets.contains($0) }.sorted(), id: \.self) { lead in
                    HStack {
                        Text(minutesLabel(lead, words: w))
                        Spacer()
                        Button { draft.leads.removeAll { $0 == lead } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .accessibilityLabel(w("移除该提醒", "Remove this reminder"))
                    }
                }
                HStack {
                    TextField(w("自定义提前分钟数", "Custom minutes before"), text: $customLead)
                        .onSubmit { _ = addCustomLead() }
                    Button(w("添加", "Add")) { _ = addCustomLead() }
                        .disabled(customLead.isEmpty)
                }
            } else {
                Button(w("设置截止时间和提醒", "Set a deadline and reminder")) {
                    if draft.due == nil { setDate(true) }
                    setTime(true)
                    draft.leads = [state.preferences.values.defaultLead]
                }
                .buttonStyle(.link)
            }
        }
    }

    private var independentReminders: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(w("独立提醒", "Independent reminders")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    draft.independentReminders.append(IndependentReminder(fire: suggestedDue))
                } label: {
                    Label(w("添加独立提醒", "Add independent reminder"), systemImage: "plus.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }
            ForEach($draft.independentReminders) { $reminder in
                let id = reminder.id
                HStack {
                    DatePicker(w("独立提醒时间", "Independent reminder time"), selection: $reminder.fire,
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.field)
                        .labelsHidden()
                    Spacer()
                    Button {
                        draft.independentReminders.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(w("移除独立提醒", "Remove independent reminder"))
                }
            }
        }
    }

    private var reminderSummary: some View {
        let manager = state.notifications
        let saved = taskID.flatMap(state.store.item)
        let scheduleSaved = saved.map {
            $0.due == draft.due && $0.hasTime == draft.hasTime && $0.leads == draft.leads.sorted() && $0.rule == draft.rule
                && TaskDraft(task: $0).independentReminders == draft.independentReminders
        } == true
        return VStack(alignment: .leading, spacing: 5) {
            LabeledContent(w("通知权限", "Notifications"), value: manager.permissionLabel(w))
            LabeledContent(w("提醒状态", "Reminders"), value: reminderQueueLabel(saved, scheduleSaved: scheduleSaved))
            if !manager.authorized {
                Button(w("通知设置", "Notification settings")) {
                    if manager.authorization == .notDetermined { Task { await state.authorizeNotifications() } }
                    else { manager.openSystemSettings() }
                }
                .buttonStyle(.link)
            }
            if scheduleSaved, let saved, let next = manager.pending(for: saved)?.next {
                LabeledContent(w("下一次提醒", "Next reminder"), value: dateLabel(next, timed: true, words: w))
            }
            if draft.hasTime, let due = draft.due, !draft.leads.isEmpty, !scheduleSaved || draft.rule.kind == .none {
                let deadline = OccurrenceCalendar.normalizedDeadline(due, hasTime: true, rule: draft.rule,
                                                                     timeZone: saved?.timeZone ?? .current)
                ForEach(draft.leads.sorted(), id: \.self) { lead in
                    LabeledContent(minutesLabel(lead, words: w),
                                   value: dateLabel(deadline.addingTimeInterval(-Double(lead) * 60), timed: true, words: w))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(appearance.secondary)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
    }

    private var sectionFill: Color { .primary.opacity(appearance.dark ? 0.055 : 0.037) }

    private func reminderQueueLabel(_ saved: TaskItem?, scheduleSaved: Bool) -> String {
        let manager = state.notifications
        guard !draft.leads.isEmpty || !draft.independentReminders.isEmpty else { return w("关闭", "Off") }
        if saved?.isCompleted == true { return w("任务已完成", "Task completed") }
        if !manager.authorized { return w("未获授权，系统通知不可用", "Permission required. System notifications are unavailable.") }
        guard scheduleSaved, let saved else { return w("保存后核对系统队列", "Save to verify the system queue") }
        if manager.failures.contains(saved.id) { return w("提交未确认，等待重试", "Submission unconfirmed. Will retry.") }
        if let pending = manager.pending(for: saved) {
            if manager.queue.deferred.contains(saved.id) {
                return w("已排队 \(pending.count) 条，等待补充", "\(pending.count) pending. More awaiting refill.")
            }
            if pending.late > 0 && pending.next == nil { return w("macOS 正在处理到期提醒", "macOS is handling due requests") }
            return w("macOS 已确认 \(pending.count) 条", "macOS verified \(pending.count) pending")
        }
        if manager.isSyncing { return w("正在核对", "Checking") }
        if manager.queue.deferred.contains(saved.id) { return w("等待队列空间", "Waiting for queue space") }
        return w("没有待触发的请求", "No pending requests")
    }

    private func setDate(_ enabled: Bool) {
        if enabled { draft.due = suggestedDue }
        else {
            draft.due = nil
            draft.hasTime = false
            draft.leads = []
            draft.rule = RepeatRule()
            customLead = ""
        }
    }

    private func setTime(_ enabled: Bool) {
        draft.hasTime = enabled
        if enabled {
            let calendar = Calendar.current
            let clock = calendar.dateComponents([.hour, .minute], from: suggestedDue)
            if let day = draft.due {
                draft.due = calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: day) ?? day
            }
        } else {
            draft.leads = []
            customLead = ""
        }
    }

    private func addCustomLead() -> Bool {
        guard let value = Int(customLead.trimmingCharacters(in: .whitespaces)),
              (1...TaskDraft.maximumLead).contains(value) else {
            validation = w("请输入 1–525600 分钟。", "Enter 1–525,600 minutes.")
            return false
        }
        if !draft.leads.contains(value) { draft.leads.append(value) }
        validation = nil
        customLead = ""
        return true
    }

    private func requestClose() {
        guard !TaskPanel.hasActiveComposition else { return }
        if isDirty { state.confirmsDiscard = true }
        else { discardAndClose() }
    }

    private func discardAndClose() {
        attachments.discard()
        state.closeEditor()
    }

    private func save() {
        guard !TaskPanel.hasActiveComposition, !trimmedTitle.isEmpty, !attachments.importing else { return }
        if !customLead.isEmpty && !addCustomLead() { return }
        if let taskID {
            guard let item = state.store.item(taskID), TaskDraft(task: item) == originalDraft else {
                validation = w("此任务在编辑时已更新。你的草稿仍在这里，请返回后重新打开任务以载入最新内容。",
                               "This task changed during editing. Your draft is still here. Reopen the task to load the latest information.")
                return
            }
        }
        validation = nil
        if state.save(draft, id: taskID, attachments: attachments.changes) {
            attachments.markSaved()
            state.closeEditor()
        }
    }
}
