import Foundation
import SwiftData

@Model
final class TaskTemplate {
    var id: UUID
    var title: String
    var notes: String
    var emoji: String
    var categoryRaw: String
    var recurrenceRaw: String

    /// Estimated clock duration of the task in minutes (e.g., 15, 30, 45, 60).
    var durationMinutes: Int

    /// Task effort weight ("light" = +0m, "normal" = +30m, "heavy" = +60m added to ranking/cup load).
    var weightRaw: String = TaskWeight.light.rawValue

    /// Optional hard deadline: forces the task to appear on or before `hardDeadlineDate` even if the daily cup lacks hours.
    var hasHardDeadline: Bool = false
    var hardDeadlineDate: Date? = nil
    var hardDeadlineDayKey: String = ""
    var hardDeadlineTimezoneID: String = ""

    /// Used when recurrence == .customDays (minimum 2).
    var customIntervalDays: Int

    /// When true, SmartScheduler places occurrences onto days with the most remaining free time.
    var isAutoScheduled: Bool

    /// Optional anchor date (used for pinned dates or flexible once target windows).
    var anchorDate: Date
    var anchorDayKey: String = ""
    var anchorTimezoneID: String = ""

    /// Optional target window length in days for flexible once tasks (default 7 days).
    var flexibleWindowDays: Int

    var isActive: Bool
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \TaskOccurrence.template)
    var occurrences: [TaskOccurrence] = []

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        emoji: String = "🌸",
        category: TaskCategory = .selfCare,
        recurrence: RecurrenceKind = .once,
        durationMinutes: Int = 30,
        weight: TaskWeight = .light,
        hasHardDeadline: Bool = false,
        hardDeadlineDate: Date? = nil,
        customIntervalDays: Int = 3,
        isAutoScheduled: Bool = true,
        anchorDate: Date = Date(),
        flexibleWindowDays: Int = 7,
        isActive: Bool = true,
        createdAt: Date = Date(),
        calendar: Calendar? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.emoji = emoji
        self.categoryRaw = category.rawValue
        self.recurrenceRaw = recurrence.rawValue
        self.durationMinutes = max(5, durationMinutes)
        self.weightRaw = weight.rawValue
        self.hasHardDeadline = hasHardDeadline
        self.customIntervalDays = max(2, customIntervalDays)
        self.isAutoScheduled = recurrence == .daily ? false : isAutoScheduled
        self.flexibleWindowDays = max(1, flexibleWindowDays)
        self.isActive = isActive
        self.createdAt = createdAt

        if let calendar {
            let tzID = calendar.timeZone.identifier
            let normAnchor = DateHelpers.startOfDay(for: anchorDate, calendar: calendar)
            let normDeadline = hardDeadlineDate.map { DateHelpers.startOfDay(for: $0, calendar: calendar) }
            self.anchorDate = normAnchor
            self.anchorDayKey = DateHelpers.dayKeyString(for: normAnchor, calendar: calendar)
            self.anchorTimezoneID = tzID
            self.hardDeadlineDate = normDeadline
            self.hardDeadlineDayKey = normDeadline.map { DateHelpers.dayKeyString(for: $0, calendar: calendar) } ?? ""
            self.hardDeadlineTimezoneID = normDeadline != nil ? tzID : ""
        } else {
            self.anchorDate = anchorDate
            self.anchorDayKey = ""
            self.anchorTimezoneID = ""
            self.hardDeadlineDate = hardDeadlineDate
            self.hardDeadlineDayKey = ""
            self.hardDeadlineTimezoneID = ""
        }
    }

    var category: TaskCategory {
        get { TaskCategory(rawValue: categoryRaw) ?? .selfCare }
        set { categoryRaw = newValue.rawValue }
    }

    var recurrence: RecurrenceKind {
        get { RecurrenceKind(rawValue: recurrenceRaw) ?? .once }
        set { recurrenceRaw = newValue.rawValue }
    }

    var weight: TaskWeight {
        get { TaskWeight(rawValue: weightRaw) ?? .light }
        set { weightRaw = newValue.rawValue }
    }

    /// Combined minutes used for ranking & daily cup balancing (`durationMinutes` + weight bonus).
    var effectiveLoadMinutes: Int {
        durationMinutes + weight.extraRankingMinutes
    }

    func normalizedAnchorDate(calendar: Calendar = DateHelpers.calendar) -> Date {
        let resolved = DateHelpers.resolveCivilDay(
            dayKey: anchorDayKey,
            fallbackDate: anchorDate,
            storedTimezoneID: anchorTimezoneID,
            calendar: calendar
        )
        return resolved.date
    }

    func setAnchorDate(_ date: Date, calendar: Calendar = DateHelpers.calendar) {
        let norm = DateHelpers.startOfDay(for: date, calendar: calendar)
        anchorDate = norm
        anchorDayKey = DateHelpers.dayKeyString(for: norm, calendar: calendar)
        anchorTimezoneID = calendar.timeZone.identifier
    }

    func normalizedHardDeadline(calendar: Calendar = DateHelpers.calendar) -> Date? {
        guard hasHardDeadline, let raw = hardDeadlineDate else { return nil }
        let resolved = DateHelpers.resolveCivilDay(
            dayKey: hardDeadlineDayKey,
            fallbackDate: raw,
            storedTimezoneID: hardDeadlineTimezoneID,
            calendar: calendar
        )
        return resolved.date
    }

    func setHardDeadline(_ date: Date?, hasDeadline: Bool, calendar: Calendar = DateHelpers.calendar) {
        hasHardDeadline = hasDeadline
        if hasDeadline, let date {
            let norm = DateHelpers.startOfDay(for: date, calendar: calendar)
            hardDeadlineDate = norm
            hardDeadlineDayKey = DateHelpers.dayKeyString(for: norm, calendar: calendar)
            hardDeadlineTimezoneID = calendar.timeZone.identifier
        } else {
            hardDeadlineDate = nil
            hardDeadlineDayKey = ""
            hardDeadlineTimezoneID = ""
        }
    }

    func normalizeCivilDates(in calendar: Calendar = DateHelpers.calendar) {
        let resolvedAnchor = DateHelpers.resolveCivilDay(
            dayKey: anchorDayKey,
            fallbackDate: anchorDate,
            storedTimezoneID: anchorTimezoneID,
            calendar: calendar
        )
        anchorDate = resolvedAnchor.date
        anchorDayKey = resolvedAnchor.dayKey
        anchorTimezoneID = resolvedAnchor.timezoneID

        if hasHardDeadline, let raw = hardDeadlineDate {
            let resolvedDL = DateHelpers.resolveCivilDay(
                dayKey: hardDeadlineDayKey,
                fallbackDate: raw,
                storedTimezoneID: hardDeadlineTimezoneID,
                calendar: calendar
            )
            hardDeadlineDate = resolvedDL.date
            hardDeadlineDayKey = resolvedDL.dayKey
            hardDeadlineTimezoneID = resolvedDL.timezoneID
        }
    }

    var recurrenceDisplayLabel: String {
        if recurrence == .customDays {
            return "Every \(customIntervalDays)d"
        }
        return recurrence.shortLabel
    }
}
