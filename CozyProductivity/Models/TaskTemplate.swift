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

    /// Estimated duration of the task in minutes (e.g., 15, 30, 45, 60).
    var durationMinutes: Int

    /// Used when recurrence == .customDays (minimum 2).
    var customIntervalDays: Int

    /// When true, SmartScheduler places occurrences onto days with the most remaining free time.
    var isAutoScheduled: Bool

    /// Optional anchor or deadline date (used for pinned dates or flexible once target windows).
    var anchorDate: Date

    /// Optional target window length in days for flexible once tasks (default 7 days).
    var flexibleWindowDays: Int

    var isActive: Bool
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \TaskOccurrence.template)
    var occurrences: [TaskOccurrence] = []

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        emoji: String = "🌸",
        category: TaskCategory = .selfCare,
        recurrence: RecurrenceKind = .weekly,
        durationMinutes: Int = 30,
        customIntervalDays: Int = 3,
        isAutoScheduled: Bool = true,
        anchorDate: Date = Date(),
        flexibleWindowDays: Int = 7,
        isActive: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.emoji = emoji
        self.categoryRaw = category.rawValue
        self.recurrenceRaw = recurrence.rawValue
        self.durationMinutes = max(5, durationMinutes)
        self.customIntervalDays = max(2, customIntervalDays)
        self.isAutoScheduled = recurrence == .daily ? false : isAutoScheduled
        self.anchorDate = DateHelpers.startOfDay(for: anchorDate)
        self.flexibleWindowDays = max(1, flexibleWindowDays)
        self.isActive = isActive
        self.createdAt = createdAt
    }

    var category: TaskCategory {
        get { TaskCategory(rawValue: categoryRaw) ?? .selfCare }
        set { categoryRaw = newValue.rawValue }
    }

    var recurrence: RecurrenceKind {
        get { RecurrenceKind(rawValue: recurrenceRaw) ?? .once }
        set { recurrenceRaw = newValue.rawValue }
    }

    var recurrenceDisplayLabel: String {
        if recurrence == .customDays {
            return "Every \(customIntervalDays)d"
        }
        return recurrence.shortLabel
    }
}
