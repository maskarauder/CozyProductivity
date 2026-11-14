import Foundation
import SwiftData

struct DayAchievementSummary: Equatable {
    let date: Date
    let baseTotalCount: Int
    let baseCompletedCount: Int
    let bonusCompletedCount: Int

    var allBaseCompleted: Bool {
        baseTotalCount > 0 && baseCompletedCount == baseTotalCount
    }

    var tier: DayCompletionTier {
        guard allBaseCompleted else { return .none }
        if bonusCompletedCount >= 2 {
            return .gold
        } else if bonusCompletedCount == 1 {
            return .silver
        } else {
            return .base
        }
    }
}

struct StreakSnapshot: Equatable {
    let daySummaries: [Date: DayAchievementSummary]
    let currentStreak: Int
    let longestStreak: Int
    let totalBronzeOrPinkDays: Int
    let totalSilverDays: Int
    let totalGoldDays: Int

    func tier(for date: Date, calendar: Calendar = DateHelpers.calendar) -> DayCompletionTier {
        let day = DateHelpers.startOfDay(for: date, calendar: calendar)
        return daySummaries[day]?.tier ?? .none
    }

    func summary(for date: Date, calendar: Calendar = DateHelpers.calendar) -> DayAchievementSummary {
        let day = DateHelpers.startOfDay(for: date, calendar: calendar)
        return daySummaries[day] ?? DayAchievementSummary(
            date: day,
            baseTotalCount: 0,
            baseCompletedCount: 0,
            bonusCompletedCount: 0
        )
    }
}

@MainActor
enum StreakAndBonusService {
    // MARK: - Streak & Day Tier Evaluation

    static func evaluate(
        occurrences: [TaskOccurrence],
        persistedLongestStreak: Int = 0,
        today referenceDate: Date = Date(),
        calendar: Calendar = DateHelpers.calendar
    ) -> StreakSnapshot {
        let today = DateHelpers.startOfDay(for: referenceDate, calendar: calendar)

        var baseTotalByDay: [Date: Int] = [:]
        var baseDoneByDay: [Date: Int] = [:]
        var bonusDoneByDay: [Date: Int] = [:]
        var allTrackedDays: Set<Date> = []

        for occ in occurrences where occ.status != .skipped {
            if let bonusDate = occ.bonusForDate {
                let bDay = DateHelpers.startOfDay(for: bonusDate, calendar: calendar)
                if occ.isCompleted {
                    bonusDoneByDay[bDay, default: 0] += 1
                    allTrackedDays.insert(bDay)
                } else if bDay >= today {
                    // Still pending as an optional bonus candidate today; it remains a future scheduled task
                    let sDay = DateHelpers.startOfDay(for: occ.scheduledDate, calendar: calendar)
                    baseTotalByDay[sDay, default: 0] += 1
                    allTrackedDays.insert(sDay)
                }
            } else {
                let sDay = DateHelpers.startOfDay(for: occ.scheduledDate, calendar: calendar)
                baseTotalByDay[sDay, default: 0] += 1
                if occ.isCompleted {
                    baseDoneByDay[sDay, default: 0] += 1
                }
                allTrackedDays.insert(sDay)
            }
        }

        var summaries: [Date: DayAchievementSummary] = [:]
        var bronzeCount = 0
        var silverCount = 0
        var goldCount = 0

        for day in allTrackedDays {
            let summary = DayAchievementSummary(
                date: day,
                baseTotalCount: baseTotalByDay[day] ?? 0,
                baseCompletedCount: baseDoneByDay[day] ?? 0,
                bonusCompletedCount: bonusDoneByDay[day] ?? 0
            )
            summaries[day] = summary

            if day <= today {
                switch summary.tier {
                case .none: break
                case .base: bronzeCount += 1
                case .silver: silverCount += 1
                case .gold: goldCount += 1
                }
            }
        }

        let pastAndTodayDays = allTrackedDays.filter { $0 <= today }
        guard let earliestDay = pastAndTodayDays.min() else {
            return StreakSnapshot(
                daySummaries: summaries,
                currentStreak: 0,
                longestStreak: max(0, persistedLongestStreak),
                totalBronzeOrPinkDays: bronzeCount,
                totalSilverDays: silverCount,
                totalGoldDays: goldCount
            )
        }

        var runningStreak = 0
        var bestStreak = max(0, persistedLongestStreak)

        // Scan completed past days strictly before today
        let yesterday = DateHelpers.addDays(-1, to: today, calendar: calendar)
        if earliestDay <= yesterday {
            let span = max(0, DateHelpers.daysBetween(earliestDay, and: yesterday, calendar: calendar))
            for offset in 0...span {
                let day = DateHelpers.addDays(offset, to: earliestDay, calendar: calendar)
                guard let summary = summaries[day], summary.baseTotalCount > 0 else {
                    // Empty day with zero scheduled tasks is neutral
                    continue
                }

                switch summary.tier {
                case .gold:
                    runningStreak += 1
                    bestStreak = max(bestStreak, runningStreak)
                case .silver:
                    // Silver preserves the streak without adding to it
                    break
                case .base, .none:
                    // Finished day below Silver resets streak
                    runningStreak = 0
                }
            }
        }

        // Apply today's live state without breaking yesterday's active streak while today is still ongoing
        let todayTier = summaries[today]?.tier ?? .none
        let currentStreak: Int
        switch todayTier {
        case .gold:
            currentStreak = runningStreak + 1
        case .silver, .base, .none:
            currentStreak = runningStreak
        }
        bestStreak = max(bestStreak, currentStreak)

        return StreakSnapshot(
            daySummaries: summaries,
            currentStreak: currentStreak,
            longestStreak: bestStreak,
            totalBronzeOrPinkDays: bronzeCount,
            totalSilverDays: silverCount,
            totalGoldDays: goldCount
        )
    }

    // MARK: - Two Optional Bonus Tasks Management (Selectable from Next 7 Days)

    /// Ensures that once all base tasks for `today` are completed, up to 2 upcoming tasks from `[tomorrow ... today + 7]`
    /// are populated into Bonus Slots 1 & 2 (and clears uncompleted bonus slots if base tasks aren't all complete).
    static func syncBonusSlots(
        context: ModelContext,
        occurrences: [TaskOccurrence],
        preferences: CozyPreferences? = nil,
        today referenceDate: Date = Date(),
        calendar: Calendar = DateHelpers.calendar
    ) {
        let today = DateHelpers.startOfDay(for: referenceDate, calendar: calendar)

        // Clean up any stale pending bonus assignments from past days
        for occ in occurrences where occ.status == .pending {
            if let bDate = occ.bonusForDate, DateHelpers.startOfDay(for: bDate, calendar: calendar) < today {
                occ.bonusForDate = nil
                occ.bonusSlot = 0
            }
        }

        let baseToday = occurrences.filter {
            $0.status != .skipped
                && $0.bonusForDate == nil
                && DateHelpers.isSameDay($0.scheduledDate, today, calendar: calendar)
        }
        let allBaseCompleted = !baseToday.isEmpty && baseToday.allSatisfy(\.isCompleted)

        if !allBaseCompleted {
            // Hide/release uncompleted optional bonus slots until all base tasks are done
            for occ in occurrences where occ.status == .pending {
                if let bDate = occ.bonusForDate, DateHelpers.isSameDay(bDate, today, calendar: calendar) {
                    occ.bonusForDate = nil
                    occ.bonusSlot = 0
                }
            }
        } else {
            for slot in [1, 2] {
                let existingInSlot = occurrences.first {
                    $0.status != .skipped
                        && $0.bonusSlot == slot
                        && ($0.bonusForDate.map { DateHelpers.isSameDay($0, today, calendar: calendar) } ?? false)
                }
                guard existingInSlot == nil else { continue }

                let otherSlot = slot == 1 ? 2 : 1
                let otherTemplateID = occurrences.first {
                    $0.status != .skipped
                        && $0.bonusSlot == otherSlot
                        && ($0.bonusForDate.map { DateHelpers.isSameDay($0, today, calendar: calendar) } ?? false)
                }?.template?.id

                let candidates = eligibleCandidatesForBonusSlot(
                    slot: slot,
                    occurrences: occurrences,
                    today: today,
                    calendar: calendar
                )

                // Prefer a distinct task template from the other bonus slot when available
                let chosen = candidates.first { $0.template?.id != otherTemplateID } ?? candidates.first
                if let chosen {
                    chosen.bonusForDate = today
                    chosen.bonusSlot = slot
                }
            }
        }

        if let preferences {
            let snapshot = evaluate(
                occurrences: occurrences,
                persistedLongestStreak: preferences.longestRecordedStreak,
                today: today,
                calendar: calendar
            )
            if snapshot.longestStreak > preferences.longestRecordedStreak {
                preferences.longestRecordedStreak = snapshot.longestStreak
            }
        }

        try? context.save()
    }

    /// Returns all pending occurrences scheduled within `[tomorrow ... today + 7]` that can be selected into `slot` (1 or 2).
    static func eligibleCandidatesForBonusSlot(
        slot: Int,
        occurrences: [TaskOccurrence],
        today referenceDate: Date = Date(),
        calendar: Calendar = DateHelpers.calendar
    ) -> [TaskOccurrence] {
        let today = DateHelpers.startOfDay(for: referenceDate, calendar: calendar)
        let tomorrow = DateHelpers.addDays(1, to: today, calendar: calendar)
        let maxDay = DateHelpers.addDays(7, to: today, calendar: calendar)

        return occurrences
            .filter { occ in
                guard occ.status == .pending else { return false }
                let sDay = DateHelpers.startOfDay(for: occ.scheduledDate, calendar: calendar)
                guard sDay >= tomorrow && sDay <= maxDay else { return false }

                if let bDate = occ.bonusForDate {
                    // Allow the task already sitting in THIS slot, exclude the task in the OTHER slot
                    return DateHelpers.isSameDay(bDate, today, calendar: calendar) && occ.bonusSlot == slot
                }
                return true
            }
            .sorted { lhs, rhs in
                let lhsFlexible = (lhs.template?.recurrence ?? .once) != .daily
                let rhsFlexible = (rhs.template?.recurrence ?? .once) != .daily
                if lhsFlexible != rhsFlexible {
                    return lhsFlexible && !rhsFlexible
                }
                if lhs.scheduledDate != rhs.scheduledDate {
                    return lhs.scheduledDate < rhs.scheduledDate
                }
                if lhs.displayDurationMinutes != rhs.displayDurationMinutes {
                    return lhs.displayDurationMinutes < rhs.displayDurationMinutes
                }
                return lhs.displayTitle < rhs.displayTitle
            }
    }

    static func selectBonusTask(
        _ newOccurrence: TaskOccurrence,
        forSlot slot: Int,
        occurrences: [TaskOccurrence],
        context: ModelContext,
        today referenceDate: Date = Date(),
        calendar: Calendar = DateHelpers.calendar
    ) {
        let today = DateHelpers.startOfDay(for: referenceDate, calendar: calendar)

        // Release any pending occurrence currently occupying this slot on today
        for occ in occurrences where occ.status == .pending && occ.bonusSlot == slot {
            if let bDate = occ.bonusForDate, DateHelpers.isSameDay(bDate, today, calendar: calendar) {
                occ.bonusForDate = nil
                occ.bonusSlot = 0
            }
        }

        newOccurrence.bonusForDate = today
        newOccurrence.bonusSlot = slot
        try? context.save()
    }
}
