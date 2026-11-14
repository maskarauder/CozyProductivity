import Foundation

struct AccomplishmentDigest: Equatable {
    enum PeriodKind: Equatable {
        case daily
        case weekly
        case monthly
    }

    let kind: PeriodKind
    let periodLabel: String
    let completedCount: Int
    let pendingCount: Int
    let totalCompletedMinutes: Int
    let activeDaysCount: Int
    let completedItems: [CompletedItemSnapshot]

    struct CompletedItemSnapshot: Identifiable, Equatable {
        let id: UUID
        let title: String
        let emoji: String
        let durationMinutes: Int
        let completedDate: Date
    }

    var notificationTitle: String {
        switch kind {
        case .daily:
            return completedCount > 0 ? "Today's Cozy Wrap-Up 🌸" : "Peaceful Evening Check-In 🌙"
        case .weekly:
            return "Weekly Cozy Reflection 🌷"
        case .monthly:
            return "Monthly Cozy Celebration ✨🌸"
        }
    }

    var notificationBody: String {
        let durationText = DateHelpers.formatDuration(minutes: totalCompletedMinutes)

        switch kind {
        case .daily:
            guard completedCount > 0 else {
                return "No tasks checked off today — and that's okay! Any flexible tasks will gently shift to freer days 💖"
            }
            let previewTitles = completedItems.prefix(3).map { "\($0.emoji) \($0.title)" }.joined(separator: ", ")
            let extraCount = max(0, completedCount - 3)
            let suffix = extraCount > 0 ? " + \(extraCount) more" : ""
            let noun = completedCount == 1 ? "task" : "tasks"
            return "You completed \(completedCount) \(noun) today (\(durationText)): \(previewTitles)\(suffix) ✨ Rest well!"

        case .weekly:
            guard completedCount > 0 else {
                return "A restful week is part of the rhythm 🌸 Next week's tasks are balanced across your freest days."
            }
            let previewTitles = completedItems.prefix(3).map { "\($0.emoji) \($0.title)" }.joined(separator: ", ")
            let extraCount = max(0, completedCount - 3)
            let suffix = extraCount > 0 ? " + \(extraCount) more" : ""
            let dayNoun = activeDaysCount == 1 ? "day" : "days"
            return "You finished \(completedCount) tasks (\(durationText)) across \(activeDaysCount) cozy \(dayNoun) this week: \(previewTitles)\(suffix) 💖"

        case .monthly:
            guard completedCount > 0 else {
                return "A fresh month awaits 🌷 Your upcoming tasks are gently arranged around your free time."
            }
            let dayNoun = activeDaysCount == 1 ? "day" : "days"
            return "Celebrate yourself! You completed \(completedCount) tasks (\(durationText)) across \(activeDaysCount) \(dayNoun) in \(periodLabel) 🌸💕"
        }
    }
}

enum SummaryBuilder {
    static func dailyDigest(
        for date: Date,
        occurrences: [TaskOccurrence],
        calendar: Calendar = DateHelpers.calendar
    ) -> AccomplishmentDigest {
        let targetDay = DateHelpers.startOfDay(for: date, calendar: calendar)

        let completed = occurrences.filter { occ in
            guard occ.isCompleted else { return false }
            return occ.completedLogicalDay(calendar: calendar) == targetDay
        }

        let pendingToday = occurrences.filter { occ in
            occ.status == .pending && DateHelpers.isSameDay(occ.scheduledDay(calendar: calendar), targetDay, calendar: calendar)
        }

        let snapshots = completed
            .sorted { ($0.completedAt ?? $0.scheduledDate) < ($1.completedAt ?? $1.scheduledDate) }
            .map {
                AccomplishmentDigest.CompletedItemSnapshot(
                    id: $0.id,
                    title: $0.displayTitle,
                    emoji: $0.displayEmoji,
                    durationMinutes: $0.displayDurationMinutes,
                    completedDate: $0.completedAt ?? $0.scheduledDay(calendar: calendar)
                )
            }

        let totalMinutes = snapshots.reduce(0) { $0 + $1.durationMinutes }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMM d"

        return AccomplishmentDigest(
            kind: .daily,
            periodLabel: formatter.string(from: targetDay),
            completedCount: snapshots.count,
            pendingCount: pendingToday.count,
            totalCompletedMinutes: totalMinutes,
            activeDaysCount: snapshots.isEmpty ? 0 : 1,
            completedItems: snapshots
        )
    }

    static func weeklyDigest(
        containing date: Date,
        occurrences: [TaskOccurrence],
        calendar: Calendar = DateHelpers.calendar
    ) -> AccomplishmentDigest {
        let window = DateHelpers.weekWindow(containing: date, calendar: calendar)

        let completed = occurrences.filter { occ in
            guard occ.isCompleted else { return false }
            let day = occ.completedLogicalDay(calendar: calendar)
            return day >= window.start && day <= window.end
        }

        let pending = occurrences.filter { occ in
            guard occ.status == .pending else { return false }
            let day = occ.scheduledDay(calendar: calendar)
            return day >= window.start && day <= window.end
        }

        let snapshots = completed
            .sorted { $0.displayDurationMinutes > $1.displayDurationMinutes }
            .map {
                AccomplishmentDigest.CompletedItemSnapshot(
                    id: $0.id,
                    title: $0.displayTitle,
                    emoji: $0.displayEmoji,
                    durationMinutes: $0.displayDurationMinutes,
                    completedDate: $0.completedAt ?? $0.scheduledDay(calendar: calendar)
                )
            }

        let uniqueDays = Set(completed.map { $0.completedLogicalDay(calendar: calendar) })
        let totalMinutes = snapshots.reduce(0) { $0 + $1.durationMinutes }

        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "MMM d"
        let label = "\(fmt.string(from: window.start)) – \(fmt.string(from: window.end))"

        return AccomplishmentDigest(
            kind: .weekly,
            periodLabel: label,
            completedCount: snapshots.count,
            pendingCount: pending.count,
            totalCompletedMinutes: totalMinutes,
            activeDaysCount: uniqueDays.count,
            completedItems: snapshots
        )
    }

    static func monthlyDigest(
        containing date: Date,
        occurrences: [TaskOccurrence],
        calendar: Calendar = DateHelpers.calendar
    ) -> AccomplishmentDigest {
        let window = DateHelpers.monthWindow(containing: date, calendar: calendar)

        let completed = occurrences.filter { occ in
            guard occ.isCompleted else { return false }
            let day = occ.completedLogicalDay(calendar: calendar)
            return day >= window.start && day <= window.end
        }

        let pending = occurrences.filter { occ in
            guard occ.status == .pending else { return false }
            let day = occ.scheduledDay(calendar: calendar)
            return day >= window.start && day <= window.end
        }

        let snapshots = completed
            .sorted { ($0.completedAt ?? $0.scheduledDate) > ($1.completedAt ?? $1.scheduledDate) }
            .map {
                AccomplishmentDigest.CompletedItemSnapshot(
                    id: $0.id,
                    title: $0.displayTitle,
                    emoji: $0.displayEmoji,
                    durationMinutes: $0.displayDurationMinutes,
                    completedDate: $0.completedAt ?? $0.scheduledDay(calendar: calendar)
                )
            }

        let uniqueDays = Set(completed.map { $0.completedLogicalDay(calendar: calendar) })
        let totalMinutes = snapshots.reduce(0) { $0 + $1.durationMinutes }

        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "MMMM yyyy"
        let label = fmt.string(from: window.start)

        return AccomplishmentDigest(
            kind: .monthly,
            periodLabel: label,
            completedCount: snapshots.count,
            pendingCount: pending.count,
            totalCompletedMinutes: totalMinutes,
            activeDaysCount: uniqueDays.count,
            completedItems: snapshots
        )
    }
}
