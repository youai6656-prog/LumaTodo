import Foundation
import Testing
@testable import LumaTodo

@MainActor
struct TaskStoreTests {
    @Test func taskLifecycleCommitsEachChange() throws {
        try withStore { store in
            let now = instant("2026-11-18T10:00:00Z")
            let task = try store.save(TaskDraft(title: "  初稿  "), now: now)
            #expect(store.items.map(\.title) == ["初稿"])
            var draft = TaskDraft(task: task)
            draft.title = "交付"
            draft.notes = "包含安装包"
            draft.tags = "工作"
            draft.due = now.addingTimeInterval(3600)
            draft.hasTime = true
            draft.leads = [60, 0, 0]
            draft.priority = .high
            try store.save(draft, editing: task, now: now)
            try store.complete(task, now: now)

            let reloaded = try #require(store.items.first)
            #expect(reloaded.id == task.id)
            #expect(reloaded.title == "交付")
            #expect(reloaded.notes == "包含安装包")
            #expect(reloaded.tags == "工作")
            #expect(reloaded.due == now.addingTimeInterval(3600))
            #expect(reloaded.leads == [0, 60])
            #expect(reloaded.priority == .high)
            #expect(reloaded.completedAt == now)
            try store.restore(task, now: now)
            #expect(!task.isCompleted)
            try store.delete(task)
            #expect(store.items.isEmpty)
        }
    }

    @Test func completingRepeatAdvancesAndUndoRestoresSeries() throws {
        try withStore { store in
            var draft = TaskDraft(title: "Daily")
            let now = instant("2026-11-18T10:00:00Z")
            draft.due = now
            draft.hasTime = true
            draft.leads = [0]
            draft.rule = RepeatRule(kind: .daily)
            let task = try store.save(draft, now: now, timeZone: utc)
            let history = try store.complete(task, now: now)
            #expect(history.id != task.id)
            #expect(history.isCompleted)
            #expect(!task.isCompleted)
            #expect(task.due == instant("2026-11-19T10:00:00Z"))
            #expect(!store.isCurrent(task, scheduleID: task.scheduleID, occurrence: now))
            try store.restore(history, now: now)
            #expect(store.items.count == 1)
            #expect(task.due == now)
            #expect(store.isCurrent(task, scheduleID: task.scheduleID, occurrence: now))
        }
    }

    @Test func restoringOldRepeatHistoryPreservesNewerCursor() throws {
        try withStore { store in
            let due = instant("2026-11-18T10:00:00Z")
            var draft = TaskDraft(title: "Weekly")
            draft.due = due
            draft.hasTime = true
            draft.rule = RepeatRule(kind: .weekly)
            let task = try store.save(draft, now: due, timeZone: utc)
            let first = try store.complete(task, now: due)
            let next = try #require(task.due)
            try store.complete(task, now: next)
            let latest = task.due
            try store.restore(first, now: next)
            #expect(task.due == latest)
            #expect(!first.isCompleted)
            #expect(first.rule.kind == .none)
        }
    }

    @Test func reschedulingInvalidatesOldNotificationAndSnooze() throws {
        try withStore { store in
            var draft = TaskDraft(title: "Timed")
            let now = instant("2026-11-18T10:00:00Z")
            let first = now.addingTimeInterval(300)
            draft.hasTime = true
            draft.due = first
            draft.leads = [0]
            let task = try store.save(draft, now: now, timeZone: utc)
            let original = task.scheduleID
            try store.snooze(task, occurrence: first, minutes: 10, now: now)
            #expect(task.snoozes.count == 1)
            draft.due = now.addingTimeInterval(600)
            try store.save(draft, editing: task, now: now, timeZone: utc)
            #expect(task.scheduleID != original)
            #expect(task.snoozes.isEmpty)
            #expect(!store.isCurrent(task, scheduleID: original, occurrence: first))
            let plan = NotificationPlan.make(tasks: store.items, now: now, limit: 60)
            #expect(plan.events.map(\.fire) == [now.addingTimeInterval(600)])
            try store.delete(task)
            #expect(NotificationPlan.make(tasks: store.items, now: now, limit: 60).events.isEmpty)
        }
    }

    @Test func snoozeReplacesEarlierChoice() throws {
        try withStore { store in
            let now = instant("2026-11-18T10:00:00Z")
            var draft = TaskDraft(title: "Snooze")
            draft.due = now
            draft.hasTime = true
            draft.leads = [0]
            let task = try store.save(draft, now: now, timeZone: utc)
            try store.snooze(task, occurrence: now, minutes: 5, now: now)
            try store.snooze(task, occurrence: now, minutes: 30, now: now)

            let plan = NotificationPlan.make(tasks: store.items, now: now, limit: 60)
            #expect(plan.events.count == 1)
            #expect(plan.events.first?.fire == now.addingTimeInterval(30 * 60))
            #expect(plan.events.first?.snoozeID != nil)
        }
    }

    @Test func titleOnlyAndAllDayAreValidWithoutNotifications() throws {
        try withStore { store in
            #expect(throws: TaskError.self) { try store.save(TaskDraft(title: "   ")) }
            let now = instant("2026-11-18T10:00:00Z")
            var draft = TaskDraft(title: "All day")
            draft.due = now
            draft.leads = [0]
            let task = try store.save(draft, now: now, timeZone: utc)
            #expect(task.due == instant("2026-11-18T23:59:00Z"))
            #expect(task.leads.isEmpty)
            let tokyo = OccurrenceCalendar.calendar(in: try #require(TimeZone(identifier: "Asia/Tokyo")))
            #expect(tokyo.component(.day, from: try #require(dateForGrouping(task, calendar: tokyo))) == 18)
        }
    }
}

let utc = TimeZone(secondsFromGMT: 0)!
func instant(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }

@MainActor
private enum StoreFixture {
    // Like the application, these synchronous tests use a single SwiftData container per process.
    static let store: Result<TaskStore, Error> = Result {
        let directory = FileManager.default.temporaryDirectory.appending(path: "LumaTodoTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try TaskStore(url: directory.appending(path: "Tasks.store"))
    }
}

@MainActor
func withStore(_ test: (TaskStore) throws -> Void) throws {
    let store = try StoreFixture.store.get()
    defer { for item in store.items { try? store.delete(item) } }
    try test(store)
}
