import Foundation
import SwiftData

@Model
final class TaskOccurrence {
    var id: UUID

    /// Normalized to start-of-day in the current calendar, paired with a timezone-invariant `"YYYY-MM-DD"` civil day key.
    var scheduledDate: Date
    var scheduledDayKey: String = ""
    var scheduledTimezoneID: String = ""

    /// Identifier for the recurrence period (e.g., "daily:2026-11-13", "weekly:2026-11-09", "monthly:2026-11", "once:<uuid>").
    /// Ensures at most one occurrence per recurrence window and prevents missed habits from piling up.
    var periodKey: String

    var statusRaw: String
    var completedAt: Date?

    /// True if the user manually moved or pinned this specific occurrence so auto-rebalance leaves its date intact.
    var isManuallyPinned: Bool

    /// When non-nil, this upcoming occurrence was selected into one of the 2 optional bonus slots on `bonusForDate`.
    var bonusForDate: Date? = nil
    var bonusForDayKey: String = ""
    var bonusTimezoneID: String = ""
    var bonusSlot: Int = 0

    /// Identifiers & destination bindings for two-way Google & Apple Calendar push/merge.
    var googleCalendarEventId: String? = nil
    var googleSyncedDestination: String? = nil
    var syncedEKEventIdentifier: String? = nil
    var googleBridgeSyncedDestination: String? = nil
    var lastCalendarSyncSignature: String? = nil
    var appleCalendarEventIdentifier: String? = nil
    var appleSyncedDestination: String? = nil
    var lastAppleCalendarSyncSignature: String? = nil

    /// Task weight snapshot & optional per-occurrence override.
    var weightSnapshotRaw: String = TaskWeight.light.rawValue
    var hasCustomWeightOverride: Bool = false
    var hardDeadlineSnapshot: Date? = nil
    var hardDeadlineSnapshotDayKey: String = ""

    /// Frozen snapshot fields preserved for completed/skipped history & summaries even if a template is later edited or deleted.
    var titleSnapshot: String
    var emojiSnapshot: String
    var durationMinutesSnapshot: Int
    var notesSnapshot: String = ""
    var recurrenceKindSnapshotRaw: String = RecurrenceKind.once.rawValue
    var recurrenceLabelSnapshot: String = "Once"
    var categorySnapshotRaw: String = TaskCategory.selfCare.rawValue

    var template: TaskTemplate?

    init(
        id: UUID = UUID(),
        scheduledDate: Date,
        periodKey: String,
        status: OccurrenceStatus = .pending,
        completedAt: Date? = nil,
        isManuallyPinned: Bool = false,
        bonusForDate: Date? = nil,
        bonusSlot: Int = 0,
        googleCalendarEventId: String? = nil,
        syncedEKEventIdentifier: String? = nil,
        lastCalendarSyncSignature: String? = nil,
        appleCalendarEventIdentifier: String? = nil,
        lastAppleCalendarSyncSignature: String? = nil,
        weightOverride: TaskWeight? = nil,
        template: TaskTemplate,
        calendar: Calendar? = nil
    ) {
        self.id = id
        self.periodKey = periodKey
        self.statusRaw = status.rawValue
        self.completedAt = completedAt
        self.isManuallyPinned = isManuallyPinned
        self.bonusSlot = bonusSlot
        self.googleCalendarEventId = googleCalendarEventId
        self.syncedEKEventIdentifier = syncedEKEventIdentifier
        self.lastCalendarSyncSignature = lastCalendarSyncSignature
        self.appleCalendarEventIdentifier = appleCalendarEventIdentifier
        self.lastAppleCalendarSyncSignature = lastAppleCalendarSyncSignature
        self.weightSnapshotRaw = (weightOverride ?? template.weight).rawValue
        self.hasCustomWeightOverride = weightOverride != nil
        self.titleSnapshot = template.title
        self.emojiSnapshot = template.emoji
        self.durationMinutesSnapshot = template.durationMinutes
        self.notesSnapshot = template.notes
        self.recurrenceKindSnapshotRaw = template.recurrence.rawValue
        self.recurrenceLabelSnapshot = template.recurrenceDisplayLabel
        self.categorySnapshotRaw = template.category.rawValue
        self.template = template

        if let calendar {
            let tzID = calendar.timeZone.identifier
            let normScheduled = DateHelpers.startOfDay(for: scheduledDate, calendar: calendar)
            let normBonus = bonusForDate.map { DateHelpers.startOfDay(for: $0, calendar: calendar) }
            let scopedDeadline: Date? = {
                guard let dl = template.normalizedHardDeadline(calendar: calendar) else { return nil }
                if template.recurrence == .once {
                    return dl
                }
                let win = DateHelpers.periodWindow(for: template, containing: normScheduled, calendar: calendar)
                return (dl >= win.start && dl <= win.end) ? dl : nil
            }()
            self.scheduledDate = normScheduled
            self.scheduledDayKey = DateHelpers.dayKeyString(for: normScheduled, calendar: calendar)
            self.scheduledTimezoneID = tzID
            self.bonusForDate = normBonus
            self.bonusForDayKey = normBonus.map { DateHelpers.dayKeyString(for: $0, calendar: calendar) } ?? ""
            self.bonusTimezoneID = normBonus != nil ? tzID : ""
            self.hardDeadlineSnapshot = scopedDeadline
            self.hardDeadlineSnapshotDayKey = scopedDeadline.map { DateHelpers.dayKeyString(for: $0, calendar: calendar) } ?? ""
        } else {
            self.scheduledDate = scheduledDate
            self.scheduledDayKey = ""
            self.scheduledTimezoneID = ""
            self.bonusForDate = bonusForDate
            self.bonusForDayKey = ""
            self.bonusTimezoneID = ""
            self.hardDeadlineSnapshot = template.hasHardDeadline && template.recurrence == .once ? template.hardDeadlineDate : nil
            self.hardDeadlineSnapshotDayKey = ""
        }
    }

    var status: OccurrenceStatus {
        get { OccurrenceStatus(rawValue: statusRaw) ?? .pending }
        set {
            let previous = OccurrenceStatus(rawValue: statusRaw) ?? .pending
            if previous == .pending && newValue != .pending {
                freezeSnapshotsFromCurrentState()
            }
            statusRaw = newValue.rawValue
        }
    }

    var isCompleted: Bool {
        get { status == .completed }
        set {
            if newValue {
                if status == .pending {
                    freezeSnapshotsFromCurrentState()
                }
                statusRaw = OccurrenceStatus.completed.rawValue
                if completedAt == nil {
                    completedAt = Date()
                }
            } else {
                statusRaw = OccurrenceStatus.pending.rawValue
                completedAt = nil
            }
        }
    }

    func markCompleted(at date: Date = Date(), calendar: Calendar = DateHelpers.calendar) {
        if status == .pending {
            freezeSnapshotsFromCurrentState(calendar: calendar)
        }
        statusRaw = OccurrenceStatus.completed.rawValue
        completedAt = date
    }

    /// Captures live template fields into frozen snapshots right before an occurrence transitions out of `.pending`,
    /// or backfills any missing legacy snapshot fields without overwriting already-frozen completed/skipped history.
    func freezeSnapshotsFromCurrentState(calendar: Calendar = DateHelpers.calendar) {
        guard let template else { return }
        if status == .pending {
            titleSnapshot = template.title
            emojiSnapshot = template.emoji
            durationMinutesSnapshot = template.durationMinutes
            if !hasCustomWeightOverride {
                weightSnapshotRaw = template.weight.rawValue
            }
            notesSnapshot = template.notes
            recurrenceKindSnapshotRaw = template.recurrence.rawValue
            recurrenceLabelSnapshot = template.recurrenceDisplayLabel
            categorySnapshotRaw = template.category.rawValue
            let deadline = effectiveHardDeadline(calendar: calendar)
            hardDeadlineSnapshot = deadline
            hardDeadlineSnapshotDayKey = deadline.map { DateHelpers.dayKeyString(for: $0, calendar: calendar) } ?? ""
        } else {
            if titleSnapshot.isEmpty {
                titleSnapshot = template.title
            }
            if emojiSnapshot.isEmpty {
                emojiSnapshot = template.emoji
            }
            if durationMinutesSnapshot <= 0 {
                durationMinutesSnapshot = template.durationMinutes
            }
            if weightSnapshotRaw.isEmpty {
                weightSnapshotRaw = template.weight.rawValue
            }
            if recurrenceKindSnapshotRaw.isEmpty {
                recurrenceKindSnapshotRaw = template.recurrence.rawValue
            }
            if recurrenceLabelSnapshot.isEmpty {
                recurrenceLabelSnapshot = template.recurrenceDisplayLabel
            }
            if categorySnapshotRaw.isEmpty {
                categorySnapshotRaw = template.category.rawValue
            }
        }
    }

    /// Refreshes snapshots on `.pending` occurrences when the underlying template is edited.
    func refreshPendingSnapshotsFromTemplate(
        periodDeadline: Date?,
        calendar: Calendar = DateHelpers.calendar
    ) {
        guard status == .pending, let template else { return }
        titleSnapshot = template.title
        emojiSnapshot = template.emoji
        durationMinutesSnapshot = template.durationMinutes
        if !hasCustomWeightOverride {
            weightSnapshotRaw = template.weight.rawValue
        }
        notesSnapshot = template.notes
        recurrenceKindSnapshotRaw = template.recurrence.rawValue
        recurrenceLabelSnapshot = template.recurrenceDisplayLabel
        categorySnapshotRaw = template.category.rawValue
        let normDL = periodDeadline.map { DateHelpers.startOfDay(for: $0, calendar: calendar) }
        hardDeadlineSnapshot = normDL
        hardDeadlineSnapshotDayKey = normDL.map { DateHelpers.dayKeyString(for: $0, calendar: calendar) } ?? ""
    }

    // MARK: - Civil & Logical Day Resolution

    func scheduledDay(calendar: Calendar = DateHelpers.calendar) -> Date {
        DateHelpers.resolveCivilDay(
            dayKey: scheduledDayKey,
            fallbackDate: scheduledDate,
            storedTimezoneID: scheduledTimezoneID,
            calendar: calendar
        ).date
    }

    func setScheduledDay(_ date: Date, calendar: Calendar = DateHelpers.calendar) {
        let norm = DateHelpers.startOfDay(for: date, calendar: calendar)
        scheduledDate = norm
        scheduledDayKey = DateHelpers.dayKeyString(for: norm, calendar: calendar)
        scheduledTimezoneID = calendar.timeZone.identifier
    }

    func bonusDay(calendar: Calendar = DateHelpers.calendar) -> Date? {
        guard let rawBonus = bonusForDate else { return nil }
        return DateHelpers.resolveCivilDay(
            dayKey: bonusForDayKey,
            fallbackDate: rawBonus,
            storedTimezoneID: bonusTimezoneID,
            calendar: calendar
        ).date
    }

    func setBonusDay(_ date: Date?, slot: Int = 0, calendar: Calendar = DateHelpers.calendar) {
        if let date {
            let norm = DateHelpers.startOfDay(for: date, calendar: calendar)
            bonusForDate = norm
            bonusForDayKey = DateHelpers.dayKeyString(for: norm, calendar: calendar)
            bonusTimezoneID = calendar.timeZone.identifier
            bonusSlot = slot
        } else {
            bonusForDate = nil
            bonusForDayKey = ""
            bonusTimezoneID = ""
            bonusSlot = 0
        }
    }

    @discardableResult
    func normalizeCivilDates(in calendar: Calendar = DateHelpers.calendar) -> Date {
        let resolvedSched = DateHelpers.resolveCivilDay(
            dayKey: scheduledDayKey,
            fallbackDate: scheduledDate,
            storedTimezoneID: scheduledTimezoneID,
            calendar: calendar
        )
        scheduledDate = resolvedSched.date
        scheduledDayKey = resolvedSched.dayKey
        scheduledTimezoneID = resolvedSched.timezoneID

        if let rawBonus = bonusForDate {
            let resolvedBonus = DateHelpers.resolveCivilDay(
                dayKey: bonusForDayKey,
                fallbackDate: rawBonus,
                storedTimezoneID: bonusTimezoneID,
                calendar: calendar
            )
            bonusForDate = resolvedBonus.date
            bonusForDayKey = resolvedBonus.dayKey
            bonusTimezoneID = resolvedBonus.timezoneID
        }
        return resolvedSched.date
    }

    /// Maps `completedAt` to its 4:00 AM Cozy logical day (while preserving exact start-of-day synthetic test fixtures).
    func completedLogicalDay(calendar: Calendar = DateHelpers.calendar) -> Date {
        let scheduledOrBonus = bonusDay(calendar: calendar) ?? scheduledDay(calendar: calendar)
        guard let instant = completedAt else {
            return scheduledOrBonus
        }
        let midnightOfInstant = DateHelpers.startOfDay(for: instant, calendar: calendar)
        if instant == midnightOfInstant && midnightOfInstant == scheduledOrBonus {
            return scheduledOrBonus
        }
        return DateHelpers.logicalDay(for: instant, calendar: calendar)
    }

    // MARK: - Display Properties (Frozen for Completed/Skipped History)

    var displayTitle: String {
        guard status == .pending, let template else { return titleSnapshot }
        return template.title
    }

    var displayEmoji: String {
        guard status == .pending, let template else { return emojiSnapshot }
        return template.emoji
    }

    var displayDurationMinutes: Int {
        guard status == .pending, let template else { return durationMinutesSnapshot }
        return template.durationMinutes
    }

    var displayWeight: TaskWeight {
        if status != .pending || hasCustomWeightOverride {
            return TaskWeight(rawValue: weightSnapshotRaw) ?? .light
        }
        if let template {
            return template.weight
        }
        return TaskWeight(rawValue: weightSnapshotRaw) ?? .light
    }

    /// Effective ranking & cup load minutes (`duration` + `0m` light / `+30m` normal / `+60m` heavy).
    var effectiveLoadMinutes: Int {
        displayDurationMinutes + displayWeight.extraRankingMinutes
    }

    func effectiveHardDeadline(calendar: Calendar = DateHelpers.calendar) -> Date? {
        if status == .pending, let template {
            guard let dl = template.normalizedHardDeadline(calendar: calendar) else { return nil }
            if template.recurrence == .once {
                return dl
            }
            let sched = scheduledDay(calendar: calendar)
            let win = DateHelpers.periodWindow(for: template, containing: sched, calendar: calendar)
            return (dl >= win.start && dl <= win.end) ? dl : nil
        }
        if !hardDeadlineSnapshotDayKey.isEmpty,
           let fromKey = DateHelpers.date(fromDayKey: hardDeadlineSnapshotDayKey, calendar: calendar) {
            return fromKey
        }
        return hardDeadlineSnapshot.map { DateHelpers.startOfDay(for: $0, calendar: calendar) }
    }

    func applyWeightAdjustment(_ newWeight: TaskWeight, updateTemplate: Bool = true) {
        weightSnapshotRaw = newWeight.rawValue
        hasCustomWeightOverride = true
        if updateTemplate {
            template?.weight = newWeight
        }
    }

    var displayNotes: String {
        guard status == .pending, let template else { return notesSnapshot }
        return template.notes
    }

    var displayRecurrenceKind: RecurrenceKind {
        guard status == .pending, let template else {
            return RecurrenceKind(rawValue: recurrenceKindSnapshotRaw) ?? .once
        }
        return template.recurrence
    }

    var displayCategory: TaskCategory? {
        if status == .pending {
            return template?.category
        }
        return TaskCategory(rawValue: categorySnapshotRaw)
    }

    var recurrenceLabel: String {
        guard status == .pending, let template else {
            return recurrenceLabelSnapshot.isEmpty ? "Once" : recurrenceLabelSnapshot
        }
        return template.recurrenceDisplayLabel
    }
}
