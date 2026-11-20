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

    @Test func edgePositionRespectsVisibleAreaAfterResolutionChanges() {
        let original = CGRect(x: -1200, y: 46, width: 1140, height: 800)
        let smaller = CGRect(x: 36, y: 24, width: 1040, height: 630)
        let high = EdgePlacement(displayID: 42, edge: .left, centerY: .greatestFiniteMagnitude, in: original)
        let low = EdgePlacement(displayID: 42, edge: .right, centerY: -.greatestFiniteMagnitude, in: original)
        let middle = EdgePlacement(displayID: 42, edge: .right, centerY: original.midY, in: original)
        #expect(high.frame(in: smaller).minX == smaller.minX)
        #expect(high.frame(in: smaller).maxY == smaller.maxY - 4)
        #expect(low.frame(in: smaller).maxX == smaller.maxX)
        #expect(low.frame(in: smaller).minY == smaller.minY + 4)
        #expect(middle.frame(in: smaller).midY == smaller.midY)
    }

    @Test func flingTracksIntentAcross288Trajectories() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 38, width: 1440, height: 832)
        let neighboringLeft = CGRect(x: -1240, y: 0, width: 1240, height: 900)
        let neighboringRight = CGRect(x: 1440, y: 0, width: 1240, height: 900)
        for sign in [-1.0, 1.0] {
            let edge: ScreenEdge = sign < 0 ? .left : .right
            let near = CGRect(x: sign < 0 ? 90 : 990, y: 350, width: 360, height: 330)
            for y in [220.0, 410, 620] {
                for variant in 0..<4 {
                    let step = Double(variant) * 0.002
                    func check(points: [(Double, Double, Double)], frame: CGRect = near,
                               neighbors: [CGRect] = [], crossed: Bool = false, expected: ScreenEdge?) {
                        let start = PointerSample(point: CGPoint(x: 720, y: y), time: 1)
                        var drag = DragMotion(start: start)
                        for (time, x, dy) in points {
                            drag.append(PointerSample(point: CGPoint(x: 720 + sign * x, y: y + dy), time: 1 + time + step))
                        }
                        #expect(FlingIntent.detect(drag, window: frame, visible: visible, display: display,
                                                  neighbors: neighbors, crossedDisplay: crossed)?.edge == expected)
                    }
                    let fast = [(0.030, 38.0, 1.0), (0.065, 94.0, 4.0), (0.095, 149.0, 3.0)]
                    check(points: fast, expected: edge)
                    check(points: [(0.20, 40, 0), (0.45, 100, 0), (0.75, 150, 1)], expected: nil)
                    check(points: [(0.030, 10, 48), (0.065, 20, 95), (0.095, 70, 185)], expected: nil)
                    check(points: [(0.030, 100, 0), (0.066, 145, 0), (0.096, 112, 0)], expected: nil)
                    check(points: [(0.020, 19, 0), (0.040, 44, 0)], expected: nil)
                    check(points: fast, frame: CGRect(x: 540, y: 350, width: 360, height: 330), expected: nil)
                    check(points: fast + [(0.35, 149, 3)], expected: nil)
                    check(points: fast, neighbors: [sign < 0 ? neighboringLeft : neighboringRight], expected: nil)
                    check(points: fast, crossed: true, expected: nil)
                    check(points: fast, neighbors: [CGRect(x: sign < 0 ? -800 : 1440, y: 850, width: 800, height: 300)],
                          expected: edge)
                    check(points: [(0.04, 36, 0), (0.08, 78, 2), (0.12, 120, 4)], expected: edge)
                    check(points: [(0.04, 27, 0), (0.08, 52, 2), (0.12, 77, 4)], expected: nil)
                }
            }
        }
    }

    @Test func releaseUsesMultipleSamplesAndRejectsARealPause() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 1000, y: 300, width: 364, height: 280)
        var motion = DragMotion(start: PointerSample(point: CGPoint(x: 950, y: 500), time: 0))
        for (x, time) in [(970.0, 0.019), (1015, 0.050), (1043, 0.065), (1090, 0.101)] {
            motion.append(PointerSample(point: CGPoint(x: x, y: 500), time: time))
        }
        motion.append(PointerSample(point: CGPoint(x: 1090, y: 500), time: 0.124))
        let released = FlingIntent.evaluate(motion, window: frame, visible: visible, display: visible,
                                            neighbors: [], crossedDisplay: false)
        #expect(released.shouldCollapse && released.targetEdge == .right)
        #expect(released.velocity.dx > 1_200)
        motion.append(PointerSample(point: CGPoint(x: 1090, y: 500), time: 0.23))
        let stopped = FlingIntent.evaluate(motion, window: frame, visible: visible, display: visible,
                                           neighbors: [], crossedDisplay: false)
        #expect(stopped.rejection == "noReleaseMomentum")
        #expect(!stopped.shouldCollapse)
    }

    @Test func morphFinishesContentFadeBeforeNarrowingTheShell() {
        let shape = MorphGeometry(window: CGRect(x: 500, y: 350, width: 364, height: 330),
                                  tab: CGRect(x: 1412, y: 480, width: 28, height: 64), windowRadius: 26)
        for index in 0...100 {
            let progress = Double(index) / 100
            let frame = shape.frame(at: progress)
            if shape.contentOpacity(at: progress) > 0 {
                #expect(frame.size == shape.window.size)
            }
            #expect(shape.canvas.contains(frame))
        }
    }

    @Test func edgePullCombinesBothAxesAcross324MirroredTrajectories() {
        for edge: ScreenEdge in [.left, .right] {
            let inward: CGFloat = edge == .left ? 1 : -1
            for (width, display) in [(300.0, 800.0), (364, 1440), (520, 1920)] {
                let tuning = EdgePullTuning(windowWidth: width, displayWidth: display)
                for y in [36.0, 400, 764] {
                    for step in [0.018, 0.045, 0.14] {
                        func drag(_ path: [(Double, Double)], release: EdgePullGesture.Release) {
                            let start = PointerSample(point: CGPoint(x: edge == .left ? 14 : display - 14, y: y), time: 0)
                            var drag = EdgePullGesture(edge: edge, tuning: tuning, start: start)
                            for (index, point) in path.enumerated() {
                                drag.append(PointerSample(point: CGPoint(x: start.point.x + point.0 * inward, y: y + point.1),
                                                          time: Double(index + 1) * step))
                            }
                            #expect(drag.dragging)
                            #expect(abs(drag.motion.translation.height - (path.last?.1 ?? 0)) < 0.01)
                            #expect(abs(drag.progress - tuning.progress(at: path.last?.0 ?? 0)) < 0.001)
                            #expect(drag.release == release)
                        }
                        drag([(10, 0), (25, 1), (40, 0), (60, 0)], release: .stay)
                        drag([(14, 1), (tuning.reach * 0.65, 1), (tuning.reach * 0.94, 2)], release: .expand)
                        drag([(20, 1), (tuning.reach * 0.97, -15), (85, 38), (20, -12)], release: .stay)
                        drag([(1, 18), (38, 80), (tuning.reach, 170)], release: .expand)
                        drag([(0, -16), (0, -53), (0, -110)], release: .stay)
                        drag([(-14, 1), (-25, 1), (tuning.reach, -52)], release: .expand)
                    }
                }
            }
        }
    }

    @Test func edgePullIsContinuousAndShowsContentOnlyAtFullSize() {
        let tuning = EdgePullTuning(windowWidth: 364, displayWidth: 1408)
        #expect(tuning.progress(at: 0) == 0 && tuning.progress(at: tuning.reach) == 1)
        let before = tuning.velocity(at: tuning.knee - 0.01, pointerVelocity: 1)
        let after = tuning.velocity(at: tuning.knee + 0.01, pointerVelocity: 1)
        #expect(abs(before - after) < 0.0001)
        #expect(tuning.velocity(at: 10, pointerVelocity: 1) > tuning.velocity(at: 40, pointerVelocity: 1))
        for edge: ScreenEdge in [.left, .right] {
            let shape = MorphGeometry(window: CGRect(x: edge == .left ? 32 : 1012, y: 359, width: 364, height: 280),
                                      tab: CGRect(x: edge == .left ? 0 : 1380, y: 500, width: 28, height: 64),
                                      windowRadius: 26, pullEdge: edge)
            #expect(shape.frame(at: 1) == shape.tab)
            #expect(shape.frame(at: 0) == shape.window)
            var previous = 0.0
            for distance in 0...275 {
                let opening = tuning.progress(at: Double(distance))
                #expect(opening >= previous && opening <= 1)
                previous = opening
                let frame = shape.frame(at: 1 - opening)
                #expect(shape.canvas.contains(frame))
                if shape.contentOpacity(at: 1 - opening) > 0 { #expect(frame.size == shape.window.size) }
            }
        }
    }

    @Test func edgePullDestinationStaysReachableAndNearItsStartingSide() {
        let display = CGRect(x: -1400, y: 80, width: 1400, height: 780)
        for edge: ScreenEdge in [.left, .right] {
            let tab = EdgePlacement(displayID: 1, edge: edge, centerY: 580, in: display).frame(in: display)
            let originX = edge == .left ? display.maxX - 364 : display.minX
            let previous = CGRect(x: originX, y: 500, width: 364, height: 330)
            let target = MorphGeometry.pullDestination(window: previous, tab: tab, edge: edge, visible: display)
            #expect(display.contains(target))
            #expect(previous.size == target.size && previous.minY == target.minY)
            let edgeGap = edge == .left ? target.minX - tab.minX : tab.maxX - target.maxX
            #expect(edgeGap >= 0 && edgeGap <= 95)
            #expect(MorphGeometry.pullDestination(window: target, tab: tab, edge: edge, visible: display) == target)
        }
    }

    @Test func liquidContourStaysClosedAndMatchesMirroredEdges() {
        let box = CGRect(x: 40, y: 60, width: 30, height: 64)
        let mirror = CGRect(x: 150, y: 60, width: 30, height: 64)
        for depth in (0...24).map(Double.init) {
            for shear in [-5.0, 0, 5] {
                let left = FluidContour(body: box, radius: 14, edge: .left, neck: depth, pressure: 0.6, anchor: 0.8, shear: shear).path
                let right = FluidContour(body: mirror, radius: 14, edge: .right, neck: depth, pressure: 0.6, anchor: 0.8, shear: shear).path
                #expect(abs(left.boundingBoxOfPath.minX - (220 - right.boundingBoxOfPath.maxX)) < 0.001)
                #expect(abs(left.boundingBoxOfPath.width - right.boundingBoxOfPath.width) < 0.001)
                #expect(left.boundingBoxOfPath.minY == box.minY && left.boundingBoxOfPath.maxY == box.maxY)
                #expect(left.contains(CGPoint(x: box.midX, y: box.midY)))
                if depth >= 2 {
                    #expect(left.contains(CGPoint(x: box.minX - depth / 2, y: box.minY + 35)))
                }
            }
        }
    }

    @Test func liquidPreviewTracksHeightIndependentlyAndClampsAtDisplayEdges() {
        let visible = CGRect(x: -1200, y: 32, width: 1200, height: 700)
        let tab = EdgePlacement(displayID: 1, edge: .left, centerY: 320, in: visible).frame(in: visible)
        let geometry = MorphGeometry(window: CGRect(x: -1150, y: 200, width: 364, height: 340), tab: tab,
                                     windowRadius: 26, pullEdge: .left, verticalBounds: visible)
        for progress in [0.0, 0.25, 0.60, 0.92, 1] {
            let low = geometry.frame(at: progress, centerY: -100, within: visible)
            let medium = geometry.frame(at: progress, centerY: 320, within: visible)
            let high = geometry.frame(at: progress, centerY: 900, within: visible)
            #expect(abs(low.minY - visible.minY) < 0.001 && abs(high.maxY - visible.maxY) < 0.001)
            #expect(low.midY < medium.midY && medium.midY < high.midY)
            #expect(low.size == medium.size && medium.size == high.size)
            #expect(low.minX == medium.minX && medium.minX == high.minX)
            #expect(geometry.canvas.insetBy(dx: -0.001, dy: -0.001).contains(low))
            #expect(geometry.canvas.insetBy(dx: -0.001, dy: -0.001).contains(high))
        }
    }

    @Test func edgePullRejectsLongPressAndPredictsOnlyCommittedMotion() {
        let tuning = EdgePullTuning(windowWidth: 364, displayWidth: 1408)
        let start = PointerSample(point: .zero, time: 0)
        var held = EdgePullGesture(edge: .left, tuning: tuning, start: start)
        held.append(PointerSample(point: .zero, time: 0.70))
        #expect(held.release == .stay)
        var clicked = EdgePullGesture(edge: .left, tuning: tuning, start: start)
        clicked.append(PointerSample(point: CGPoint(x: 1, y: 2), time: 0.11))
        #expect(clicked.release == .click)
        var predicted = EdgePullGesture(edge: .left, tuning: tuning, start: start)
        for (point, time) in [(25.0, 0.035), (70, 0.066), (135, 0.105)] {
            predicted.append(PointerSample(point: CGPoint(x: point, y: 0), time: time))
        }
        #expect(!predicted.ready && predicted.release == .expand)
        predicted.append(PointerSample(point: CGPoint(x: 135, y: 0), time: 0.25))
        #expect(predicted.release == .stay)
    }

    @Test func interruptedSpringKeepsPresentationAndVelocity() {
        let shape = MorphGeometry(window: CGRect(x: 190, y: 320, width: 365, height: 330),
                                  tab: CGRect(x: 0, y: 460, width: 28, height: 64), windowRadius: 26)
        let outbound = MorphSpring(start: 0, target: 1, velocity: 5, response: 22, damping: 0.88)
        let released = outbound.sample(at: 0)
        #expect(abs(released.velocity - 5) < 0.0001)
        let halfway = outbound.sample(at: 0.065)
        let inward = MorphSpring(start: halfway.position, target: 0, velocity: halfway.velocity, response: 22, damping: 0.88)
        #expect(shape.frame(at: inward.sample(at: 0).position) == shape.frame(at: halfway.position))
        #expect(abs(inward.sample(at: 0).velocity - halfway.velocity) < 0.0001)
        #expect(abs(inward.sample(at: 0.53).position) < 0.003)
        #expect(shape.frame(at: 0) == shape.window && shape.frame(at: 1) == shape.tab)
        #expect(shape.radius(at: 0) == 26 && shape.radius(at: 1) == 14)
        #expect(shape.frame(at: 0.5).width < shape.window.width && shape.frame(at: 0.5).width > shape.tab.width)
    }

    @MainActor @Test func completingFutureOrUndatedTasksDoesNotInflateToday() throws {
        try withStore { store in
            let now = instant("2026-11-19T12:00:00Z")
            var draft = TaskDraft(title: "Future")
            draft.due = now.addingTimeInterval(2 * 86400)
            draft.hasTime = true
            let future = try store.save(draft, now: now, timeZone: .current)
            try store.complete(future, now: now)
            let undated = try store.save(TaskDraft(title: "Undated"), now: now)
            try store.complete(undated, now: now)
            draft.title = "Today"
            draft.due = now
            let today = try store.save(draft, now: now, timeZone: .current)
            try store.complete(today, now: now)
            let listing = PanelListing(items: store.items, now: now, order: .date)
            #expect(listing.completedToday == 1 && listing.remainingToday == 0)
        }
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
