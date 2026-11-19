import Foundation
import Testing
@testable import LumaTodo

struct IndependentReminderTests {
    @Test func editorSizesIndependentlyOfBrowsingHeightAndFitsItsDisplay() {
        #expect(PanelLayout.editorSize(browsingWidth: 364, contentHeight: 260) == CGSize(width: 420, height: 420))
        #expect(PanelLayout.editorSize(browsingWidth: 700, contentHeight: 950) == CGSize(width: 460, height: 600))
        let screen = CGRect(x: 0, y: 45, width: 420, height: 380)
        let previous = CGRect(x: 42, y: 230, width: 364, height: 185)
        let size = PanelLayout.editorSize(browsingWidth: previous.width, contentHeight: 590)
        let actual = PanelLayout.resized(previous, width: size.width, height: size.height, in: screen)
        #expect(screen.contains(actual))
        #expect(actual.height == screen.height)
    }

    @MainActor @Test func independentReminderWorksWithoutDeadlineAndKeepsSnoozesSeparate() throws {
        try withStore { store in
            let now = instant("2027-01-14T10:00:00Z")
            let fire = now.addingTimeInterval(300)
            var draft = TaskDraft(title: "Call back")
            let reminder = IndependentReminder(fire: fire)
            draft.independentReminders = [reminder, IndependentReminder(fire: fire.addingTimeInterval(5))]
            let task = try store.save(draft, now: now, timeZone: utc)
            #expect(task.due == nil)
            #expect(task.independentReminders == [reminder])
            var event = try #require(NotificationPlan.make(tasks: store.items, now: now, limit: 60).events.first)
            #expect(event.fire == fire)
            #expect(event.independentReminderID == reminder.id)
            #expect(event.id == NotificationEvent.identifier(taskID: task.id, occurrence: fire, independentReminderID: reminder.id))

            try store.snooze(task, occurrence: fire, minutes: 5, now: fire, independentReminderID: reminder.id)
            event = try #require(NotificationPlan.make(tasks: store.items, now: fire, limit: 60).events.first)
            #expect(event.fire == fire.addingTimeInterval(300))
            #expect(event.independentReminderID == reminder.id)
            #expect(event.snoozeID != nil)

            let generation = task.scheduleID
            draft.independentReminders[0].fire = fire.addingTimeInterval(900)
            draft.independentReminders.removeLast()
            try store.save(draft, editing: task, now: fire, timeZone: utc)
            #expect(task.scheduleID != generation)
            #expect(task.snoozes.isEmpty)
            #expect(NotificationPlan.make(tasks: store.items, now: fire, limit: 60).events.map(\.fire) == [fire.addingTimeInterval(900)])
            try store.complete(task, now: fire)
            #expect(NotificationPlan.make(tasks: store.items, now: fire, limit: 60).events.isEmpty)
        }
    }

    @MainActor @Test func legacySnoozeArrayRemainsReadableWhenAddingAnIndependentReminder() throws {
        try withStore { store in
            let now = instant("2027-01-14T10:00:00Z")
            var draft = TaskDraft(title: "Legacy")
            draft.due = now
            draft.hasTime = true
            draft.leads = [0]
            let task = try store.save(draft, now: now, timeZone: utc)
            let snoozeID = UUID()
            // A SwiftData 1.1 task stored a bare array, without the independent-ID field.
            let old = """
                [{"id":"\(snoozeID.uuidString)","occurrence":\(now.timeIntervalSinceReferenceDate),"fire":\(now.timeIntervalSinceReferenceDate + 600)}]
                """
            task.snoozeData = Data(old.utf8)
            let snooze = try #require(task.snoozes.first)
            #expect(snooze.id == snoozeID)
            #expect(snooze.independentReminderID == nil)
            task.independentReminders = [IndependentReminder(fire: now.addingTimeInterval(900))]
            #expect(task.snoozes == [snooze])
            #expect(task.independentReminders.count == 1)
        }
    }

    @MainActor @Test func finishingARecurrenceClearsItsOneShotAndUndoRestoresIt() throws {
        try withStore { store in
            let now = instant("2027-01-14T10:00:00Z")
            var draft = TaskDraft(title: "Daily round")
            draft.due = now
            draft.hasTime = true
            draft.rule = RepeatRule(kind: .daily)
            let reminder = IndependentReminder(fire: now.addingTimeInterval(300))
            draft.independentReminders = [reminder]
            let active = try store.save(draft, now: now, timeZone: utc)
            let completed = try store.complete(active, now: now)
            #expect(active.independentReminders.isEmpty)
            #expect(completed.independentReminders == [reminder])
            try store.restore(completed, now: now)
            #expect(active.independentReminders == [reminder])
        }
    }
}
