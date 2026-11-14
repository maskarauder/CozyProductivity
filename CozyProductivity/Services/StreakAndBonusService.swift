import Foundation
import SwiftData

struct DayAchievementSummary: Equatable {
    let date: Date
    let baseTotalCount: Int
    let baseCompletedCount: Int
    let bonusCompletedCount: Int
    var optionalBonusTasksEnabled: Bool = true

    var allBaseCompleted: Bool {
        baseTotalCount > 0 && baseCompletedCount == baseTotalCount
    }

    var tier: DayCompletionTier {
        guard allBaseCompleted else { return .none }
        if !optionalBonusTasksEnabled {
            return .gold
        }
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
        optionalBonusTasksEnabled: Bool = true,
        historicalArchive: CozyPreferences.HistoricalStreakArchive? = nil,
        today referenceDate: Date = Date(),
        calendar: Calendar = DateHelpers.calendar
    ) -> StreakSnapshot {
        let today = DateHelpers.startOfDay(for: referenceDate, calendar: calendar)

        let validArchive: (archive: CozyPreferences.HistoricalStreakArchive, endDay: Date)? = {
            guard let archive = historicalArchive,
                  archive.optionalBonusTasksEnabled == optionalBonusTasksEnabled,
                  let endDay = DateHelpers.date(fromDayKey: archive.archivedThroughDayKey, calendar: calendar),
                  endDay < today else {
                return nil
            }
            return (archive, endDay)
        }()

        let archiveCutoffEnd = validArchive?.endDay

        var baseTotalByDay: [Date: Int] = [:]
        var baseDoneByDay: [Date: Int] = [:]
        var bonusDoneByDay: [Date: Int] = [:]
        var allTrackedDays: Set<Date> = []

        for occ in occurrences where occ.status != .skipped {
            if let bDay = occ.bonusDay(calendar: calendar) {
                if occ.isCompleted {
                    if let archiveCutoffEnd, bDay <= archiveCutoffEnd { continue }
                    bonusDoneByDay[bDay, default: 0] += 1
                    allTrackedDays.insert(bDay)
                } else if bDay >= today {
                    // Still pending as an optional bonus candidate today; it remains a future scheduled task
                    let sDay = occ.scheduledDay(calendar: calendar)
                    if let archiveCutoffEnd, sDay <= archiveCutoffEnd { continue }
                    baseTotalByDay[sDay, default: 0] += 1
                    allTrackedDays.insert(sDay)
                }
            } else {
                let sDay = occ.scheduledDay(calendar: calendar)
                if let archiveCutoffEnd, sDay <= archiveCutoffEnd { continue }
                baseTotalByDay[sDay, default: 0] += 1
                if occ.isCompleted {
                    baseDoneByDay[sDay, default: 0] += 1
                }
                allTrackedDays.insert(sDay)
            }
        }

        var summaries: [Date: DayAchievementSummary] = [:]
        var bronzeCount = validArchive?.archive.archivedBaseDays ?? 0
        var silverCount = validArchive?.archive.archivedSilverDays ?? 0
        var goldCount = validArchive?.archive.archivedGoldDays ?? 0

        for day in allTrackedDays {
            let summary = DayAchievementSummary(
                date: day,
                baseTotalCount: baseTotalByDay[day] ?? 0,
                baseCompletedCount: baseDoneByDay[day] ?? 0,
                bonusCompletedCount: bonusDoneByDay[day] ?? 0,
                optionalBonusTasksEnabled: optionalBonusTasksEnabled
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

        var runningStreak = validArchive?.archive.streakEnteringNextDay ?? 0
        var bestStreak = max(
            0,
            max(persistedLongestStreak, validArchive?.archive.longestStreakThroughArchive ?? 0)
        )

        let scanStartDay: Date? = {
            if let archiveEnd = archiveCutoffEnd {
                return DateHelpers.addDays(1, to: archiveEnd, calendar: calendar)
            }
            return allTrackedDays.filter { $0 <= today }.min()
        }()

        guard let earliestDay = scanStartDay else {
            return StreakSnapshot(
                daySummaries: summaries,
                currentStreak: 0,
                longestStreak: bestStreak,
                totalBronzeOrPinkDays: bronzeCount,
                totalSilverDays: silverCount,
                totalGoldDays: goldCount
            )
        }

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

    // MARK: - Incremental Historical Streak Checkpoint

    /// Summarizes immutable completed/missed history strictly before `operationalCutoff` incrementally
    /// so operational views and daily archive updates run in bounded memory without scanning from day 0.
    static func refreshHistoricalArchiveIfNeeded(
        context: ModelContext,
        preferences: CozyPreferences,
        operationalCutoff: Date,
        today referenceDate: Date = Date(),
        calendar: Calendar = DateHelpers.calendar
    ) {
        let today = DateHelpers.startOfDay(for: referenceDate, calendar: calendar)
        let cutoffStart = DateHelpers.startOfDay(for: operationalCutoff, calendar: calendar)
        let archiveThroughDay = DateHelpers.addDays(-1, to: cutoffStart, calendar: calendar)
        guard archiveThroughDay < today else { return }

        let targetArchiveKey = DateHelpers.dayKeyString(for: archiveThroughDay, calendar: calendar)
        let bonusEnabled = preferences.optionalBonusTasksEnabled

        if let existing = preferences.historicalStreakArchive,
           existing.archivedThroughDayKey == targetArchiveKey,
           existing.optionalBonusTasksEnabled == bonusEnabled {
            return
        }

        // Include a 9-day upper margin on `scheduledDate` so any bonus occurrence completed on `<= archiveThroughDay`
        // (originally scheduled up to 7 days later) is captured accurately.
        let upperFetchBound = DateHelpers.addDays(9, to: archiveThroughDay, calendar: calendar)
        let skippedRaw = OccurrenceStatus.skipped.rawValue

        // Determine whether we can extend incrementally from `existing.archivedThroughDayKey`!
        let incrementalStartDay: Date? = {
            guard let existing = preferences.historicalStreakArchive,
                  existing.optionalBonusTasksEnabled == bonusEnabled,
                  let prevEndDay = DateHelpers.date(fromDayKey: existing.archivedThroughDayKey, calendar: calendar),
                  prevEndDay < archiveThroughDay else {
                return nil
            }
            return DateHelpers.addDays(1, to: prevEndDay, calendar: calendar)
        }()

        let candidates: [TaskOccurrence]
        if let deltaStart = incrementalStartDay {
            let lowerFetchBound = DateHelpers.addDays(-3, to: deltaStart, calendar: calendar)
            let descriptor = FetchDescriptor<TaskOccurrence>(
                predicate: #Predicate<TaskOccurrence> { occ in
                    occ.statusRaw != skippedRaw
                        && occ.scheduledDate >= lowerFetchBound
                        && occ.scheduledDate <= upperFetchBound
                }
            )
            candidates = (try? context.fetch(descriptor)) ?? []
        } else {
            let descriptor = FetchDescriptor<TaskOccurrence>(
                predicate: #Predicate<TaskOccurrence> { occ in
                    occ.statusRaw != skippedRaw && occ.scheduledDate <= upperFetchBound
                }
            )
            candidates = (try? context.fetch(descriptor)) ?? []
        }

        let lowerEvalDay = incrementalStartDay
        var baseTotalByDay: [Date: Int] = [:]
        var baseDoneByDay: [Date: Int] = [:]
        var bonusDoneByDay: [Date: Int] = [:]
        var trackedDays: Set<Date> = []

        for occ in candidates where occ.status != .skipped {
            if let bDay = occ.bonusDay(calendar: calendar) {
                let aboveLower = lowerEvalDay.map { bDay >= $0 } ?? true
                if occ.isCompleted && aboveLower && bDay <= archiveThroughDay {
                    bonusDoneByDay[bDay, default: 0] += 1
                    trackedDays.insert(bDay)
                }
            } else {
                let sDay = occ.scheduledDay(calendar: calendar)
                let aboveLower = lowerEvalDay.map { sDay >= $0 } ?? true
                if aboveLower && sDay <= archiveThroughDay {
                    baseTotalByDay[sDay, default: 0] += 1
                    if occ.isCompleted {
                        baseDoneByDay[sDay, default: 0] += 1
                    }
                    trackedDays.insert(sDay)
                }
            }
        }

        let priorArchive = incrementalStartDay != nil ? preferences.historicalStreakArchive : nil
        var archivedBase = priorArchive?.archivedBaseDays ?? 0
        var archivedSilver = priorArchive?.archivedSilverDays ?? 0
        var archivedGold = priorArchive?.archivedGoldDays ?? 0
        var runningStreak = priorArchive?.streakEnteringNextDay ?? 0
        var bestStreak = priorArchive?.longestStreakThroughArchive ?? 0

        var summaries: [Date: DayAchievementSummary] = [:]
        for day in trackedDays {
            let summary = DayAchievementSummary(
                date: day,
                baseTotalCount: baseTotalByDay[day] ?? 0,
                baseCompletedCount: baseDoneByDay[day] ?? 0,
                bonusCompletedCount: bonusDoneByDay[day] ?? 0,
                optionalBonusTasksEnabled: bonusEnabled
            )
            summaries[day] = summary
            switch summary.tier {
            case .none: break
            case .base: archivedBase += 1
            case .silver: archivedSilver += 1
            case .gold: archivedGold += 1
            }
        }

        let scanStartDay: Date? = {
            if let deltaStart = incrementalStartDay {
                return deltaStart
            }
            return trackedDays.min()
        }()

        if let earliest = scanStartDay, earliest <= archiveThroughDay {
            let span = max(0, DateHelpers.daysBetween(earliest, and: archiveThroughDay, calendar: calendar))
            for offset in 0...span {
                let day = DateHelpers.addDays(offset, to: earliest, calendar: calendar)
                guard let summary = summaries[day], summary.baseTotalCount > 0 else { continue }
                switch summary.tier {
                case .gold:
                    runningStreak += 1
                    bestStreak = max(bestStreak, runningStreak)
                case .silver:
                    break
                case .base, .none:
                    runningStreak = 0
                }
            }
        }

        preferences.historicalStreakArchive = CozyPreferences.HistoricalStreakArchive(
            archivedThroughDayKey: targetArchiveKey,
            streakEnteringNextDay: runningStreak,
            longestStreakThroughArchive: bestStreak,
            archivedGoldDays: archivedGold,
            archivedSilverDays: archivedSilver,
            archivedBaseDays: archivedBase,
            optionalBonusTasksEnabled: bonusEnabled
        )
        if bestStreak > preferences.longestRecordedStreak {
            preferences.longestRecordedStreak = bestStreak
        }
    }

    // MARK: - Two Optional Bonus Tasks Management (Selectable from Next 7 Days)

    /// Ensures that once all base tasks for `today` are completed, up to 2 upcoming tasks from `[tomorrow ... today + 7]`
    /// are populated into Bonus Slots 1 & 2 (and clears uncompleted bonus slots if base tasks aren't all complete or bonus tasks are disabled).
    static func syncBonusSlots(
        context: ModelContext,
        occurrences: [TaskOccurrence],
        preferences: CozyPreferences? = nil,
        today referenceDate: Date = Date(),
        calendar: Calendar = DateHelpers.calendar
    ) {
        let today = DateHelpers.startOfDay(for: referenceDate, calendar: calendar)
        let bonusEnabled = preferences?.optionalBonusTasksEnabled ?? true

        // Clean up any stale pending bonus assignments from past days (or all pending bonus slots when disabled)
        for occ in occurrences where occ.status == .pending {
            if let bDay = occ.bonusDay(calendar: calendar) {
                if !bonusEnabled || bDay < today {
                    occ.setBonusDay(nil, calendar: calendar)
                }
            }
        }

        if bonusEnabled {
            let baseToday = occurrences.filter {
                $0.status != .skipped
                    && $0.bonusDay(calendar: calendar) == nil
                    && DateHelpers.isSameDay($0.scheduledDay(calendar: calendar), today, calendar: calendar)
            }
            let allBaseCompleted = !baseToday.isEmpty && baseToday.allSatisfy(\.isCompleted)

            if !allBaseCompleted {
                // Hide/release uncompleted optional bonus slots until all base tasks are done
                for occ in occurrences where occ.status == .pending {
                    if let bDay = occ.bonusDay(calendar: calendar), DateHelpers.isSameDay(bDay, today, calendar: calendar) {
                        occ.setBonusDay(nil, calendar: calendar)
                    }
                }
            } else {
                for slot in [1, 2] {
                    let existingInSlot = occurrences.first {
                        $0.status != .skipped
                            && $0.bonusSlot == slot
                            && ($0.bonusDay(calendar: calendar).map { DateHelpers.isSameDay($0, today, calendar: calendar) } ?? false)
                    }
                    guard existingInSlot == nil else { continue }

                    let otherSlot = slot == 1 ? 2 : 1
                    let otherTemplateID = occurrences.first {
                        $0.status != .skipped
                            && $0.bonusSlot == otherSlot
                            && ($0.bonusDay(calendar: calendar).map { DateHelpers.isSameDay($0, today, calendar: calendar) } ?? false)
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
                        chosen.setBonusDay(today, slot: slot, calendar: calendar)
                    }
                }
            }
        }

        if let preferences, preferences.streaksEnabled {
            let snapshot = evaluate(
                occurrences: occurrences,
                persistedLongestStreak: preferences.longestRecordedStreak,
                optionalBonusTasksEnabled: bonusEnabled,
                historicalArchive: preferences.historicalStreakArchive,
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
                let sDay = occ.scheduledDay(calendar: calendar)
                guard sDay >= tomorrow && sDay <= maxDay else { return false }

                if let bDay = occ.bonusDay(calendar: calendar) {
                    // Allow the task already sitting in THIS slot, exclude the task in the OTHER slot
                    return DateHelpers.isSameDay(bDay, today, calendar: calendar) && occ.bonusSlot == slot
                }
                return true
            }
            .sorted { lhs, rhs in
                let lhsFlexible = lhs.displayRecurrenceKind != .daily
                let rhsFlexible = rhs.displayRecurrenceKind != .daily
                if lhsFlexible != rhsFlexible {
                    return lhsFlexible && !rhsFlexible
                }
                let lhsDay = lhs.scheduledDay(calendar: calendar)
                let rhsDay = rhs.scheduledDay(calendar: calendar)
                if lhsDay != rhsDay {
                    return lhsDay < rhsDay
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
            if let bDay = occ.bonusDay(calendar: calendar), DateHelpers.isSameDay(bDay, today, calendar: calendar) {
                occ.setBonusDay(nil, calendar: calendar)
            }
        }

        newOccurrence.setBonusDay(today, slot: slot, calendar: calendar)
        try? context.save()
    }
}
