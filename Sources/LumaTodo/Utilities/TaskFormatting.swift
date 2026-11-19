import Foundation

func minutesLabel(_ minutes: Int, words: Words) -> String {
    if minutes == 0 { return words("截止时", "At deadline") }
    if minutes % 60 == 0 {
        let hours = minutes / 60
        return words("提前 \(hours) 小时", "\(hours) hr before")
    }
    return words("提前 \(minutes) 分钟", "\(minutes) min before")
}

func dateLabel(_ date: Date, timed: Bool, words: Words, timeZone: TimeZone? = nil,
               includeDay: Bool = true) -> String {
    var style = Date.FormatStyle(date: includeDay ? .abbreviated : .omitted,
                                 time: timed ? .shortened : .omitted, locale: words.locale)
    if let timeZone { style.timeZone = timeZone }
    return date.formatted(style)
}

func dateForGrouping(_ task: TaskItem, calendar: Calendar = .current) -> Date? {
    guard let due = task.due else { return nil }
    guard !task.hasTime else { return due }
    var origin = calendar
    origin.timeZone = task.timeZone
    let day = origin.dateComponents([.era, .year, .month, .day], from: due)
    return calendar.date(from: day).flatMap {
        calendar.date(byAdding: DateComponents(day: 1, second: -1), to: $0)
    } ?? due
}
