import Foundation

struct PanelListMetrics: Equatable {
    let content: CGFloat
    let viewport: CGFloat
    let offset: CGFloat
    let scrolling: Bool
}

enum PanelLayout {
    static let minimumWidth: CGFloat = 320
    static let minimumHeight: CGFloat = 244
    static let editorMinimumWidth: CGFloat = 420
    static let editorMinimumHeight: CGFloat = 420
    static let editorMaximumHeight: CGFloat = 600
    static let miniSize = CGSize(width: 300, height: 120)
    static let headerHeight: CGFloat = 85
    static let footerHeight: CGFloat = 64
    static let sectionHeight: CGFloat = 27
    static let rowGap: CGFloat = 2
    static let sectionGap: CGFloat = 6
    static let listInsets: CGFloat = 20
    static let emptyHeight: CGFloat = 95
    static let searchHeight: CGFloat = 42
    static let noticeHeight: CGFloat = 34
    static let undoHeight: CGFloat = 31

    static func rowHeight(compact: Bool, notes: Bool, metadata: Bool) -> CGFloat {
        (compact ? 32 : 38) + (notes && !compact ? 14 : 0) + (metadata ? 13 : 0)
    }

    struct SectionSize {
        let rows: Int
        let height: CGFloat

        static let collapsed = SectionSize(rows: 0, height: 0)
    }

    static func height(sections: [SectionSize], searching: Bool = false, notice: Bool = false,
                       undo: Bool = false, limit: CGFloat, available: CGFloat) -> CGFloat {
        let rowsVisible = sections.contains { $0.rows > 0 }
        let list = max(rowsVisible ? 110 : emptyHeight, listContentHeight(sections: sections))
        return min(max(minimumHeight, chromeHeight(searching: searching, notice: notice, undo: undo) + list),
                   max(minimumHeight, limit), available)
    }

    static func listContentHeight(sections: [SectionSize]) -> CGFloat {
        guard !sections.isEmpty else { return emptyHeight }
        return sections.reduce(listInsets) { total, section in
            total + sectionHeight + section.height + rowGap * CGFloat(section.rows)
        } + CGFloat(max(0, sections.count - 1)) * sectionGap
    }

    static func chromeHeight(searching: Bool, notice: Bool, undo: Bool) -> CGFloat {
        headerHeight + footerHeight + (searching ? searchHeight : 0)
            + (notice ? noticeHeight : 0) + (undo ? undoHeight : 0)
    }

    static func editorSize(browsingWidth: CGFloat, contentHeight: CGFloat) -> CGSize {
        let height = contentHeight.isFinite ? contentHeight : editorMinimumHeight
        return CGSize(width: min(460, max(editorMinimumWidth, browsingWidth)),
                      height: min(editorMaximumHeight, max(editorMinimumHeight, height)))
    }

    static func resized(_ frame: CGRect, width: CGFloat, height: CGFloat, in visible: CGRect) -> CGRect {
        let alignRight = frame.midX >= visible.midX
        let x = alignRight ? frame.maxX - width : frame.minX
        return reachable(CGRect(x: x, y: frame.maxY - height, width: width, height: height), in: visible)
    }

    static func reachable(_ frame: CGRect, in visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - height),
                      width: width, height: height)
    }
}

struct PanelTask: Identifiable {
    let id: UUID
    let title: String
    let notes: String
    let tags: String
    let due: Date?
    let hasTime: Bool
    let isCompleted: Bool
    let priority: Priority
    let reminderEnabled: Bool
    let attachmentCount: Int
    let scheduleID: UUID
    let repeatKind: RepeatKind
    let timeZone: TimeZone
    let groupingDue: Date?
    let sortIndex: Double
    let completedAt: Date?

    init(_ item: TaskItem, calendar: Calendar, attachmentCount: Int) {
        id = item.id
        title = item.title
        notes = item.notes
        tags = item.tags
        due = item.due
        hasTime = item.hasTime
        isCompleted = item.isCompleted
        priority = item.priority
        reminderEnabled = item.hasReminders && !item.isCompleted
        self.attachmentCount = attachmentCount
        scheduleID = item.scheduleID
        repeatKind = item.rule.kind
        timeZone = item.timeZone
        groupingDue = dateForGrouping(item, calendar: calendar)
        sortIndex = item.sortIndex
        completedAt = item.completedAt
    }

    func precedes(_ other: PanelTask, by order: TaskOrder) -> Bool {
        if let completedAt, let otherDate = other.completedAt, completedAt != otherDate { return completedAt > otherDate }
        if order == .priority, priority != other.priority { return priority.rawValue > other.priority.rawValue }
        let left = groupingDue ?? .distantFuture
        let right = other.groupingDue ?? .distantFuture
        if left != right { return left < right }
        if priority != other.priority { return priority.rawValue > other.priority.rawValue }
        return sortIndex > other.sortIndex
    }

    var hasMetadata: Bool { due != nil || !tags.isEmpty || reminderEnabled || attachmentCount > 0 }

    func matches(_ term: String) -> Bool {
        term.isEmpty || [title, notes, tags].contains { $0.localizedStandardContains(term) }
    }

    func height(compact: Bool) -> CGFloat {
        PanelLayout.rowHeight(compact: compact, notes: !notes.isEmpty, metadata: hasMetadata)
    }
}

struct PanelListing {
    private var groups: [TaskGroup: [PanelTask]]
    let featured: PanelTask?
    let completedToday: Int
    let remainingToday: Int
    let hasReminders: Bool
    let nextDeadline: Date?

    @MainActor
    init(items: [TaskItem], now: Date, order: TaskOrder, attachmentCount: (UUID) -> Int = { _ in 0 }) {
        let calendar = Calendar.current
        var groups: [TaskGroup: [PanelTask]] = [:]
        var featured: PanelTask?
        var next: Date?
        var completed = 0
        var remaining = 0
        var reminders = false
        for item in items {
            let row = PanelTask(item, calendar: calendar, attachmentCount: attachmentCount(item.id))
            let due = row.groupingDue
            let group = TaskGroup.group(isCompleted: row.isCompleted, due: due, now: now, calendar: calendar)
            groups[group, default: []].append(row)
            if row.isCompleted {
                if let due, calendar.isDate(due, inSameDayAs: now) { completed += 1 }
            } else {
                if let current = featured {
                    if row.precedes(current, by: .priority) { featured = row }
                } else { featured = row }
                if let due {
                    if calendar.isDate(due, inSameDayAs: now) { remaining += 1 }
                    if due > now { next = min(next ?? due, due) }
                }
                if row.reminderEnabled { reminders = true }
            }
        }
        self.groups = groups.mapValues { $0.sorted { $0.precedes($1, by: order) } }
        self.featured = featured
        completedToday = completed
        remainingToday = remaining
        hasReminders = reminders
        nextDeadline = next
    }

    func sections(matching search: String) -> [PanelSection] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return TaskGroup.allCases.compactMap { group in
            guard let all = groups[group] else { return nil }
            let rows = term.isEmpty ? all : all.filter { $0.matches(term) }
            return rows.isEmpty ? nil : PanelSection(group: group, tasks: rows)
        }
    }
}

struct PanelSection: Identifiable {
    let group: TaskGroup
    let tasks: [PanelTask]
    private let normalSize: PanelLayout.SectionSize
    private let compactSize: PanelLayout.SectionSize
    var id: TaskGroup { group }

    init(group: TaskGroup, tasks: [PanelTask]) {
        self.group = group
        self.tasks = tasks
        normalSize = PanelLayout.SectionSize(rows: tasks.count, height: tasks.reduce(0) { $0 + $1.height(compact: false) })
        compactSize = PanelLayout.SectionSize(rows: tasks.count, height: tasks.reduce(0) { $0 + $1.height(compact: true) })
    }

    func size(compact: Bool, collapsed: Bool) -> PanelLayout.SectionSize {
        if collapsed { return .collapsed }
        return compact ? compactSize : normalSize
    }
}
