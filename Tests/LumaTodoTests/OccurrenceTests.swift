import Foundation
import Testing
@testable import LumaTodo

struct OccurrenceTests {
    @Test func weekdaysRollPastWeekends() {
        let saturday = instant("2026-11-21T10:00:00Z")
        let rule = RepeatRule(kind: .weekdays)
        let monday = OccurrenceCalendar.normalizedDeadline(saturday, hasTime: true, rule: rule, timeZone: utc)
        let repeatDates = OccurrenceCalendar(anchor: monday, rule: rule, timeZone: utc)
        #expect(monday == instant("2026-11-23T10:00:00Z"))
        #expect(repeatDates.date(at: 4) == instant("2026-11-27T10:00:00Z"))
        #expect(repeatDates.date(at: 5) == instant("2026-11-30T10:00:00Z"))
    }

    @Test func monthlyRetainsOriginalDayWhenPossible() {
        let calendar = OccurrenceCalendar(anchor: instant("2027-01-31T10:00:00Z"),
                                          rule: RepeatRule(kind: .months), timeZone: utc)
        #expect(calendar.date(at: 1) == instant("2027-02-28T10:00:00Z"))
        #expect(calendar.date(at: 2) == instant("2027-03-31T10:00:00Z"))
    }

    @Test func dailyKeepsLocalClockAcrossDaylightSaving() throws {
        let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let calendar = OccurrenceCalendar(anchor: instant("2027-03-13T17:00:00Z"),
                                          rule: RepeatRule(kind: .daily), timeZone: pacific)
        #expect(calendar.date(at: 1) == instant("2027-03-14T16:00:00Z"))
        #expect(calendar.date(at: 2) == instant("2027-03-15T16:00:00Z"))
        let missingHour = OccurrenceCalendar(anchor: instant("2027-03-13T10:30:00Z"),
                                             rule: RepeatRule(kind: .daily), timeZone: pacific)
        #expect(missingHour.date(at: 1) == instant("2027-03-14T10:30:00Z"))
        #expect(missingHour.date(at: 2) == instant("2027-03-15T09:30:00Z"))
    }

    @Test func customIntervalFindsNextOccurrenceAfterLongDisuse() {
        let anchor = instant("1998-01-01T12:00:00Z")
        let lowerBound = instant("2026-11-18T12:00:00Z")
        for rule in [RepeatRule(kind: .days, interval: 3), RepeatRule(kind: .weeks, interval: 2)] {
            let calendar = OccurrenceCalendar(anchor: anchor, rule: rule, timeZone: utc)
            let candidate = calendar.first(onOrAfter: lowerBound)
            #expect(candidate.map { $0.date >= lowerBound } == true)
            #expect(candidate.flatMap { calendar.date(at: $0.index - 1) }.map { $0 < lowerBound } == true)
        }
    }

    @MainActor @Test func notificationQueueIsChronologicalBoundedAndStable() throws {
        try withStore { store in
            let now = instant("2026-11-18T07:00:00Z")
            var draft = TaskDraft(title: "Repeat")
            draft.due = instant("2026-11-18T10:00:00Z")
            draft.hasTime = true
            draft.leads = [0, 10, 60]
            draft.rule = RepeatRule(kind: .daily)
            let repeating = try store.save(draft, now: now, timeZone: utc)

            draft.title = "One-time"
            draft.due = instant("2026-11-18T09:30:00Z")
            draft.leads = [0]
            draft.rule = RepeatRule()
            let once = try store.save(draft, now: now, timeZone: utc)
            let first = NotificationPlan.make(tasks: store.items, now: now, limit: 4)
            let again = NotificationPlan.make(tasks: store.items.reversed(), now: now, limit: 4)
            #expect(first.events.map(\.taskID) == [repeating.id, once.id, repeating.id, repeating.id])
            #expect(first.events.map(\.id) == again.events.map(\.id))
            #expect(Set(first.events.map(\.id)).count == 4)
            #expect(first.deferredTaskIDs == [repeating.id])
            let after = instant("2026-11-18T09:45:00Z")
            let refill = NotificationPlan.make(tasks: store.items, now: after, limit: 4)
            #expect(refill.events.first?.lead == 10)
            #expect(refill.events.last?.occurrence == instant("2026-11-19T10:00:00Z"))
        }
    }

    @MainActor @Test func missedLeadStillSchedulesNextCrossDateOccurrence() throws {
        try withStore { store in
            let now = instant("2026-11-18T23:56:00Z")
            var draft = TaskDraft(title: "Midnight")
            draft.due = instant("2026-11-19T00:01:00Z")
            draft.hasTime = true
            draft.leads = [0, 10]
            draft.rule = RepeatRule(kind: .daily)
            try store.save(draft, now: now, timeZone: utc)
            let plan = NotificationPlan.make(tasks: store.items, now: now, limit: 2)
            #expect(plan.events.map(\.fire) == [instant("2026-11-19T00:01:00Z"), instant("2026-11-19T23:51:00Z")])
        }
    }
}
