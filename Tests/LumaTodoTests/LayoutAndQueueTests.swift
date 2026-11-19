import Foundation
import Testing
@testable import LumaTodo

struct LayoutAndQueueTests {
    @Test func compactEmptyHeightAndGrowthUpToScrollLimit() {
        let heights = [0, 1, 3, 6, 30].map { count in
            let line = PanelLayout.rowHeight(compact: false, notes: false, metadata: false)
            let section = PanelLayout.SectionSize(rows: count, height: CGFloat(count) * line)
            return PanelLayout.height(sections: count == 0 ? [] : [section], limit: 580, available: 900)
        }
        #expect(heights == [244, 259, 316, 436, 580])
        #expect(PanelLayout.height(sections: [.collapsed, .collapsed], limit: 580, available: 900) == 244)
        #expect(PanelLayout.height(sections: [.init(rows: 2, height: 160)], searching: true, notice: true, undo: true,
                                   limit: 580, available: 310) == 310)
        #expect(PanelLayout.rowHeight(compact: true, notes: true, metadata: true) == 45)
    }

    @Test func fitsHeightWithoutMovingTopOrRightEdge() {
        let screen = CGRect(x: 0, y: 35, width: 1440, height: 845)
        let initial = CGRect(x: 1050, y: 604, width: 364, height: 244)
        let expanded = PanelLayout.resized(initial, width: 364, height: 500, in: screen)
        #expect(expanded.maxY == initial.maxY)
        #expect(expanded.maxX == initial.maxX)
        let mini = PanelLayout.resized(expanded, width: 300, height: 120, in: screen)
        #expect(mini.maxY == initial.maxY)
        #expect(mini.maxX == initial.maxX)
        #expect(PanelLayout.resized(expanded, width: initial.width, height: initial.height, in: screen) == initial)
    }

    @Test func unreachableFrameMovesInsideRemainingDisplay() {
        let removedScreenFrame = CGRect(x: -1030, y: 230, width: 630, height: 870)
        let visible = CGRect(x: 0, y: 45, width: 1024, height: 665)
        let recovered = PanelLayout.reachable(removedScreenFrame, in: visible)
        #expect(visible.contains(recovered))
        #expect(recovered.height == visible.height)
    }

    @Test func queueDiffCancelsCompletedDeletedAndEditedRequests() {
        let change = ReminderQueueDiff(existing: [
            "obsolete-time": "old", "deleted-task": "old", "completed-task": "old",
            "changed-content": "old", "sleep-pending": "still valid", "unchanged": "same"
        ], desired: [
            "new-time": "new", "changed-content": "new", "unchanged": "same"
        ], preserving: ["sleep-pending"])
        #expect(change.remove == ["obsolete-time", "deleted-task", "completed-task", "changed-content"])
        #expect(change.submit == ["new-time", "changed-content"])
        let alreadyReconciled = ReminderQueueDiff(existing: ["unchanged": "same"], desired: ["unchanged": "same"], preserving: [])
        #expect(alreadyReconciled.remove.isEmpty && alreadyReconciled.submit.isEmpty)
    }

    @Test func preservesJustDuePendingRequestButNeverAnInvalidOrDeliveredOne() {
        let fire = instant("2026-11-19T07:05:00Z")
        let wake = fire.addingTimeInterval(420)
        #expect(LateReminder.shouldKeep(fire: fire, now: wake, current: true, alreadyDelivered: false))
        #expect(!LateReminder.shouldKeep(fire: fire, now: wake, current: false, alreadyDelivered: false))
        #expect(!LateReminder.shouldKeep(fire: fire, now: wake, current: true, alreadyDelivered: true))
        #expect(!LateReminder.shouldKeep(fire: fire, now: fire.addingTimeInterval(90_000), current: true, alreadyDelivered: false))
    }

    @MainActor @Test func overlappingRepeatTimesDeduplicateAndObservedDeliverySurvivesClockRollback() throws {
        try withStore { store in
            let now = instant("2026-11-19T08:00:00Z")
            var draft = TaskDraft(title: "Overlapping")
            draft.due = instant("2026-11-19T09:00:00Z")
            draft.hasTime = true
            draft.rule = RepeatRule(kind: .daily)
            draft.leads = [0, 24 * 60]
            try store.save(draft, now: now, timeZone: utc)
            let first = NotificationPlan.make(tasks: store.items, now: now, limit: 3)
            #expect(first.events.map(\.fire) == [
                instant("2026-11-19T09:00:00Z"), instant("2026-11-20T09:00:00Z"), instant("2026-11-21T09:00:00Z")
            ])
            let delivered = try #require(first.events.first?.deliveryKey)
            let rollback = NotificationPlan.make(tasks: store.items, now: now, limit: 3, delivered: [delivered])
            #expect(rollback.events.first?.fire == instant("2026-11-20T09:00:00Z"))
        }
    }

    @MainActor @Test func completionAndSnoozeReplacementProduceExpectedRequestIdentities() throws {
        try withStore { store in
            let now = instant("2026-11-19T08:00:00Z")
            var draft = TaskDraft(title: "Snooze")
            let due = now.addingTimeInterval(3600)
            draft.due = due
            draft.hasTime = true
            draft.leads = [0]
            let task = try store.save(draft, now: now, timeZone: utc)
            try store.snooze(task, occurrence: due, minutes: 5, now: now)
            let old = NotificationPlan.make(tasks: store.items, now: now, limit: 60)
            try store.snooze(task, occurrence: due, minutes: 10, now: now)
            let new = NotificationPlan.make(tasks: store.items, now: now, limit: 60)
            #expect(old.events.first?.id != new.events.first?.id)
            #expect(old.events.last?.id == new.events.last?.id)
            try store.complete(task, now: now)
            #expect(NotificationPlan.make(tasks: store.items, now: now, limit: 60).events.isEmpty)
            try store.restore(task, now: now)
            #expect(store.item(task.id) === task)
            #expect(NotificationPlan.make(tasks: store.items, now: now, limit: 60).events.count == 1)
        }
    }
}
