import Foundation

enum DateHelpers {
    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = .autoupdatingCurrent
        cal.timeZone = .autoupdatingCurrent
        return cal
    }

    static let cupResetHour = 4

    static func startOfDay(for date: Date, calendar: Calendar = DateHelpers.calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    /// Returns the start-of-day Date for the active "Cozy Day", resetting at 4:00 AM local time
    /// (so 12:00 AM – 3:59 AM belongs to the previous day's cup, and 4:00 AM starts a new cup day).
    static func logicalToday(
        now: Date = Date(),
        resetHour: Int = cupResetHour,
        calendar: Calendar = DateHelpers.calendar
    ) -> Date {
        let hour = calendar.component(.hour, from: now)
        let rawDay = startOfDay(for: now, calendar: calendar)
        if hour < resetHour {
            return addDays(-1, to: rawDay, calendar: calendar)
        }
        return rawDay
    }

    /// Maps any timestamp (such as `completedAt` or `now`) to its Cozy logical day using the 4:00 AM reset boundary.
    static func logicalDay(
        for instant: Date,
        resetHour: Int = cupResetHour,
        calendar: Calendar = DateHelpers.calendar
    ) -> Date {
        logicalToday(now: instant, resetHour: resetHour, calendar: calendar)
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

    /// Parses a `"YYYY-MM-DD"` civil day key into a start-of-day `Date` in `calendar`.
    static func date(fromDayKey dayKey: String, calendar: Calendar = DateHelpers.calendar) -> Date? {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        guard let built = calendar.date(from: comps) else { return nil }
        return startOfDay(for: built, calendar: calendar)
    }

    /// Resolves a stored civil day so traveling across timezones keeps the exact `"YYYY-MM-DD"` calendar day,
    /// while direct in-place mutations to `fallbackDate` within the same timezone still update the day key.
    static func resolveCivilDay(
        dayKey: String,
        fallbackDate: Date,
        storedTimezoneID: String,
        calendar: Calendar = DateHelpers.calendar
    ) -> (date: Date, dayKey: String, timezoneID: String) {
        let tzID = calendar.timeZone.identifier
        let fallbackDay = startOfDay(for: fallbackDate, calendar: calendar)
        let fallbackKey = dayKeyString(for: fallbackDay, calendar: calendar)

        if !dayKey.isEmpty {
            if !storedTimezoneID.isEmpty && storedTimezoneID != tzID {
                if let resolved = date(fromDayKey: dayKey, calendar: calendar) {
                    return (resolved, dayKey, tzID)
                }
            } else if storedTimezoneID.isEmpty {
                if let resolved = date(fromDayKey: dayKey, calendar: calendar) {
                    return (resolved, dayKey, tzID)
                }
            } else if fallbackKey != dayKey {
                return (fallbackDay, fallbackKey, tzID)
            } else if let resolved = date(fromDayKey: dayKey, calendar: calendar) {
                return (resolved, dayKey, tzID)
            }
        }

        return (fallbackDay, fallbackKey, tzID)
    }

    static func shortMonthDayString(for date: Date, calendar: Calendar = DateHelpers.calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
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
        let resolvedAnchor = template.normalizedAnchorDate(calendar: calendar)
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
            return biweeklyWindow(containing: date, anchor: resolvedAnchor, calendar: calendar)
        case .monthly:
            return monthWindow(containing: date, calendar: calendar)
        case .customDays:
            return customIntervalWindow(
                containing: date,
                anchor: resolvedAnchor,
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

    static func weekdayName(for weekday: Int, calendar: Calendar = DateHelpers.calendar) -> String {
        let symbols = calendar.weekdaySymbols
        guard weekday >= 1 && weekday <= symbols.count else { return "Day" }
        return symbols[weekday - 1]
    }

    static func shortWeekdayName(for date: Date, calendar: Calendar = DateHelpers.calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    static func fullHeaderDateString(for date: Date, calendar: Calendar = DateHelpers.calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: date)
    }
}
