import Foundation

struct NotificationEvent: Equatable {
    let taskID: UUID
    let scheduleID: UUID
    let occurrence: Date
    let fire: Date
    let lead: Int?
    let snoozeID: UUID?
    let title: String
    var independentReminderID: UUID? = nil

    static let prefix = "lumatodo.task."
    var id: String {
        Self.identifier(taskID: taskID, occurrence: occurrence, lead: lead, snoozeID: snoozeID,
                        independentReminderID: independentReminderID)
    }

    var deliveryKey: ReminderDeliveryKey { ReminderDeliveryKey(id: id, version: scheduleID) }

    static func identifier(taskID: UUID, occurrence: Date, lead: Int? = nil, snoozeID: UUID? = nil,
                           independentReminderID: UUID? = nil) -> String {
        let suffix: String
        if let snoozeID { suffix = "snooze.\(snoozeID.uuidString)" }
        else if let independentReminderID { suffix = "at.\(independentReminderID.uuidString)" }
        else { suffix = "lead.\(lead ?? 0)" }
        return prefix + "\(taskID.uuidString).\(Int64(occurrence.timeIntervalSince1970)).\(suffix)"
    }
}

struct ReminderDeliveryKey: Hashable, Codable {
    let id: String
    let version: UUID
}

struct NotificationPlan {
    let events: [NotificationEvent]
    let deferredTaskIDs: Set<UUID>

    @MainActor
    static func make(tasks: [TaskItem], now: Date, limit: Int,
                     delivered: Set<ReminderDeliveryKey> = []) -> Self {
        var queue = EventHeap()
        for task in tasks where !task.isCompleted {
            let independent = Dictionary(uniqueKeysWithValues: task.independentReminders.map { ($0.id, $0.fire) })
            for (id, date) in independent where date > now {
                let event = NotificationEvent(taskID: task.id, scheduleID: task.scheduleID,
                                              occurrence: date, fire: date, lead: nil, snoozeID: nil,
                                              title: task.title, independentReminderID: id)
                queue.push(Stream(event: event))
            }
            for snooze in task.snoozes where snooze.fire.roundedForNotification > now {
                if let id = snooze.independentReminderID {
                    guard independent[id] == snooze.occurrence else { continue }
                } else {
                    guard let due = task.due, snooze.occurrence >= due else { continue }
                }
                let event = NotificationEvent(taskID: task.id, scheduleID: task.scheduleID,
                                              occurrence: snooze.occurrence, fire: snooze.fire,
                                              lead: nil, snoozeID: snooze.id, title: task.title,
                                              independentReminderID: snooze.independentReminderID)
                queue.push(Stream(event: event))
            }
            guard let due = task.due else { continue }
            let recurrence = OccurrenceCalendar(anchor: task.repeatAnchor ?? due, rule: task.rule, timeZone: task.timeZone)
            for lead in task.leads {
                let offset = TimeInterval(lead * 60)
                let afterNow = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate + offset).nextUp)
                let firstDue = max(due, afterNow)
                guard let first = recurrence.first(onOrAfter: firstDue) else { continue }
                let event = NotificationEvent(taskID: task.id, scheduleID: task.scheduleID,
                                              occurrence: first.date, fire: first.date.addingTimeInterval(-offset),
                                              lead: lead, snoozeID: nil, title: task.title)
                queue.push(Stream(event: event, recurrence: recurrence, index: first.index))
            }
        }

        var events: [NotificationEvent] = []
        var lastFireByTask: [UUID: Date] = [:]
        while events.count < limit, let stream = queue.pop() {
            let event = stream.event
            if let next = stream.next { queue.push(next) }
            let fire = event.fire.roundedForNotification
            if lastFireByTask[event.taskID] == fire { continue }
            lastFireByTask[event.taskID] = fire
            if !delivered.contains(event.deliveryKey) { events.append(event) }
        }
        return Self(events: events, deferredTaskIDs: Set(queue.streams.map { $0.event.taskID }))
    }

    private struct Stream {
        let event: NotificationEvent
        var recurrence: OccurrenceCalendar?
        var index = 0

        var next: Self? {
            guard let recurrence, let lead = event.lead,
                  let due = recurrence.date(at: index + 1) else { return nil }
            let next = NotificationEvent(taskID: event.taskID, scheduleID: event.scheduleID,
                                         occurrence: due, fire: due.addingTimeInterval(-Double(lead * 60)),
                                         lead: lead, snoozeID: nil, title: event.title)
            return Self(event: next, recurrence: recurrence, index: index + 1)
        }

        func precedes(_ other: Self) -> Bool {
            let fire = event.fire.roundedForNotification
            let otherFire = other.event.fire.roundedForNotification
            if fire != otherFire { return fire < otherFire }
            if event.taskID != other.event.taskID { return event.taskID.uuidString < other.event.taskID.uuidString }
            if event.occurrence != other.event.occurrence { return event.occurrence < other.event.occurrence }
            return event.id < other.event.id
        }
    }

    private struct EventHeap {
        var streams: [Stream] = []

        mutating func push(_ stream: Stream) {
            streams.append(stream)
            var index = streams.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard streams[index].precedes(streams[parent]) else { break }
                streams.swapAt(index, parent)
                index = parent
            }
        }

        mutating func pop() -> Stream? {
            guard let first = streams.first else { return nil }
            let last = streams.removeLast()
            guard !streams.isEmpty else { return first }
            streams[0] = last
            var index = 0
            while index * 2 + 1 < streams.count {
                var child = index * 2 + 1
                if child + 1 < streams.count, streams[child + 1].precedes(streams[child]) { child += 1 }
                guard streams[child].precedes(streams[index]) else { break }
                streams.swapAt(index, child)
                index = child
            }
            return first
        }
    }
}

extension Date {
    var roundedForNotification: Date { Date(timeIntervalSince1970: ceil(timeIntervalSince1970)) }
}

struct ReminderQueueDiff {
    let remove: Set<String>
    let submit: Set<String>

    init(existing: [String: String], desired: [String: String], preserving: Set<String>) {
        remove = Set(existing.keys.filter { id in
            !preserving.contains(id) && desired[id] != existing[id]
        })
        submit = Set(desired.keys.filter { desired[$0] != existing[$0] })
    }
}

enum LateReminder {
    static func shouldKeep(fire: Date, now: Date, current: Bool, alreadyDelivered: Bool) -> Bool {
        current && !alreadyDelivered && (0...(24 * 60 * 60)).contains(now.timeIntervalSince(fire))
    }
}
