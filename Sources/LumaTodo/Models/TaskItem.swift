import Foundation
import Observation
import SwiftData

enum Priority: Int, CaseIterable, Identifiable {
    case none, low, medium, high
    var id: Self { self }

    func label(_ words: Words) -> String {
        switch self {
        case .none: words("无", "None")
        case .low: words("低", "Low")
        case .medium: words("中", "Medium")
        case .high: words("高", "High")
        }
    }
}

enum RepeatKind: String, Codable, CaseIterable, Identifiable {
    case none, daily, weekly, weekdays, days, weeks, months
    var id: Self { self }
    var isCustom: Bool { [.days, .weeks, .months].contains(self) }

    func label(_ words: Words) -> String {
        switch self {
        case .none: words("不重复", "Never")
        case .daily: words("每天", "Daily")
        case .weekly: words("每周", "Weekly")
        case .weekdays: words("工作日", "Weekdays")
        case .days: words("自定义天数", "Custom days")
        case .weeks: words("自定义周数", "Custom weeks")
        case .months: words("自定义月数", "Custom months")
        }
    }
}

struct RepeatRule: Codable, Equatable {
    var kind: RepeatKind = .none
    var interval = 1
}

struct Snooze: Codable, Equatable, Identifiable {
    var id = UUID()
    let occurrence: Date
    let fire: Date
    var independentReminderID: UUID? = nil
}

struct IndependentReminder: Codable, Equatable, Identifiable {
    var id = UUID()
    var fire: Date

    static func normalized(_ values: [Self]) -> [Self] {
        var dates = Set<Date>()
        var ids = Set<UUID>()
        return values.compactMap { reminder -> Self? in
            let seconds = reminder.fire.timeIntervalSince1970
            guard seconds.isFinite else { return nil }
            var reminder = reminder
            reminder.fire = Date(timeIntervalSince1970: floor(seconds / 60) * 60)
            guard !ids.contains(reminder.id), dates.insert(reminder.fire).inserted else { return nil }
            ids.insert(reminder.id)
            return reminder
        }.sorted { $0.fire < $1.fire }
    }
}

private struct ReminderExtras: Codable {
    var snoozes: [Snooze] = []
    var independent: [IndependentReminder] = []
}

struct TaskDraft: Equatable {
    var title = ""
    var notes = ""
    var tags = ""
    var priority: Priority = .none
    var due: Date?
    var hasTime = false
    var leads: [Int] = []
    var independentReminders: [IndependentReminder] = []
    var rule = RepeatRule()

    static let maximumLead = 365 * 24 * 60

    init(title: String = "") { self.title = title }

    init(task: TaskItem) {
        title = task.title
        notes = task.notes
        tags = task.tags
        priority = task.priority
        due = task.due
        hasTime = task.hasTime
        leads = task.leads
        independentReminders = task.independentReminders
        rule = task.rule
    }
}

// SwiftData’s public backing interface keeps the same model usable with Xcode and the standalone SDK.
final class TaskItem: PersistentModel, Identifiable {
    static let detachedBacking = NativeBackingFactory(TaskItem.self)

    var persistentBackingData: any BackingData<TaskItem>
    private let registrar = ObservationRegistrar()

    static var schemaMetadata: [Schema.PropertyMetadata] {
        [
            .init(name: "id", keypath: \TaskItem.id, metadata: Schema.Attribute(.unique)),
            .init(name: "title", keypath: \TaskItem.title),
            .init(name: "notes", keypath: \TaskItem.notes, defaultValue: ""),
            .init(name: "tags", keypath: \TaskItem.tags, defaultValue: ""),
            .init(name: "createdAt", keypath: \TaskItem.createdAt),
            .init(name: "updatedAt", keypath: \TaskItem.updatedAt),
            .init(name: "due", keypath: \TaskItem.due),
            .init(name: "hasTime", keypath: \TaskItem.hasTime, defaultValue: false),
            .init(name: "completedAt", keypath: \TaskItem.completedAt),
            .init(name: "priorityValue", keypath: \TaskItem.priorityValue, defaultValue: 0),
            .init(name: "leadMinutes", keypath: \TaskItem.leadMinutes, defaultValue: [] as [Int]),
            .init(name: "repeatType", keypath: \TaskItem.repeatType, defaultValue: "none"),
            .init(name: "repeatInterval", keypath: \TaskItem.repeatInterval, defaultValue: 1),
            .init(name: "repeatAnchor", keypath: \TaskItem.repeatAnchor),
            .init(name: "timeZoneID", keypath: \TaskItem.timeZoneID, defaultValue: ""),
            .init(name: "scheduleID", keypath: \TaskItem.scheduleID),
            .init(name: "sortIndex", keypath: \TaskItem.sortIndex),
            .init(name: "snoozeData", keypath: \TaskItem.snoozeData, defaultValue: Data()),
            .init(name: "originID", keypath: \TaskItem.originID),
            .init(name: "originScheduleID", keypath: \TaskItem.originScheduleID),
            .init(name: "previousDue", keypath: \TaskItem.previousDue),
            .init(name: "advancedDue", keypath: \TaskItem.advancedDue),
        ]
    }

    init(backingData: any BackingData<TaskItem>) {
        persistentBackingData = backingData
    }

    convenience init(title: String, now: Date) {
        let data: any BackingData<TaskItem> = Self.detachedBacking.make()
        data.setValue(forKey: \.id, to: UUID())
        data.setValue(forKey: \.scheduleID, to: UUID())
        data.setValue(forKey: \.title, to: title)
        data.setValue(forKey: \.createdAt, to: now)
        data.setValue(forKey: \.updatedAt, to: now)
        data.setValue(forKey: \.sortIndex, to: now.timeIntervalSinceReferenceDate)
        data.setValue(forKey: \.notes, to: "")
        data.setValue(forKey: \.tags, to: "")
        data.setValue(forKey: \.hasTime, to: false)
        data.setValue(forKey: \.priorityValue, to: 0)
        data.setValue(forKey: \.leadMinutes, to: [])
        data.setValue(forKey: \.repeatType, to: "none")
        data.setValue(forKey: \.repeatInterval, to: 1)
        data.setValue(forKey: \.timeZoneID, to: "")
        data.setValue(forKey: \.snoozeData, to: Data())
        data.setValue(forKey: \.due, to: nil)
        data.setValue(forKey: \.completedAt, to: nil)
        data.setValue(forKey: \.repeatAnchor, to: nil)
        data.setValue(forKey: \.originID, to: nil)
        data.setValue(forKey: \.originScheduleID, to: nil)
        data.setValue(forKey: \.previousDue, to: nil)
        data.setValue(forKey: \.advancedDue, to: nil)
        self.init(backingData: data)
    }

    private subscript<Value: Codable>(keyPath: ReferenceWritableKeyPath<TaskItem, Value>) -> Value {
        get {
            registrar.access(self, keyPath: keyPath)
            return getValue(forKey: keyPath)
        }
        set {
            registrar.withMutation(of: self, keyPath: keyPath) {
                setValue(forKey: keyPath, to: newValue)
            }
        }
    }

    var id: UUID {
        get { self[\.id] }
        set { self[\.id] = newValue }
    }

    var title: String {
        get { self[\.title] }
        set { self[\.title] = newValue }
    }

    var notes: String {
        get { self[\.notes] }
        set { self[\.notes] = newValue }
    }

    var tags: String {
        get { self[\.tags] }
        set { self[\.tags] = newValue }
    }

    var createdAt: Date {
        get { self[\.createdAt] }
        set { self[\.createdAt] = newValue }
    }

    var updatedAt: Date {
        get { self[\.updatedAt] }
        set { self[\.updatedAt] = newValue }
    }

    var due: Date? {
        get { self[\.due] }
        set { self[\.due] = newValue }
    }

    var hasTime: Bool {
        get { self[\.hasTime] }
        set { self[\.hasTime] = newValue }
    }

    var completedAt: Date? {
        get { self[\.completedAt] }
        set { self[\.completedAt] = newValue }
    }

    var priorityValue: Int {
        get { self[\.priorityValue] }
        set { self[\.priorityValue] = newValue }
    }

    var leadMinutes: [Int] {
        get { self[\.leadMinutes] }
        set { self[\.leadMinutes] = newValue }
    }

    var repeatType: String {
        get { self[\.repeatType] }
        set { self[\.repeatType] = newValue }
    }

    var repeatInterval: Int {
        get { self[\.repeatInterval] }
        set { self[\.repeatInterval] = newValue }
    }

    var repeatAnchor: Date? {
        get { self[\.repeatAnchor] }
        set { self[\.repeatAnchor] = newValue }
    }

    var timeZoneID: String {
        get { self[\.timeZoneID] }
        set { self[\.timeZoneID] = newValue }
    }

    var scheduleID: UUID {
        get { self[\.scheduleID] }
        set { self[\.scheduleID] = newValue }
    }

    var sortIndex: Double {
        get { self[\.sortIndex] }
        set { self[\.sortIndex] = newValue }
    }

    var snoozeData: Data {
        get { self[\.snoozeData] }
        set { self[\.snoozeData] = newValue }
    }

    var originID: UUID? {
        get { self[\.originID] }
        set { self[\.originID] = newValue }
    }

    var originScheduleID: UUID? {
        get { self[\.originScheduleID] }
        set { self[\.originScheduleID] = newValue }
    }

    var previousDue: Date? {
        get { self[\.previousDue] }
        set { self[\.previousDue] = newValue }
    }

    var advancedDue: Date? {
        get { self[\.advancedDue] }
        set { self[\.advancedDue] = newValue }
    }

    var priority: Priority {
        get { Priority(rawValue: priorityValue) ?? .none }
        set { priorityValue = newValue.rawValue }
    }

    var rule: RepeatRule {
        get { RepeatRule(kind: RepeatKind(rawValue: repeatType) ?? .none, interval: repeatInterval) }
        set {
            repeatType = newValue.kind.rawValue
            repeatInterval = newValue.interval
        }
    }

    var leads: [Int] {
        get { leadMinutes }
        set { leadMinutes = Array(Set(newValue.filter { (0...TaskDraft.maximumLead).contains($0) })).sorted() }
    }

    var isCompleted: Bool { completedAt != nil }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    var hasReminders: Bool { !leads.isEmpty || !independentReminders.isEmpty }

    // Copy persisted fields verbatim, including the recurrence cursor and legacy reminder data.
    func detachedCopy() -> TaskItem {
        let copy = TaskItem(title: title, now: createdAt)
        copy.id = id
        copy.notes = notes
        copy.tags = tags
        copy.updatedAt = updatedAt
        copy.due = due
        copy.hasTime = hasTime
        copy.completedAt = completedAt
        copy.priorityValue = priorityValue
        copy.leadMinutes = leadMinutes
        copy.repeatType = repeatType
        copy.repeatInterval = repeatInterval
        copy.repeatAnchor = repeatAnchor
        copy.timeZoneID = timeZoneID
        copy.scheduleID = scheduleID
        copy.sortIndex = sortIndex
        copy.snoozeData = snoozeData
        copy.originID = originID
        copy.originScheduleID = originScheduleID
        copy.previousDue = previousDue
        copy.advancedDue = advancedDue
        return copy
    }

    var snoozes: [Snooze] {
        get { reminderExtras.snoozes }
        set {
            var extras = reminderExtras
            extras.snoozes = newValue
            reminderExtras = extras
        }
    }

    var independentReminders: [IndependentReminder] {
        get { reminderExtras.independent }
        set {
            var extras = reminderExtras
            extras.independent = IndependentReminder.normalized(newValue)
            reminderExtras = extras
        }
    }

    private var reminderExtras: ReminderExtras {
        get {
            let data = snoozeData
            guard !data.isEmpty else { return ReminderExtras() }
            let decoder = JSONDecoder()
            // LumaTodo 1.1 wrote an array directly. Keep the same SwiftData entity and read either form.
            if let first = data.first, first == UInt8(ascii: "["),
               let snoozes = try? decoder.decode([Snooze].self, from: data) {
                return ReminderExtras(snoozes: snoozes)
            }
            return (try? decoder.decode(ReminderExtras.self, from: data)) ?? ReminderExtras()
        }
        set {
            let encoder = JSONEncoder()
            if newValue.independent.isEmpty {
                snoozeData = newValue.snoozes.isEmpty ? Data() : (try? encoder.encode(newValue.snoozes)) ?? Data()
            } else {
                snoozeData = (try? encoder.encode(newValue)) ?? Data()
            }
        }
    }
}
