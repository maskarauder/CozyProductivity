import Foundation

enum DateHelpers {
    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = .autoupdatingCurrent
        cal.timeZone = .autoupdatingCurrent
        return cal
    }

    static func startOfDay(for date: Date, calendar: Calendar = DateHelpers.calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    static func addDays(_ days: Int, to date: Date, calendar: Calendar = DateHelpers.calendar) -> Date {
        let base = startOfDay(for: date, calendar: calendar)
        return calendar.date(byAdding: .day, value: days, to: base) ?? base
    }

    static func isSameDay(_ lhs: Date, _ rhs: Date, calendar: Calendar = DateHelpers.calendar) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }

    static func daysBetween(_ start: Date, and end: Date, calendar: Calendar = DateHelpers.calendar) -> Int {
        let s = startOfDay(for: start, calendar: calendar)
        let e = startOfDay(for: end, calendar: calendar)
        return calendar.dateComponents([.day], from: s, to: e).day ?? 0
    }

    static func dayKeyString(for date: Date, calendar: Calendar = DateHelpers.calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 2026
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    // MARK: - Recurrence Period Bounds

    struct PeriodWindow: Equatable {
        let start: Date
        let end: Date
        let key: String
    }

    static func dailyWindow(for date: Date, calendar: Calendar = DateHelpers.calendar) -> PeriodWindow {
        let d = startOfDay(for: date, calendar: calendar)
        return PeriodWindow(start: d, end: d, key: "daily:\(dayKeyString(for: d, calendar: calendar))")
    }

    static func weekWindow(containing date: Date, calendar: Calendar = DateHelpers.calendar) -> PeriodWindow {
        let d = startOfDay(for: date, calendar: calendar)
        let weekday = calendar.component(.weekday, from: d) // 1 = Sun ... 7 = Sat
        // Anchor weeks Monday -> Sunday for natural weekend planning, or respect locale firstWeekday
        let firstWeekday = calendar.firstWeekday
        let offsetToStart = (weekday - firstWeekday + 7) % 7
        let start = addDays(-offsetToStart, to: d, calendar: calendar)
        let end = addDays(6, to: start, calendar: calendar)
        return PeriodWindow(start: start, end: end, key: "weekly:\(dayKeyString(for: start, calendar: calendar))")
    }

    static func biweeklyWindow(
        containing date: Date,
        anchor: Date,
        calendar: Calendar = DateHelpers.calendar
    ) -> PeriodWindow {
        let anchorWeekStart = weekWindow(containing: anchor, calendar: calendar).start
        let targetDay = startOfDay(for: date, calendar: calendar)
        let diffDays = daysBetween(anchorWeekStart, and: targetDay, calendar: calendar)
        let bucketIndex = diffDays >= 0 ? (diffDays / 14) : ((diffDays - 13) / 14)
        let start = addDays(bucketIndex * 14, to: anchorWeekStart, calendar: calendar)
        let end = addDays(13, to: start, calendar: calendar)
        return PeriodWindow(start: start, end: end, key: "biweekly:\(dayKeyString(for: start, calendar: calendar))")
    }

    static func monthWindow(containing date: Date, calendar: Calendar = DateHelpers.calendar) -> PeriodWindow {
        let d = startOfDay(for: date, calendar: calendar)
        let comps = calendar.dateComponents([.year, .month], from: d)
        let start = calendar.date(from: comps).map { startOfDay(for: $0, calendar: calendar) } ?? d
        let dayCount = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        let end = addDays(dayCount - 1, to: start, calendar: calendar)
        let y = comps.year ?? 2026
        let m = comps.month ?? 1
        let key = String(format: "monthly:%04d-%02d", y, m)
        return PeriodWindow(start: start, end: end, key: key)
    }

    static func customIntervalWindow(
        containing date: Date,
        anchor: Date,
        intervalDays: Int,
        calendar: Calendar = DateHelpers.calendar
    ) -> PeriodWindow {
        let step = max(2, intervalDays)
        let anchorDay = startOfDay(for: anchor, calendar: calendar)
        let targetDay = startOfDay(for: date, calendar: calendar)
        let diffDays = daysBetween(anchorDay, and: targetDay, calendar: calendar)
        let bucketIndex = diffDays >= 0 ? (diffDays / step) : ((diffDays - (step - 1)) / step)
        let start = addDays(bucketIndex * step, to: anchorDay, calendar: calendar)
        let end = addDays(step - 1, to: start, calendar: calendar)
        return PeriodWindow(start: start, end: end, key: "custom\(step):\(dayKeyString(for: start, calendar: calendar))")
    }

    static func periodWindow(
        for template: TaskTemplate,
        containing date: Date,
        calendar: Calendar = DateHelpers.calendar
    ) -> PeriodWindow {
        switch template.recurrence {
        case .once:
            let start = startOfDay(for: date, calendar: calendar)
            let end = addDays(max(0, template.flexibleWindowDays - 1), to: start, calendar: calendar)
            return PeriodWindow(start: start, end: end, key: "once:\(template.id.uuidString)")
        case .daily:
            return dailyWindow(for: date, calendar: calendar)
        case .weekly:
            return weekWindow(containing: date, calendar: calendar)
        case .biweekly:
            return biweeklyWindow(containing: date, anchor: template.anchorDate, calendar: calendar)
        case .monthly:
            return monthWindow(containing: date, calendar: calendar)
        case .customDays:
            return customIntervalWindow(
                containing: date,
                anchor: template.anchorDate,
                intervalDays: template.customIntervalDays,
                calendar: calendar
            )
        }
    }

    // MARK: - Human-Friendly Formatting

    static func formatDuration(minutes: Int) -> String {
        let clamped = max(0, minutes)
        let hours = clamped / 60
        let mins = clamped % 60
        if hours > 0 && mins > 0 {
            return "\(hours)h \(mins)m"
        } else if hours > 0 {
            return "\(hours)h"
        } else {
            return "\(mins)m"
        }
    }

    static func cozyGreeting(for date: Date = Date(), calendar: Calendar = DateHelpers.calendar) -> String {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<12:
            return "Good morning 🌸"
        case 12..<17:
            return "Cozy afternoon ✨"
        case 17..<22:
            return "Peaceful evening 🌷"
        default:
            return "Gentle night 🌙"
        }
    }

    static func weekdayName(for weekday: Int) -> String {
        let symbols = calendar.weekdaySymbols
        guard weekday >= 1 && weekday <= symbols.count else { return "Day" }
        return symbols[weekday - 1]
    }

    static func shortWeekdayName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    static func fullHeaderDateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: date)
    }
}
