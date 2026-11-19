import Foundation
import Observation
import SwiftData

@MainActor @Observable
final class TaskStore {
    // Adding an independent entity lets SwiftData infer the 1.1 → 1.2 migration without altering TaskItem.
    private static let schema = Schema([TaskItem.self, Attachment.self])
    private(set) var items: [TaskItem] = []
    @ObservationIgnored let container: ModelContainer
    @ObservationIgnored let attachmentManager: AttachmentManager
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var byID: [UUID: TaskItem] = [:]
    @ObservationIgnored private var attachmentsByTask: [UUID: [Attachment]] = [:]
    @ObservationIgnored private var referencesByPath: [String: Int] = [:]
    @ObservationIgnored var onChange: (() -> Void)?

    init(url: URL) throws {
        attachmentManager = AttachmentManager(databaseURL: url)
        let schema = Self.schema
        _ = TaskItem.detachedBacking
        _ = Attachment.detachedBacking
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: config)
        context = ModelContext(container)
        context.autosaveEnabled = false
        items = try context.fetch(FetchDescriptor<TaskItem>(sortBy: [SortDescriptor(\TaskItem.sortIndex, order: .reverse)]))
        byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let records = try context.fetch(FetchDescriptor<Attachment>(sortBy: [SortDescriptor(\Attachment.createdAt)]))
        attachmentsByTask = Dictionary(grouping: records, by: \.taskID)
        for record in records { referencesByPath[record.relativePath, default: 0] += 1 }
        // Keep even an orphan metadata row's file for recovery; only unreferenced managed copies can be deleted.
        attachmentManager.reconcile(committed: records.map(\.info))
    }

    static func applicationStoreURL() throws -> URL {
        let library = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let directory = library.appending(path: Bundle.main.bundleIdentifier ?? "io.lumatodo.mac", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "Tasks.store")
    }

    func item(_ id: UUID) -> TaskItem? { byID[id] }

    func attachments(for taskID: UUID) -> [AttachmentInfo] {
        attachmentsByTask[taskID, default: []].map(\.info)
    }

    func attachmentCount(for taskID: UUID) -> Int {
        attachmentsByTask[taskID, default: []].count
    }

    @discardableResult
    func save(_ draft: TaskDraft, editing item: TaskItem? = nil, attachments changes: AttachmentChanges = .init(),
              now: Date = .now, timeZone: TimeZone = .current) throws -> TaskItem {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw TaskError.emptyTitle }
        if let item, byID[item.id] !== item { throw TaskError.invalidOccurrence }
        let task = item ?? TaskItem(title: title, now: now)
        let removed = attachmentsByTask[task.id, default: []].filter { changes.removing.contains($0.id) }
        guard removed.count == changes.removing.count,
              Set(changes.adding.map(\.id)).count == changes.adding.count else { throw AttachmentError.invalidChange }
        try attachmentManager.promote(changes.adding)
        let added = changes.adding.map { Attachment(info: $0.info, taskID: task.id) }
        var rule = draft.due == nil ? RepeatRule() : draft.rule
        rule.interval = rule.kind.isCustom ? min(365, max(1, rule.interval)) : 1
        let deadlineChanged = item == nil || task.due != draft.due || task.hasTime != draft.hasTime
        let dateChanged = deadlineChanged || task.rule != rule
        let zone = deadlineChanged ? timeZone : task.timeZone
        let due = draft.due.map {
            OccurrenceCalendar.normalizedDeadline($0, hasTime: draft.hasTime, rule: rule, timeZone: zone)
        }
        let leads = draft.hasTime && due != nil ? draft.leads : []
        let independent = IndependentReminder.normalized(draft.independentReminders)
        if item == nil { context.insert(task) }
        if dateChanged || task.leads != Array(Set(leads)).sorted() || task.independentReminders != independent {
            task.scheduleID = UUID()
            task.snoozes = []
        }
        if dateChanged {
            task.repeatAnchor = due
            task.timeZoneID = zone.identifier
        }
        task.title = title
        task.notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        task.tags = draft.tags.trimmingCharacters(in: .whitespacesAndNewlines)
        task.due = due
        task.hasTime = due != nil && draft.hasTime
        task.priority = draft.priority
        task.leads = leads
        task.independentReminders = independent
        task.rule = rule
        task.updatedAt = now
        do {
            try commit(inserting: item == nil ? task : nil, addingAttachments: added, removingAttachments: removed)
        } catch {
            attachmentManager.restoreStaging(changes.adding)
            throw error
        }
        return task
    }

    @discardableResult
    func complete(_ task: TaskItem, occurrence: Date? = nil, now: Date = .now) throws -> TaskItem {
        guard !task.isCompleted else { return task }
        let completed: TaskItem
        var copiedAttachments: [Attachment] = []
        if let due = task.due, task.rule.kind != .none {
            let target = occurrence ?? due
            let recurrence = OccurrenceCalendar(anchor: task.repeatAnchor ?? due, rule: task.rule, timeZone: task.timeZone)
            // Manual completion of an overdue series advances past missed occurrences.
            let lowerBound = max(now, target).addingTimeInterval(1)
            guard let next = recurrence.first(onOrAfter: lowerBound)?.date else { throw TaskError.invalidOccurrence }
            completed = TaskItem(title: task.title, now: task.createdAt)
            completed.notes = task.notes
            completed.tags = task.tags
            completed.priority = task.priority
            completed.leads = task.leads
            completed.independentReminders = task.independentReminders
            completed.due = target
            completed.hasTime = task.hasTime
            completed.timeZoneID = task.timeZoneID
            completed.originID = task.id
            completed.originScheduleID = task.scheduleID
            completed.previousDue = due
            completed.advancedDue = next
            context.insert(completed)
            // The completed occurrence and the continuing series independently refer to the same managed file.
            copiedAttachments = attachments(for: task.id).map { Attachment(info: $0.copiedMetadata(), taskID: completed.id) }
            task.due = next
            task.independentReminders = []
            task.snoozes = task.snoozes.filter { $0.independentReminderID == nil && $0.occurrence >= next }
        } else {
            completed = task
            task.snoozes = []
        }
        task.updatedAt = now
        completed.completedAt = now
        completed.updatedAt = now
        try commit(inserting: completed === task ? nil : completed, addingAttachments: copiedAttachments)
        return completed
    }

    func restore(_ task: TaskItem, now: Date = .now) throws {
        guard task.isCompleted else { return }
        if let originID = task.originID, let origin = item(originID),
           origin.scheduleID == task.originScheduleID, origin.due == task.advancedDue,
           task.updatedAt == task.completedAt {
            origin.due = task.previousDue
            origin.independentReminders = IndependentReminder.normalized(origin.independentReminders + task.independentReminders)
            origin.updatedAt = now
            try delete(task)
        } else {
            task.completedAt = nil
            task.updatedAt = now
            task.originID = nil
            task.originScheduleID = nil
            task.previousDue = nil
            task.advancedDue = nil
            if task.due != nil { task.scheduleID = UUID() }
            try commit()
        }
    }

    func delete(_ task: TaskItem) throws {
        let id = task.id
        context.delete(task)
        try commit(removing: (id, task), removingAttachments: attachmentsByTask[id, default: []])
    }

    func snooze(_ task: TaskItem, occurrence: Date, minutes: Int, now: Date = .now,
                independentReminderID: UUID? = nil) throws {
        guard [5, 10, 30].contains(minutes), !task.isCompleted else { return }
        let remaining = task.snoozes.filter {
            $0.fire > now && ($0.occurrence != occurrence || $0.independentReminderID != independentReminderID)
        }
        let snooze = Snooze(occurrence: occurrence, fire: now.addingTimeInterval(Double(minutes) * 60),
                            independentReminderID: independentReminderID)
        task.snoozes = remaining + [snooze]
        task.updatedAt = now
        try commit()
    }

    func isCurrent(_ task: TaskItem, scheduleID: UUID, occurrence: Date) -> Bool {
        guard !task.isCompleted, task.scheduleID == scheduleID, let due = task.due, occurrence >= due else { return false }
        let recurrence = OccurrenceCalendar(anchor: task.repeatAnchor ?? due, rule: task.rule, timeZone: task.timeZone)
        return recurrence.first(onOrAfter: occurrence)?.date == occurrence
    }

    private func commit(inserting newItem: TaskItem? = nil, removing removed: (UUID, TaskItem)? = nil,
                        addingAttachments added: [Attachment] = [], removingAttachments deleted: [Attachment] = []) throws {
        let removedRecords = deleted.map { (owner: $0.taskID, info: $0.info, model: $0) }
        for record in deleted { context.delete(record) }
        for record in added { context.insert(record) }
        do { try context.save() }
        catch {
            context.rollback()
            throw error
        }
        if let (id, task) = removed {
            byID.removeValue(forKey: id)
            items.removeAll { $0 === task }
        }
        if let newItem {
            byID[newItem.id] = newItem
            let index = items.firstIndex { $0.sortIndex <= newItem.sortIndex } ?? items.endIndex
            items.insert(newItem, at: index)
        }
        for record in added {
            attachmentsByTask[record.taskID, default: []].append(record)
            referencesByPath[record.relativePath, default: 0] += 1
        }
        for record in removedRecords {
            attachmentsByTask[record.owner]?.removeAll { $0 === record.model }
            if attachmentsByTask[record.owner]?.isEmpty == true { attachmentsByTask.removeValue(forKey: record.owner) }
            let path = record.info.relativePath
            if let count = referencesByPath[path], count > 1 {
                referencesByPath[path] = count - 1
            } else {
                referencesByPath.removeValue(forKey: path)
                attachmentManager.removeManaged(record.info)
            }
        }
        onChange?()
    }
}

enum TaskError: Error {
    case emptyTitle, invalidOccurrence
}
