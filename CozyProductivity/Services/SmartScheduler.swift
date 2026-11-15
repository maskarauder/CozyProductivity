import Foundation
import SwiftData

struct DayCapacitySummary: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let baseBudgetMinutes: Int
    let calendarBusyMinutes: Int
    let effectiveCapacityMinutes: Int
    let unbookedWakingMinutes: Int
    /// Effective weighted load scheduled (`durationMinutes` + weight extra minutes: +0m light, +30m normal, +60m heavy).
    let scheduledMinutes: Int
    /// Raw clock minutes scheduled (without weight bonus).
    let scheduledClockMinutes: Int
    /// Effective weighted load completed.
    let completedMinutes: Int
    /// Raw clock minutes completed.
    let completedClockMinutes: Int
    /// Non-nil when this day's capacity comes from the user's 0–5h Daily Cup check-in.
    let activeCupHours: Int?

    init(
        date: Date,
        baseBudgetMinutes: Int,
        calendarBusyMinutes: Int,
        effectiveCapacityMinutes: Int,
        unbookedWakingMinutes: Int,
        scheduledMinutes: Int,
        scheduledClockMinutes: Int? = nil,
        completedMinutes: Int,
        completedClockMinutes: Int? = nil,
        activeCupHours: Int? = nil
    ) {
        self.date = date
        self.baseBudgetMinutes = baseBudgetMinutes
        self.calendarBusyMinutes = calendarBusyMinutes
        self.effectiveCapacityMinutes = effectiveCapacityMinutes
        self.unbookedWakingMinutes = unbookedWakingMinutes
        self.scheduledMinutes = scheduledMinutes
        self.scheduledClockMinutes = scheduledClockMinutes ?? scheduledMinutes
        self.completedMinutes = completedMinutes
        self.completedClockMinutes = completedClockMinutes ?? completedMinutes
        self.activeCupHours = activeCupHours
    }

    var remainingFreeMinutes: Int {
        max(0, effectiveCapacityMinutes - scheduledMinutes)
    }

    var netBalanceMinutes: Int {
        effectiveCapacityMinutes - scheduledMinutes
    }

    var isOverCapacity: Bool {
        scheduledMinutes > effectiveCapacityMinutes
    }

    var utilizationFraction: Double {
        guard effectiveCapacityMinutes > 0 else {
            return scheduledMinutes > 0 ? 1.0 : 0.0
        }
        return min(1.0, Double(scheduledMinutes) / Double(effectiveCapacityMinutes))
    }
}

@MainActor
enum SmartScheduler {
    nonisolated static let defaultHorizonDays = 35
    nonisolated static let operationalHistoryBufferDays = 69
    nonisolated static let streakArchiveCutoffDays = 62

    // MARK: - Core Rebalance Entry Point

    static func rebalance(
        context: ModelContext,
        preferences: CozyPreferences,
        calendarBusyByDay: [Date: Int] = [:],
        referenceDate: Date = DateHelpers.logicalToday(),
        horizonDays: Int = defaultHorizonDays,
        calendar: Calendar = DateHelpers.calendar
    ) {
        CozyDataMigrator.migrateIfNeeded(context: context, preferences: preferences, calendar: calendar)

        let today = DateHelpers.startOfDay(for: referenceDate, calendar: calendar)
        let safeHorizon = max(7, horizonDays)
        let horizonEnd = DateHelpers.addDays(safeHorizon - 1, to: today, calendar: calendar)
        let tomorrow = min(horizonEnd, DateHelpers.addDays(1, to: today, calendar: calendar))
        let hasTodayCup = preferences.hasCupCheckIn(for: today, calendar: calendar)
        let todayCupHours = preferences.cupHours(for: today, calendar: calendar)

        let fetchCutoff = DateHelpers.addDays(-operationalHistoryBufferDays, to: today, calendar: calendar)
        let pendingRaw = OccurrenceStatus.pending.rawValue
        let occDescriptor = FetchDescriptor<TaskOccurrence>(
            predicate: #Predicate<TaskOccurrence> { occ in
                occ.statusRaw == pendingRaw || occ.scheduledDate >= fetchCutoff
            }
        )

        let templates = (try? context.fetch(FetchDescriptor<TaskTemplate>())) ?? []
        let allOccurrences = (try? context.fetch(occDescriptor)) ?? []
        let overrides = (try? context.fetch(FetchDescriptor<DayCapacityOverride>())) ?? []

        for template in templates {
            template.normalizeCivilDates(in: calendar)
        }

        // 1. Build capacity & waking-hour tie-breaker tables for [today ... horizonEnd]
        var overrideMap: [Date: Int] = [:]
        for item in overrides {
            overrideMap[item.normalizedDay(calendar: calendar)] = item.availableMinutes
        }

        var capacityByDay: [Date: Int] = [:]
        var unbookedByDay: [Date: Int] = [:]
        var usedMinutesByDay: [Date: Int] = [:]
        var accountedLoadByOccurrenceID: [UUID: (day: Date, minutes: Int)] = [:]

        for offset in 0..<safeHorizon {
            let day = DateHelpers.addDays(offset, to: today, calendar: calendar)
            let stats = computeDayCapacity(
                for: day,
                preferences: preferences,
                overrideMinutes: overrideMap[day],
                calendarBusyMinutes: calendarBusyByDay[day] ?? 0,
                calendar: calendar
            )
            capacityByDay[day] = stats.effectiveCapacity
            unbookedByDay[day] = stats.unbookedWaking
            usedMinutesByDay[day] = 0
        }

        // 2. Reconcile past uncompleted occurrences & inactive/changed templates
        let todayDailyKey = DateHelpers.dailyWindow(for: today, calendar: calendar).key
        var survivingOccurrences: [TaskOccurrence] = []

        for occ in allOccurrences {
            let occDay = occ.normalizeCivilDates(in: calendar)

            if occ.status == .pending,
               let bDay = occ.bonusDay(calendar: calendar),
               bDay < today {
                occ.setBonusDay(nil, calendar: calendar)
            }

            guard let template = occ.template else {
                if occ.status == .pending {
                    deleteOccurrence(occ, context: context, preferences: preferences)
                } else {
                    survivingOccurrences.append(occ)
                }
                continue
            }

            if !template.isActive {
                if occ.status == .pending {
                    deleteOccurrence(occ, context: context, preferences: preferences)
                } else {
                    survivingOccurrences.append(occ)
                }
                continue
            }

            // Refresh snapshots on pending items only; completed/missed/skipped history remains frozen.
            if occ.status == .pending {
                if !periodKeyMatchesRecurrence(occ.periodKey, recurrence: template.recurrence, intervalDays: template.customIntervalDays) {
                    deleteOccurrence(occ, context: context, preferences: preferences)
                    continue
                }

                let occWindow = DateHelpers.periodWindow(for: template, containing: occDay, calendar: calendar)
                let scopedDeadline = effectivePeriodDeadline(for: template, window: occWindow, calendar: calendar)
                occ.refreshPendingSnapshotsFromTemplate(periodDeadline: scopedDeadline, calendar: calendar)

                // If Today's cup is 0 (empty) and this task isn't forced today by an active period deadline, unpin so it can move back
                if hasTodayCup && todayCupHours == 0 && occDay == today {
                    let forcedToday = scopedDeadline.map { $0 <= today } ?? false
                    if !forcedToday {
                        occ.isManuallyPinned = false
                    }
                }
            }

            // Handle unfinished occurrences from strictly before today (or expired recurring periods)
            if occ.status == .pending {
                switch template.recurrence {
                case .daily:
                    if occDay < today || occ.periodKey < todayDailyKey {
                        // Retire the commitment without erasing it from that day's achievement total.
                        markMissedOccurrence(occ, template: template, calendar: calendar)
                        survivingOccurrences.append(occ)
                    } else {
                        survivingOccurrences.append(occ)
                    }

                case .once:
                    if occDay < today {
                        // Unfinished once task rolls forward (or stays forced onto today if hard deadline <= today)
                        occ.isManuallyPinned = false
                    }
                    survivingOccurrences.append(occ)

                case .weekly, .biweekly, .monthly, .customDays:
                    let currentWindow = DateHelpers.periodWindow(for: template, containing: today, calendar: calendar)
                    if occ.periodKey < currentWindow.key {
                        // Preserve the expired commitment in history without adding it to the new period.
                        markMissedOccurrence(occ, template: template, calendar: calendar)
                        survivingOccurrences.append(occ)
                    } else if occDay < today {
                        // Still inside currentWindow, just earlier in the week/month -> unpin to reschedule onto remaining days
                        occ.isManuallyPinned = false
                        survivingOccurrences.append(occ)
                    } else {
                        survivingOccurrences.append(occ)
                    }
                }
            } else {
                survivingOccurrences.append(occ)
            }
        }

        // Index surviving occurrences by (template.id, periodKey)
        var occurrencesByTemplateAndPeriod: [String: TaskOccurrence] = [:]
        for occ in survivingOccurrences {
            guard let templateID = occ.template?.id else { continue }
            let mapKey = "\(templateID.uuidString)|\(occ.periodKey)"
            if let existing = occurrencesByTemplateAndPeriod[mapKey] {
                if existing.status != .completed && occ.status == .completed {
                    if existing.status == .pending {
                        deleteOccurrence(existing, context: context, preferences: preferences)
                    }
                    occurrencesByTemplateAndPeriod[mapKey] = occ
                } else if occ.status == .pending {
                    deleteOccurrence(occ, context: context, preferences: preferences)
                }
            } else {
                occurrencesByTemplateAndPeriod[mapKey] = occ
            }
        }

        // 3. Count completed occurrences FIRST using effectiveLoadMinutes (includes weight adjustments!)
        for occ in survivingOccurrences where occ.status == .completed {
            let effectiveDay = occ.bonusDay(calendar: calendar) ?? occ.scheduledDay(calendar: calendar)
            recordOccurrenceLoad(
                occ,
                on: effectiveDay,
                horizonStart: today,
                horizonEnd: horizonEnd,
                usedMinutesByDay: &usedMinutesByDay,
                accountedLoadByOccurrenceID: &accountedLoadByOccurrenceID
            )
        }

        // Count manually-pinned pending items — UNLESS Today's cup cannot fit a non-deadline pinned item on today
        for occ in occurrencesByTemplateAndPeriod.values where occ.status == .pending && occ.isManuallyPinned {
            let d = occ.scheduledDay(calendar: calendar)
            guard d >= today && d <= horizonEnd else { continue }
            if d == today && hasTodayCup {
                let forcedToday = occ.effectiveHardDeadline(calendar: calendar).map { $0 <= today } ?? false
                let todayRem = (capacityByDay[today] ?? 0) - (usedMinutesByDay[today] ?? 0)
                if !forcedToday && (todayCupHours == 0 || todayRem < occ.effectiveLoadMinutes) {
                    // Today's cup is empty or exceeded -> unpin & move back!
                    occ.isManuallyPinned = false
                    continue
                }
            }
            recordOccurrenceLoad(
                occ,
                on: d,
                horizonStart: today,
                horizonEnd: horizonEnd,
                usedMinutesByDay: &usedMinutesByDay,
                accountedLoadByOccurrenceID: &accountedLoadByOccurrenceID
            )
        }

        let activeTemplates = templates.filter { $0.isActive }

        // 4. Phase A: Urgent Hard-Deadline Tasks Forced Onto Today (`effectivePeriodDeadline <= today`)
        // Scheduled FIRST so they always appear on Today even when cup == 0, and claim Today's cup before non-deadline tasks.
        // Uses `recordOccurrenceLoad` so pinned deadline occurrences are NEVER double-counted!
        var templatesHandledForTodayDeadline: Set<String> = []
        for template in activeTemplates {
            if template.recurrence == .once {
                guard let dl = template.normalizedHardDeadline(calendar: calendar), dl <= today else { continue }
                let pKey = "once:\(template.id.uuidString)"
                let mapKey = "\(template.id.uuidString)|\(pKey)"
                let alreadyCompleted = isOnceTemplateCompleted(template, survivingOccurrences: survivingOccurrences)
                guard !alreadyCompleted else {
                    templatesHandledForTodayDeadline.insert(mapKey)
                    continue
                }
                if let existing = occurrencesByTemplateAndPeriod[mapKey] {
                    if existing.status == .pending {
                        existing.setScheduledDay(today, calendar: calendar)
                        existing.setBonusDay(nil, calendar: calendar)
                        recordOccurrenceLoad(
                            existing,
                            on: today,
                            horizonStart: today,
                            horizonEnd: horizonEnd,
                            usedMinutesByDay: &usedMinutesByDay,
                            accountedLoadByOccurrenceID: &accountedLoadByOccurrenceID
                        )
                    }
                } else {
                    let created = TaskOccurrence(
                        scheduledDate: today,
                        periodKey: pKey,
                        status: .pending,
                        isManuallyPinned: false,
                        template: template,
                        calendar: calendar
                    )
                    context.insert(created)
                    occurrencesByTemplateAndPeriod[mapKey] = created
                    recordOccurrenceLoad(
                        created,
                        on: today,
                        horizonStart: today,
                        horizonEnd: horizonEnd,
                        usedMinutesByDay: &usedMinutesByDay,
                        accountedLoadByOccurrenceID: &accountedLoadByOccurrenceID
                    )
                }
                templatesHandledForTodayDeadline.insert(mapKey)
            } else {
                let window = DateHelpers.periodWindow(for: template, containing: today, calendar: calendar)
                guard let dl = effectivePeriodDeadline(for: template, window: window, calendar: calendar),
                      dl <= today else {
                    continue
                }
                let mapKey = "\(template.id.uuidString)|\(window.key)"
                if let existing = occurrencesByTemplateAndPeriod[mapKey] {
                    if existing.status == .pending {
                        existing.setScheduledDay(today, calendar: calendar)
                        existing.setBonusDay(nil, calendar: calendar)
                        recordOccurrenceLoad(
                            existing,
                            on: today,
                            horizonStart: today,
                            horizonEnd: horizonEnd,
                            usedMinutesByDay: &usedMinutesByDay,
                            accountedLoadByOccurrenceID: &accountedLoadByOccurrenceID
                        )
                    }
                } else {
                    let created = TaskOccurrence(
                        scheduledDate: today,
                        periodKey: window.key,
                        status: .pending,
                        isManuallyPinned: false,
                        template: template,
                        calendar: calendar
                    )
                    context.insert(created)
                    occurrencesByTemplateAndPeriod[mapKey] = created
                    recordOccurrenceLoad(
                        created,
                        on: today,
                        horizonStart: today,
                        horizonEnd: horizonEnd,
                        usedMinutesByDay: &usedMinutesByDay,
                        accountedLoadByOccurrenceID: &accountedLoadByOccurrenceID
                    )
                }
                templatesHandledForTodayDeadline.insert(mapKey)
            }
        }

        // 5. Phase B: Fixed commitments (Daily tasks + non-auto-scheduled templates)
        for template in activeTemplates where template.recurrence == .daily || !template.isAutoScheduled {
            scheduleFixedTemplate(
                template,
                today: today,
                tomorrow: tomorrow,
                horizonEnd: horizonEnd,
                hasTodayCup: hasTodayCup,
                todayCupHours: todayCupHours,
                handledMapKeys: templatesHandledForTodayDeadline,
                survivingOccurrences: survivingOccurrences,
                occurrencesMap: &occurrencesByTemplateAndPeriod,
                usedMinutesByDay: &usedMinutesByDay,
                accountedLoadByOccurrenceID: &accountedLoadByOccurrenceID,
                capacityByDay: capacityByDay,
                unbookedByDay: unbookedByDay,
                preferences: preferences,
                context: context,
                calendar: calendar
            )
        }

        // 6. Phase C: Flexible auto-scheduled tasks (Once, Weekly, Biweekly, Monthly, Custom)
        struct FlexibleJob {
            let template: TaskTemplate
            let periodKey: String
            let candidateStart: Date
            let candidateEnd: Date
            let hardDeadline: Date?
            let existingOccurrence: TaskOccurrence?
            let calendar: Calendar

            var effectiveLoad: Int {
                existingOccurrence?.effectiveLoadMinutes ?? template.effectiveLoadMinutes
            }

            var windowDaySpan: Int {
                max(1, DateHelpers.daysBetween(candidateStart, and: candidateEnd, calendar: calendar) + 1)
            }
        }

        let baseTodayItems = occurrencesByTemplateAndPeriod.values.filter {
            $0.status.isScheduled
                && $0.bonusDay(calendar: calendar) == nil
                && DateHelpers.isSameDay($0.scheduledDay(calendar: calendar), today, calendar: calendar)
        }
        let isTodayAlreadyFinished = !baseTodayItems.isEmpty && baseTodayItems.allSatisfy(\.isCompleted)
        let defaultFlexibleFloor = isTodayAlreadyFinished ? tomorrow : today

        var jobs: [FlexibleJob] = []

        for template in activeTemplates where template.recurrence != .daily && template.isAutoScheduled {
            let templateDeadline = template.normalizedHardDeadline(calendar: calendar)

            if template.recurrence == .once {
                let pKey = "once:\(template.id.uuidString)"
                let mapKey = "\(template.id.uuidString)|\(pKey)"
                if templatesHandledForTodayDeadline.contains(mapKey) {
                    continue
                }

                let anchor = template.normalizedAnchorDate(calendar: calendar)

                if let existing = occurrencesByTemplateAndPeriod[mapKey] {
                    if existing.status != .pending || existing.isManuallyPinned {
                        continue
                    }
                    let isTodayBonus = existing.bonusDay(calendar: calendar).map { DateHelpers.isSameDay($0, today, calendar: calendar) } ?? false
                    let baseFloor = isTodayBonus ? tomorrow : defaultFlexibleFloor
                    let desiredStart = max(baseFloor, anchor)

                    if desiredStart > horizonEnd && (templateDeadline == nil || templateDeadline! > horizonEnd) {
                        existing.setScheduledDay(desiredStart, calendar: calendar)
                        continue
                    }

                    var start = min(horizonEnd, desiredStart)
                    var end = min(horizonEnd, DateHelpers.addDays(max(0, template.flexibleWindowDays - 1), to: start, calendar: calendar))
                    if let dl = templateDeadline {
                        if dl > horizonEnd && desiredStart > horizonEnd {
                            existing.setScheduledDay(min(desiredStart, dl), calendar: calendar)
                            continue
                        }
                        let clampedDL = min(horizonEnd, max(today, dl))
                        start = min(start, clampedDL)
                        end = clampedDL
                    }
                    jobs.append(FlexibleJob(
                        template: template,
                        periodKey: pKey,
                        candidateStart: start,
                        candidateEnd: max(start, end),
                        hardDeadline: templateDeadline,
                        existingOccurrence: existing,
                        calendar: calendar
                    ))
                } else {
                    let alreadyDone = isOnceTemplateCompleted(template, survivingOccurrences: survivingOccurrences)
                    if !alreadyDone {
                        let baseAnchor = max(defaultFlexibleFloor, anchor)
                        // Defer creating occurrences whose requested start & deadline lie strictly beyond the optimization horizon
                        if baseAnchor > horizonEnd && (templateDeadline == nil || templateDeadline! > horizonEnd) {
                            continue
                        }
                        var start = min(horizonEnd, baseAnchor)
                        var end = min(horizonEnd, DateHelpers.addDays(max(0, template.flexibleWindowDays - 1), to: start, calendar: calendar))
                        if let dl = templateDeadline {
                            let clampedDL = min(horizonEnd, max(today, dl))
                            start = min(start, clampedDL)
                            end = clampedDL
                        }
                        jobs.append(FlexibleJob(
                            template: template,
                            periodKey: pKey,
                            candidateStart: start,
                            candidateEnd: max(start, end),
                            hardDeadline: templateDeadline,
                            existingOccurrence: nil,
                            calendar: calendar
                        ))
                    }
                }
            } else {
                // Recurring flexible: enumerate periods overlapping [today ... horizonEnd]
                var cursor = today
                while cursor <= horizonEnd {
                    let window = DateHelpers.periodWindow(for: template, containing: cursor, calendar: calendar)
                    let mapKey = "\(template.id.uuidString)|\(window.key)"
                    if !templatesHandledForTodayDeadline.contains(mapKey) {
                        let rawStart = max(today, window.start)
                        var cEnd = min(horizonEnd, window.end)

                        let applicableDeadline = effectivePeriodDeadline(for: template, window: window, calendar: calendar)
                        if let dl = applicableDeadline {
                            cEnd = min(cEnd, max(today, dl))
                        }

                        if rawStart <= cEnd {
                            if let existing = occurrencesByTemplateAndPeriod[mapKey] {
                                if existing.status == .pending && !existing.isManuallyPinned {
                                    let isTodayBonus = existing.bonusDay(calendar: calendar).map { DateHelpers.isSameDay($0, today, calendar: calendar) } ?? false
                                    let preferredStart = (isTodayBonus || isTodayAlreadyFinished) ? max(tomorrow, window.start) : rawStart
                                    let finalStart = preferredStart <= cEnd ? preferredStart : rawStart
                                    jobs.append(FlexibleJob(
                                        template: template,
                                        periodKey: window.key,
                                        candidateStart: finalStart,
                                        candidateEnd: cEnd,
                                        hardDeadline: applicableDeadline,
                                        existingOccurrence: existing,
                                        calendar: calendar
                                    ))
                                }
                            } else {
                                let preferredStart = isTodayAlreadyFinished ? max(tomorrow, window.start) : rawStart
                                let finalStart = preferredStart <= cEnd ? preferredStart : rawStart
                                jobs.append(FlexibleJob(
                                    template: template,
                                    periodKey: window.key,
                                    candidateStart: finalStart,
                                    candidateEnd: cEnd,
                                    hardDeadline: applicableDeadline,
                                    existingOccurrence: nil,
                                    calendar: calendar
                                ))
                            }
                        }
                    }

                    cursor = DateHelpers.addDays(1, to: window.end, calendar: calendar)
                }
            }
        }

        // Sort jobs:
        // 1. Hard-deadline tasks first (earliest deadline first) so they claim open cup/budget before optional flexible tasks
        // 2. Tightest candidate window first
        // 3. Largest effective weighted load (`duration + weight bonus`) first (LPT load balancing)
        jobs.sort { lhs, rhs in
            switch (lhs.hardDeadline, rhs.hardDeadline) {
            case let (lDL?, rDL?):
                if lDL != rDL { return lDL < rDL }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            if lhs.windowDaySpan != rhs.windowDaySpan {
                return lhs.windowDaySpan < rhs.windowDaySpan
            }
            if lhs.effectiveLoad != rhs.effectiveLoad {
                return lhs.effectiveLoad > rhs.effectiveLoad
            }
            return lhs.template.createdAt < rhs.template.createdAt
        }

        for job in jobs {
            var searchStart = job.candidateStart
            var searchEnd = job.candidateEnd

            if let dl = job.hardDeadline, dl <= today {
                searchStart = today
                searchEnd = today
            } else if searchStart == today && hasTodayCup {
                let todayRemaining = (capacityByDay[today] ?? 0) - (usedMinutesByDay[today] ?? 0)
                let todayCannotFit = (todayCupHours == 0) || (todayRemaining < job.effectiveLoad)

                if todayCannotFit {
                    // Move back off Today when Today's cup is empty (0h) or lacks enough remaining hours!
                    searchStart = tomorrow
                    if searchEnd < searchStart {
                        if let dl = job.hardDeadline {
                            searchEnd = max(searchStart, min(horizonEnd, dl))
                        } else {
                            searchEnd = min(horizonEnd, DateHelpers.addDays(6, to: searchStart, calendar: calendar))
                        }
                    }
                }
            }

            let chosenDay = chooseFreestDay(
                from: searchStart,
                to: max(searchStart, searchEnd),
                taskDuration: job.effectiveLoad,
                capacityByDay: capacityByDay,
                unbookedByDay: unbookedByDay,
                usedMinutesByDay: usedMinutesByDay,
                calendar: calendar
            )

            let placedOcc: TaskOccurrence
            if let existing = job.existingOccurrence {
                existing.setScheduledDay(chosenDay, calendar: calendar)
                existing.status = .pending
                placedOcc = existing
            } else {
                let created = TaskOccurrence(
                    scheduledDate: chosenDay,
                    periodKey: job.periodKey,
                    status: .pending,
                    isManuallyPinned: false,
                    template: job.template,
                    calendar: calendar
                )
                context.insert(created)
                let mapKey = "\(job.template.id.uuidString)|\(job.periodKey)"
                occurrencesByTemplateAndPeriod[mapKey] = created
                placedOcc = created
            }

            recordOccurrenceLoad(
                placedOcc,
                on: chosenDay,
                horizonStart: today,
                horizonEnd: horizonEnd,
                usedMinutesByDay: &usedMinutesByDay,
                accountedLoadByOccurrenceID: &accountedLoadByOccurrenceID
            )
        }

        let archiveCutoff = DateHelpers.addDays(-streakArchiveCutoffDays, to: today, calendar: calendar)
        StreakAndBonusService.refreshHistoricalArchiveIfNeeded(
            context: context,
            preferences: preferences,
            operationalCutoff: archiveCutoff,
            today: today,
            calendar: calendar
        )

        let updatedOccurrences = (try? context.fetch(occDescriptor)) ?? []
        StreakAndBonusService.syncBonusSlots(
            context: context,
            occurrences: updatedOccurrences,
            preferences: preferences,
            today: today,
            calendar: calendar
        )
    }

    // MARK: - Pure Day Selection & Capacity Calculation

    static func computeDayCapacity(
        for date: Date,
        preferences: CozyPreferences,
        overrideMinutes: Int?,
        calendarBusyMinutes: Int,
        calendar: Calendar = DateHelpers.calendar
    ) -> (baseBudget: Int, effectiveCapacity: Int, unbookedWaking: Int) {
        let wakingMinutes = max(60, (preferences.wakingEndHour - preferences.wakingStartHour) * 60)

        // If the user answered "How full is your cup today?" (0...5 hours) for `date`, use that exact hour budget!
        if let cupHrs = preferences.cupHours(for: date, calendar: calendar) {
            let cupMinutes = max(0, min(5, cupHrs)) * 60
            guard cupMinutes > 0 else {
                return (0, 0, 0)
            }
            guard preferences.hasAnyCalendarBusySyncEnabled else {
                return (cupMinutes, cupMinutes, cupMinutes)
            }
            let unbooked = max(0, wakingMinutes - max(0, calendarBusyMinutes))
            return (cupMinutes, min(cupMinutes, unbooked), unbooked)
        }

        // Otherwise (predicted upcoming days or before morning check-in), use weekday budget / single-day override
        let weekday = calendar.component(.weekday, from: date)
        let baseBudget = overrideMinutes ?? preferences.baseBudgetMinutes(forWeekday: weekday)

        guard preferences.hasAnyCalendarBusySyncEnabled else {
            return (baseBudget, baseBudget, baseBudget)
        }

        let unbooked = max(0, wakingMinutes - max(0, calendarBusyMinutes))
        let effective: Int
        switch preferences.calendarDeductionMode {
        case .subtractFromBudget:
            effective = min(unbooked, max(0, baseBudget - max(0, calendarBusyMinutes)))
        case .capByUnbookedWakingHours:
            effective = min(baseBudget, unbooked)
        }
        return (baseBudget, effective, unbooked)
    }

    static func effectiveCapacityMinutes(
        for date: Date,
        preferences: CozyPreferences,
        overridesByDay: [Date: Int] = [:],
        calendarBusyMinutesByDay: [Date: Int] = [:],
        today: Date? = nil,
        calendar: Calendar = DateHelpers.calendar
    ) -> Int {
        let day = DateHelpers.startOfDay(for: date, calendar: calendar)
        if let today {
            let normToday = DateHelpers.startOfDay(for: today, calendar: calendar)
            if day != normToday {
                // Only `today` uses the daily cup check-in; other days use weekday budget / override
                let weekday = calendar.component(.weekday, from: day)
                let baseBudget = overridesByDay[day] ?? preferences.baseBudgetMinutes(forWeekday: weekday)
                guard preferences.hasAnyCalendarBusySyncEnabled else { return baseBudget }
                let wakingMinutes = max(60, (preferences.wakingEndHour - preferences.wakingStartHour) * 60)
                let busy = max(0, calendarBusyMinutesByDay[day] ?? 0)
                let unbooked = max(0, wakingMinutes - busy)
                switch preferences.calendarDeductionMode {
                case .subtractFromBudget:
                    return min(unbooked, max(0, baseBudget - busy))
                case .capByUnbookedWakingHours:
                    return min(baseBudget, unbooked)
                }
            }
        }
        return computeDayCapacity(
            for: day,
            preferences: preferences,
            overrideMinutes: overridesByDay[day],
            calendarBusyMinutes: calendarBusyMinutesByDay[day] ?? 0,
            calendar: calendar
        ).effectiveCapacity
    }

    static func chooseFreestDay(
        from startDate: Date,
        to endDate: Date,
        taskDuration: Int,
        capacityByDay: [Date: Int],
        unbookedByDay: [Date: Int],
        usedMinutesByDay: [Date: Int],
        calendar: Calendar = DateHelpers.calendar
    ) -> Date {
        let span = max(0, DateHelpers.daysBetween(startDate, and: endDate, calendar: calendar))
        var bestDay = startDate
        var bestRemainingAfter = Int.min
        var bestUnbookedRemaining = Int.min

        for offset in 0...span {
            let candidate = DateHelpers.addDays(offset, to: startDate, calendar: calendar)
            let capacity = capacityByDay[candidate] ?? 90
            let used = usedMinutesByDay[candidate] ?? 0
            let remainingAfter = (capacity - used) - taskDuration
            let unbookedRemaining = (unbookedByDay[candidate] ?? capacity) - used

            if remainingAfter > bestRemainingAfter {
                bestRemainingAfter = remainingAfter
                bestUnbookedRemaining = unbookedRemaining
                bestDay = candidate
            } else if remainingAfter == bestRemainingAfter && unbookedRemaining > bestUnbookedRemaining {
                bestUnbookedRemaining = unbookedRemaining
                bestDay = candidate
            }
        }

        return bestDay
    }

    // MARK: - Day Summaries for UI Visualization (O(N + days))

    static func buildDaySummaries(
        from startDate: Date,
        days: Int,
        occurrences: [TaskOccurrence],
        preferences: CozyPreferences,
        overrides: [DayCapacityOverride],
        calendarBusyByDay: [Date: Int] = [:],
        calendar: Calendar = DateHelpers.calendar
    ) -> [DayCapacitySummary] {
        struct DayLoadAccumulator {
            var totalWeighted = 0
            var totalClock = 0
            var completedWeighted = 0
            var completedClock = 0
        }

        let first = DateHelpers.startOfDay(for: startDate, calendar: calendar)
        let dayCount = max(1, days)
        let last = DateHelpers.addDays(dayCount - 1, to: first, calendar: calendar)

        var overrideMap: [Date: Int] = [:]
        overrideMap.reserveCapacity(overrides.count)
        for item in overrides {
            overrideMap[item.normalizedDay(calendar: calendar)] = item.availableMinutes
        }

        var loadByDay: [Date: DayLoadAccumulator] = [:]
        loadByDay.reserveCapacity(dayCount)

        for occ in occurrences where occ.status.isScheduled {
            let day = occ.isCompleted
                ? (occ.bonusDay(calendar: calendar) ?? occ.scheduledDay(calendar: calendar))
                : occ.scheduledDay(calendar: calendar)
            guard day >= first && day <= last else { continue }

            let weighted = occ.effectiveLoadMinutes
            let clock = occ.displayDurationMinutes
            var acc = loadByDay[day] ?? DayLoadAccumulator()
            acc.totalWeighted += weighted
            acc.totalClock += clock
            if occ.isCompleted {
                acc.completedWeighted += weighted
                acc.completedClock += clock
            }
            loadByDay[day] = acc
        }

        var summaries: [DayCapacitySummary] = []
        summaries.reserveCapacity(dayCount)

        for offset in 0..<dayCount {
            let day = DateHelpers.addDays(offset, to: first, calendar: calendar)
            let busy = calendarBusyByDay[day] ?? 0
            let cap = computeDayCapacity(
                for: day,
                preferences: preferences,
                overrideMinutes: overrideMap[day],
                calendarBusyMinutes: busy,
                calendar: calendar
            )

            let acc = loadByDay[day] ?? DayLoadAccumulator()

            summaries.append(
                DayCapacitySummary(
                    date: day,
                    baseBudgetMinutes: cap.baseBudget,
                    calendarBusyMinutes: busy,
                    effectiveCapacityMinutes: cap.effectiveCapacity,
                    unbookedWakingMinutes: cap.unbookedWaking,
                    scheduledMinutes: acc.totalWeighted,
                    scheduledClockMinutes: acc.totalClock,
                    completedMinutes: acc.completedWeighted,
                    completedClockMinutes: acc.completedClock,
                    activeCupHours: preferences.cupHours(for: day, calendar: calendar)
                )
            )
        }
        return summaries
    }

    // MARK: - Starter Seed Tasks

    static func seedStarterTasksIfNeeded(context: ModelContext, preferences: CozyPreferences) {
        guard !preferences.hasSeededStarterTasks else { return }
        let existingCount = (try? context.fetchCount(FetchDescriptor<TaskTemplate>())) ?? 0
        guard existingCount == 0 else {
            preferences.hasSeededStarterTasks = true
            try? context.save()
            return
        }

        let today = DateHelpers.logicalToday()
        let starters: [TaskTemplate] = [
            TaskTemplate(
                title: "Morning stretch & make the bed",
                notes: "Open the blinds, sip water, and take 3 slow breaths.",
                emoji: "🌸",
                category: .selfCare,
                recurrence: .daily,
                durationMinutes: 15,
                weight: .light,
                isAutoScheduled: false,
                anchorDate: today
            ),
            TaskTemplate(
                title: "Water plants & mist leaves",
                notes: "Check soil on the monstera and pothos.",
                emoji: "🪴",
                category: .home,
                recurrence: .weekly,
                durationMinutes: 25,
                weight: .light,
                isAutoScheduled: true,
                anchorDate: today
            ),
            TaskTemplate(
                title: "Fresh sheets & cozy bedroom reset",
                notes: "Put on warm-washed pastel pillowcases.",
                emoji: "🧺",
                category: .home,
                recurrence: .weekly,
                durationMinutes: 45,
                weight: .heavy,
                isAutoScheduled: true,
                anchorDate: today
            ),
            TaskTemplate(
                title: "Organize skincare & vanity drawer",
                notes: "Toss expired bottles and wipe the tray.",
                emoji: "🎀",
                category: .selfCare,
                recurrence: .once,
                durationMinutes: 35,
                weight: .normal,
                isAutoScheduled: true,
                anchorDate: today,
                flexibleWindowDays: 7
            ),
            TaskTemplate(
                title: "Cozy monthly budget & tea check-in",
                notes: "Review subscriptions and savings goals.",
                emoji: "💌",
                category: .lifeAdmin,
                recurrence: .monthly,
                durationMinutes: 40,
                weight: .normal,
                isAutoScheduled: true,
                anchorDate: today
            )
        ]

        for task in starters {
            context.insert(task)
        }
        preferences.hasSeededStarterTasks = true
        try? context.save()
    }

    // MARK: - Internal Helpers

    private static func markMissedOccurrence(
        _ occurrence: TaskOccurrence,
        template: TaskTemplate,
        calendar: Calendar
    ) {
        // A zero-cup day can defer a weekly/monthly occurrence beyond its own period.
        // Attribute the missed commitment to that period's last day, not to the new period.
        let periodSuffix = occurrence.periodKey.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        let startKey = template.recurrence == .monthly ? "\(periodSuffix)-01" : periodSuffix
        if let periodStart = DateHelpers.date(fromDayKey: startKey, calendar: calendar) {
            let periodEnd: Date
            switch template.recurrence {
            case .daily:
                periodEnd = periodStart
            case .weekly:
                periodEnd = DateHelpers.addDays(6, to: periodStart, calendar: calendar)
            case .biweekly:
                periodEnd = DateHelpers.addDays(13, to: periodStart, calendar: calendar)
            case .monthly:
                periodEnd = DateHelpers.monthWindow(containing: periodStart, calendar: calendar).end
            case .customDays:
                periodEnd = DateHelpers.addDays(max(2, template.customIntervalDays) - 1, to: periodStart, calendar: calendar)
            case .once:
                periodEnd = occurrence.scheduledDay(calendar: calendar)
            }
            if occurrence.scheduledDay(calendar: calendar) > periodEnd {
                occurrence.setScheduledDay(periodEnd, calendar: calendar)
            }
        }
        occurrence.setBonusDay(nil, calendar: calendar)
        occurrence.status = .missed
    }

    private static func recordOccurrenceLoad(
        _ occ: TaskOccurrence,
        on day: Date,
        horizonStart: Date,
        horizonEnd: Date,
        usedMinutesByDay: inout [Date: Int],
        accountedLoadByOccurrenceID: inout [UUID: (day: Date, minutes: Int)]
    ) {
        if let previous = accountedLoadByOccurrenceID.removeValue(forKey: occ.id) {
            usedMinutesByDay[previous.day] = max(0, (usedMinutesByDay[previous.day] ?? 0) - previous.minutes)
        }
        guard day >= horizonStart && day <= horizonEnd else { return }
        let load = occ.effectiveLoadMinutes
        usedMinutesByDay[day, default: 0] += load
        accountedLoadByOccurrenceID[occ.id] = (day: day, minutes: load)
    }

    private static func deleteOccurrence(
        _ occ: TaskOccurrence,
        context: ModelContext,
        preferences: CozyPreferences,
        usedMinutesByDay: inout [Date: Int],
        accountedLoadByOccurrenceID: inout [UUID: (day: Date, minutes: Int)]
    ) {
        if let previous = accountedLoadByOccurrenceID.removeValue(forKey: occ.id) {
            usedMinutesByDay[previous.day] = max(0, (usedMinutesByDay[previous.day] ?? 0) - previous.minutes)
        }
        preferences.enqueuePendingDeletions(for: occ)
        context.delete(occ)
    }

    private static func deleteOccurrence(
        _ occ: TaskOccurrence,
        context: ModelContext,
        preferences: CozyPreferences
    ) {
        preferences.enqueuePendingDeletions(for: occ)
        context.delete(occ)
    }

    private static func isOnceTemplateCompleted(
        _ template: TaskTemplate,
        survivingOccurrences: [TaskOccurrence]
    ) -> Bool {
        if survivingOccurrences.contains(where: { $0.template?.id == template.id && $0.status == .completed }) {
            return true
        }
        return template.occurrences.contains(where: { $0.status == .completed })
    }

    static func effectivePeriodDeadline(
        for template: TaskTemplate,
        window: DateHelpers.PeriodWindow,
        calendar: Calendar
    ) -> Date? {
        guard let dl = template.normalizedHardDeadline(calendar: calendar) else { return nil }
        if template.recurrence == .once {
            return dl
        }
        return (dl >= window.start && dl <= window.end) ? dl : nil
    }

    private static func periodKeyMatchesRecurrence(
        _ periodKey: String,
        recurrence: RecurrenceKind,
        intervalDays: Int
    ) -> Bool {
        switch recurrence {
        case .once: return periodKey.hasPrefix("once:")
        case .daily: return periodKey.hasPrefix("daily:")
        case .weekly: return periodKey.hasPrefix("weekly:")
        case .biweekly: return periodKey.hasPrefix("biweekly:")
        case .monthly: return periodKey.hasPrefix("monthly:")
        case .customDays: return periodKey.hasPrefix("custom\(max(2, intervalDays)):")
        }
    }

    private static func scheduleFixedTemplate(
        _ template: TaskTemplate,
        today: Date,
        tomorrow: Date,
        horizonEnd: Date,
        hasTodayCup: Bool,
        todayCupHours: Int?,
        handledMapKeys: Set<String>,
        survivingOccurrences: [TaskOccurrence],
        occurrencesMap: inout [String: TaskOccurrence],
        usedMinutesByDay: inout [Date: Int],
        accountedLoadByOccurrenceID: inout [UUID: (day: Date, minutes: Int)],
        capacityByDay: [Date: Int],
        unbookedByDay: [Date: Int],
        preferences: CozyPreferences,
        context: ModelContext,
        calendar: Calendar
    ) {
        let templateDeadline = template.normalizedHardDeadline(calendar: calendar)
        let anchorDate = template.normalizedAnchorDate(calendar: calendar)

        if template.recurrence == .daily {
            let span = max(0, DateHelpers.daysBetween(today, and: horizonEnd, calendar: calendar))
            for offset in 0...span {
                let day = DateHelpers.addDays(offset, to: today, calendar: calendar)
                let window = DateHelpers.dailyWindow(for: day, calendar: calendar)
                let mapKey = "\(template.id.uuidString)|\(window.key)"
                if handledMapKeys.contains(mapKey) {
                    continue
                }

                // On `today`, if the user has checked in their cup and Today's cup is empty (0h) or doesn't have enough
                // remaining capacity for this non-deadline daily habit, keep Today clear while leaving future predicted days intact!
                if day == today && hasTodayCup {
                    let todayRem = (capacityByDay[today] ?? 0) - (usedMinutesByDay[today] ?? 0)
                    let itemLoad = occurrencesMap[mapKey]?.effectiveLoadMinutes ?? template.effectiveLoadMinutes
                    if todayCupHours == 0 || todayRem < itemLoad {
                        if let existing = occurrencesMap[mapKey], existing.status == .pending && !existing.isManuallyPinned {
                            deleteOccurrence(
                                existing,
                                context: context,
                                preferences: preferences,
                                usedMinutesByDay: &usedMinutesByDay,
                                accountedLoadByOccurrenceID: &accountedLoadByOccurrenceID
                            )
                            occurrencesMap.removeValue(forKey: mapKey)
                        }
                        continue
                    }
                }

                if let existing = occurrencesMap[mapKey] {
                    if existing.status == .pending && !existing.isManuallyPinned {
                        existing.setScheduledDay(day, calendar: calendar)
                        recordOccurrenceLoad(
                            existing,
                            on: day,
                            horizonStart: today,
                            horizonEnd: horizonEnd,
                            usedMinutesByDay: &usedMinutesByDay,
                            accountedLoadByOccurrenceID: &accountedLoadByOccurrenceID
                        )
                    }
                } else {
                    let created = TaskOccurrence(
                        scheduledDate: day,
                        periodKey: window.key,
                        status: .pending,
                        isManuallyPinned: false,
                        template: template,
                        calendar: calendar
                    )
                    context.insert(created)
                    occurrencesMap[mapKey] = created
                    recordOccurrenceLoad(
                        created,
                        on: day,
                        horizonStart: today,
                        horizonEnd: horizonEnd,
                        usedMinutesByDay: &usedMinutesByDay,
                        accountedLoadByOccurrenceID: &accountedLoadByOccurrenceID
                    )
                }
            }
            return
        }

        // Non-daily, pinned (`isAutoScheduled == false`): preserve exact requested dates even beyond the 35-day horizon!
        if template.recurrence == .once {
            let pKey = "once:\(template.id.uuidString)"
            let mapKey = "\(template.id.uuidString)|\(pKey)"
            if handledMapKeys.contains(mapKey) {
                return
            }

            var target = max(today, anchorDate)
            if let dl = templateDeadline {
                target = min(target, max(today, dl))
            }

            let itemLoad = occurrencesMap[mapKey]?.effectiveLoadMinutes ?? template.effectiveLoadMinutes
            if target == today && hasTodayCup {
                let forcedToday = templateDeadline.map { $0 <= today } ?? false
                let todayRem = (capacityByDay[today] ?? 0) - (usedMinutesByDay[today] ?? 0)
                if !forcedToday && (todayCupHours == 0 || todayRem < itemLoad) {
                    target = tomorrow
                }
            }

            if let existing = occurrencesMap[mapKey] {
                if existing.status == .pending && !existing.isManuallyPinned {
                    existing.setScheduledDay(target, calendar: calendar)
                    recordOccurrenceLoad(
                        existing,
                        on: target,
                        horizonStart: today,
                        horizonEnd: horizonEnd,
                        usedMinutesByDay: &usedMinutesByDay,
                        accountedLoadByOccurrenceID: &accountedLoadByOccurrenceID
                    )
                }
            } else {
                let alreadyDone = isOnceTemplateCompleted(template, survivingOccurrences: survivingOccurrences)
                if !alreadyDone {
                    let created = TaskOccurrence(
                        scheduledDate: target,
                        periodKey: pKey,
                        status: .pending,
                        isManuallyPinned: false,
                        template: template,
                        calendar: calendar
                    )
                    context.insert(created)
                    occurrencesMap[mapKey] = created
                    recordOccurrenceLoad(
                        created,
                        on: target,
                        horizonStart: today,
                        horizonEnd: horizonEnd,
                        usedMinutesByDay: &usedMinutesByDay,
                        accountedLoadByOccurrenceID: &accountedLoadByOccurrenceID
                    )
                }
            }
            return
        }

        // Recurring pinned (Weekly, Biweekly, Monthly, Custom)
        var cursor = today
        let anchorWeekday = calendar.component(.weekday, from: anchorDate)
        let anchorDayOfMonth = calendar.component(.day, from: anchorDate)

        while cursor <= horizonEnd {
            let window = DateHelpers.periodWindow(for: template, containing: cursor, calendar: calendar)
            let mapKey = "\(template.id.uuidString)|\(window.key)"
            if !handledMapKeys.contains(mapKey) {
                var pinnedDay: Date = {
                    switch template.recurrence {
                    case .weekly, .biweekly:
                        let span = DateHelpers.daysBetween(window.start, and: window.end, calendar: calendar)
                        for offset in 0...max(0, span) {
                            let d = DateHelpers.addDays(offset, to: window.start, calendar: calendar)
                            if calendar.component(.weekday, from: d) == anchorWeekday {
                                return d
                            }
                        }
                        return window.start
                    case .monthly:
                        let count = calendar.range(of: .day, in: .month, for: window.start)?.count ?? 28
                        let clampedDay = max(1, min(count, anchorDayOfMonth))
                        return DateHelpers.addDays(clampedDay - 1, to: window.start, calendar: calendar)
                    case .customDays, .daily, .once:
                        return window.start
                    }
                }()

                let periodDeadline = effectivePeriodDeadline(for: template, window: window, calendar: calendar)
                if let dl = periodDeadline {
                    pinnedDay = min(pinnedDay, max(today, dl))
                }

                let itemLoad = occurrencesMap[mapKey]?.effectiveLoadMinutes ?? template.effectiveLoadMinutes

                if let existing = occurrencesMap[mapKey] {
                    if existing.status == .pending && !existing.isManuallyPinned {
                        var destination: Date
                        if pinnedDay >= today && pinnedDay <= horizonEnd {
                            destination = pinnedDay
                        } else {
                            destination = chooseFreestDay(
                                from: max(today, window.start),
                                to: min(horizonEnd, window.end),
                                taskDuration: itemLoad,
                                capacityByDay: capacityByDay,
                                unbookedByDay: unbookedByDay,
                                usedMinutesByDay: usedMinutesByDay,
                                calendar: calendar
                            )
                        }
                        if destination == today && hasTodayCup {
                            let forcedToday = periodDeadline.map { $0 <= today } ?? false
                            let todayRem = (capacityByDay[today] ?? 0) - (usedMinutesByDay[today] ?? 0)
                            if !forcedToday && (todayCupHours == 0 || todayRem < itemLoad) {
                                destination = tomorrow
                            }
                        }
                        existing.setScheduledDay(destination, calendar: calendar)
                        recordOccurrenceLoad(
                            existing,
                            on: destination,
                            horizonStart: today,
                            horizonEnd: horizonEnd,
                            usedMinutesByDay: &usedMinutesByDay,
                            accountedLoadByOccurrenceID: &accountedLoadByOccurrenceID
                        )
                    }
                } else if pinnedDay >= today && pinnedDay <= horizonEnd {
                    var destination = pinnedDay
                    if destination == today && hasTodayCup {
                        let forcedToday = periodDeadline.map { $0 <= today } ?? false
                        let todayRem = (capacityByDay[today] ?? 0) - (usedMinutesByDay[today] ?? 0)
                        if !forcedToday && (todayCupHours == 0 || todayRem < itemLoad) {
                            destination = tomorrow
                        }
                    }
                    let created = TaskOccurrence(
                        scheduledDate: destination,
                        periodKey: window.key,
                        status: .pending,
                        isManuallyPinned: false,
                        template: template,
                        calendar: calendar
                    )
                    context.insert(created)
                    occurrencesMap[mapKey] = created
                    recordOccurrenceLoad(
                        created,
                        on: destination,
                        horizonStart: today,
                        horizonEnd: horizonEnd,
                        usedMinutesByDay: &usedMinutesByDay,
                        accountedLoadByOccurrenceID: &accountedLoadByOccurrenceID
                    )
                }
            }

            cursor = DateHelpers.addDays(1, to: window.end, calendar: calendar)
        }
    }
}
