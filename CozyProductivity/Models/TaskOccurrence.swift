import Foundation
import SwiftData

@Model
final class TaskOccurrence {
    var id: UUID

    /// Normalized to start-of-day in the current calendar.
    var scheduledDate: Date

    /// Identifier for the recurrence period (e.g., "daily:2026-11-13", "weekly:2026-W46", "monthly:2026-11", "once:<uuid>").
    /// Ensures at most one occurrence per recurrence window and prevents missed habits from piling up.
    var periodKey: String

    var statusRaw: String
    var completedAt: Date?

    /// True if the user manually moved or pinned this specific occurrence so auto-rebalance leaves its date intact.
    var isManuallyPinned: Bool

    /// When non-nil, this upcoming occurrence was selected into one of the 2 optional bonus slots on `bonusForDate`.
    var bonusForDate: Date? = nil
    var bonusSlot: Int = 0

    /// Identifiers for two-way Google & Apple Calendar push/merge so rebalanced, edited, or completed tasks update in place without duplicating.
    var googleCalendarEventId: String? = nil
    var syncedEKEventIdentifier: String? = nil
    var lastCalendarSyncSignature: String? = nil
    var appleCalendarEventIdentifier: String? = nil
    var lastAppleCalendarSyncSignature: String? = nil

    /// Task weight snapshot & optional per-occurrence override.
    var weightSnapshotRaw: String = TaskWeight.light.rawValue
    var hasCustomWeightOverride: Bool = false
    var hardDeadlineSnapshot: Date? = nil

    /// Snapshot fields preserved for history/summaries even if a template is later renamed or deleted.
    var titleSnapshot: String
    var emojiSnapshot: String
    var durationMinutesSnapshot: Int

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
        template: TaskTemplate
    ) {
        self.id = id
        self.scheduledDate = DateHelpers.startOfDay(for: scheduledDate)
        self.periodKey = periodKey
        self.statusRaw = status.rawValue
        self.completedAt = completedAt
        self.isManuallyPinned = isManuallyPinned
        self.bonusForDate = bonusForDate.map { DateHelpers.startOfDay(for: $0) }
        self.bonusSlot = bonusSlot
        self.googleCalendarEventId = googleCalendarEventId
        self.syncedEKEventIdentifier = syncedEKEventIdentifier
        self.lastCalendarSyncSignature = lastCalendarSyncSignature
        self.appleCalendarEventIdentifier = appleCalendarEventIdentifier
        self.lastAppleCalendarSyncSignature = lastAppleCalendarSyncSignature
        self.weightSnapshotRaw = (weightOverride ?? template.weight).rawValue
        self.hasCustomWeightOverride = weightOverride != nil
        self.hardDeadlineSnapshot = template.normalizedHardDeadline()
        self.titleSnapshot = template.title
        self.emojiSnapshot = template.emoji
        self.durationMinutesSnapshot = template.durationMinutes
        self.template = template
    }

    var status: OccurrenceStatus {
        get { OccurrenceStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var isCompleted: Bool {
        get { status == .completed }
        set {
            if newValue {
                status = .completed
                if completedAt == nil {
                    completedAt = Date()
                }
            } else {
                status = .pending
                completedAt = nil
            }
        }
    }

    var displayTitle: String {
        template?.title ?? titleSnapshot
    }

    var displayEmoji: String {
        template?.emoji ?? emojiSnapshot
    }

    var displayDurationMinutes: Int {
        template?.durationMinutes ?? durationMinutesSnapshot
    }

    var displayWeight: TaskWeight {
        if hasCustomWeightOverride {
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
        if let template {
            return template.normalizedHardDeadline(calendar: calendar)
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
        template?.notes ?? ""
    }

    var recurrenceLabel: String {
        template?.recurrenceDisplayLabel ?? "Task"
    }
}
