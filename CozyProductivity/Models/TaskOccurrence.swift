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

    /// Snapshot fields preserved for history/summaries even if a template is later renamed.
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
        template: TaskTemplate
    ) {
        self.id = id
        self.scheduledDate = DateHelpers.startOfDay(for: scheduledDate)
        self.periodKey = periodKey
        self.statusRaw = status.rawValue
        self.completedAt = completedAt
        self.isManuallyPinned = isManuallyPinned
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

    var displayNotes: String {
        template?.notes ?? ""
    }

    var recurrenceLabel: String {
        template?.recurrenceDisplayLabel ?? "Task"
    }
}
