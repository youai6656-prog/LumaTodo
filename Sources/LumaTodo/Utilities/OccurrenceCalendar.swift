import Foundation

struct OccurrenceCalendar {
    let anchor: Date
    let rule: RepeatRule
    var calendar: Calendar

    init(anchor: Date, rule: RepeatRule, timeZone: TimeZone) {
        self.anchor = anchor
        self.rule = rule
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
    }

    static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func normalizedDeadline(_ date: Date, hasTime: Bool, rule: RepeatRule, timeZone: TimeZone) -> Date {
        let calendar = calendar(in: timeZone)
        var value = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        if !hasTime {
            value = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: date) ?? value
        }
        if rule.kind == .weekdays {
            let weekday = calendar.component(.weekday, from: value)
            let shift = weekday == 7 ? 2 : (weekday == 1 ? 1 : 0)
            if shift > 0 { value = calendar.date(byAdding: .day, value: shift, to: value) ?? value }
        }
        return value
    }

    func date(at index: Int) -> Date? {
        guard index >= 0 else { return nil }
        if index == 0 { return anchor }
        let step = max(1, min(rule.interval, 365))
        let dayOffset: Int
        switch rule.kind {
        case .none: return nil
        case .daily: dayOffset = index
        case .weekly: dayOffset = index * 7
        case .days: dayOffset = index * step
        case .weeks: dayOffset = index * step * 7
        case .months:
            return calendar.date(byAdding: .month, value: index * step, to: anchor)
        case .weekdays:
            let weekday = calendar.component(.weekday, from: anchor)
            let workday = weekday - 2
            dayOffset = index + ((workday + index) / 5) * 2
        }
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: anchor)) else { return nil }
        let time = calendar.dateComponents([.hour, .minute, .second], from: anchor)
        return calendar.nextDate(after: day.addingTimeInterval(-1), matching: time,
                                 matchingPolicy: .nextTimePreservingSmallerComponents,
                                 repeatedTimePolicy: .first, direction: .forward)
    }

    func first(onOrAfter lowerBound: Date) -> (index: Int, date: Date)? {
        if lowerBound <= anchor { return (0, anchor) }
        guard rule.kind != .none else { return nil }
        // Exponential search handles old recurring tasks without scanning missed occurrences.
        var low = 0
        var high = 1
        while high < 1_048_576, let candidate = date(at: high), candidate < lowerBound {
            low = high
            high *= 2
        }
        while high - low > 1 {
            let mid = (low + high) / 2
            if let candidate = date(at: mid), candidate < lowerBound { low = mid }
            else { high = mid }
        }
        guard let value = date(at: high), value >= lowerBound else { return nil }
        return (high, value)
    }
}
