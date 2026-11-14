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
    static let defaultHorizonDays = 35

    // MARK: - Core Rebalance Entry Point

    static func rebalance(
        context: ModelContext,
        preferences: CozyPreferences,
        calendarBusyByDay: [Date: Int] = [:],
        referenceDate: Date = DateHelpers.logicalToday(),
        horizonDays: Int = defaultHorizonDays,
        calendar: Calendar = DateHelpers.calendar
    ) {
        let templates = (try? context.fetch(FetchDescriptor<TaskTemplate>())) ?? []
        let allOccurrences = (try? context.fetch(FetchDescriptor<TaskOccurrence>())) ?? []
        let overrides = (try? context.fetch(FetchDescriptor<DayCapacityOverride>())) ?? []

        let today = DateHelpers.startOfDay(for: referenceDate, calendar: calendar)
        let safeHorizon = max(7, horizonDays)
        let horizonEnd = DateHelpers.addDays(safeHorizon - 1, to: today, calendar: calendar)
        let tomorrow = min(horizonEnd, DateHelpers.addDays(1, to: today, calendar: calendar))
        let hasTodayCup = preferences.hasCupCheckIn(for: today, calendar: calendar)
        let todayCupHours = preferences.cupHours(for: today, calendar: calendar)

        // 1. Build capacity & waking-hour tie-breaker tables for [today ... horizonEnd]
        var overrideMap: [Date: Int] = [:]
        for item in overrides {
            overrideMap[DateHelpers.startOfDay(for: item.date, calendar: calendar)] = item.availableMinutes
        }

        var capacityByDay: [Date: Int] = [:]
        var unbookedByDay: [Date: Int] = [:]
        var usedMinutesByDay: [Date: Int] = [:]

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
        var survivingOccurrences: [TaskOccurrence] = []

        for occ in allOccurrences {
            let occDay = DateHelpers.startOfDay(for: occ.scheduledDate, calendar: calendar)
            occ.scheduledDate = occDay

            if occ.status == .pending,
               let bDate = occ.bonusForDate,
               DateHelpers.startOfDay(for: bDate, calendar: calendar) < today {
                occ.bonusForDate = nil
                occ.bonusSlot = 0
            }

            guard let template = occ.template else {
                if occ.status == .pending {
                    context.delete(occ)
                } else {
                    survivingOccurrences.append(occ)
                }
                continue
            }

            if !template.isActive {
                if occ.status == .pending {
                    context.delete(occ)
                } else {
                    survivingOccurrences.append(occ)
                }
                continue
            }

            let templateDeadline = template.normalizedHardDeadline(calendar: calendar)

            // Refresh snapshots on pending items in case user edited title, emoji, duration, weight, or deadline
            if occ.status == .pending {
                occ.titleSnapshot = template.title
                occ.emojiSnapshot = template.emoji
                occ.durationMinutesSnapshot = template.durationMinutes
                occ.hardDeadlineSnapshot = templateDeadline
                if !occ.hasCustomWeightOverride {
                    occ.weightSnapshotRaw = template.weight.rawValue
                }

                if !periodKeyMatchesRecurrence(occ.periodKey, recurrence: template.recurrence, intervalDays: template.customIntervalDays) {
                    context.delete(occ)
                    continue
                }

                // If Today's cup is 0 (empty) and this task isn't forced today by a hard deadline, unpin so it can move back
                if hasTodayCup && todayCupHours == 0 && occDay == today {
                    let forcedToday = templateDeadline.map { $0 <= today } ?? false
                    if !forcedToday {
                        occ.isManuallyPinned = false
                    }
                }
            }

            // Handle unfinished occurrences from strictly before today (or spilled recurring windows that have now expired)
            if occ.status == .pending {
                switch template.recurrence {
                case .daily:
                    if occDay < today {
                        if let dl = templateDeadline, dl <= today {
                            occ.scheduledDate = today
                            survivingOccurrences.append(occ)
                        } else {
                            // Never pile missed daily tasks onto today
                            occ.status = .skipped
                            survivingOccurrences.append(occ)
                        }
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
                    if occDay < today {
                        if occ.periodKey == currentWindow.key {
                            occ.isManuallyPinned = false
                            survivingOccurrences.append(occ)
                        } else if templateDeadline != nil {
                            occ.isManuallyPinned = false
                            survivingOccurrences.append(occ)
                        } else {
                            occ.status = .skipped
                            survivingOccurrences.append(occ)
                        }
                    } else if occ.periodKey < currentWindow.key && templateDeadline == nil {
                        // Previous period spilled onto this week when yesterday's cup was empty; now that the new period is active, skip old duplicate
                        occ.status = .skipped
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
                    if existing.status == .pending { context.delete(existing) }
                    occurrencesByTemplateAndPeriod[mapKey] = occ
                } else if occ.status == .pending {
                    context.delete(occ)
                }
            } else {
                occurrencesByTemplateAndPeriod[mapKey] = occ
            }
        }

        // 3. Count completed occurrences FIRST using effectiveLoadMinutes (includes post-completion weight adjustments!)
        for occ in survivingOccurrences where occ.status == .completed {
            let effectiveDay = DateHelpers.startOfDay(for: occ.bonusForDate ?? occ.scheduledDate, calendar: calendar)
            if effectiveDay >= today && effectiveDay <= horizonEnd {
                usedMinutesByDay[effectiveDay, default: 0] += occ.effectiveLoadMinutes
            }
        }

        // Count manually-pinned pending items — UNLESS Today's cup cannot fit a non-deadline pinned item on today
        for occ in occurrencesByTemplateAndPeriod.values where occ.status == .pending && occ.isManuallyPinned {
            let d = occ.scheduledDate
            guard d >= today && d <= horizonEnd else { continue }
            if d == today && hasTodayCup {
                let forcedToday = occ.effectiveHardDeadline(calendar: calendar).map { $0 <= today } ?? false
                let todayRem = (capacityByDay[today] ?? 0) - (usedMinutesByDay[today] ?? 0)
                if !forcedToday && (todayCupHours == 0 || todayRem < occ.effectiveLoadMinutes) {
                    // Today's cup is empty or exceeded (e.g. after another task's weight increased) -> unpin & move back!
                    occ.isManuallyPinned = false
                    continue
                }
            }
            usedMinutesByDay[d, default: 0] += occ.effectiveLoadMinutes
        }

        let activeTemplates = templates.filter { $0.isActive }

        // 4. Phase A: Urgent Hard-Deadline Tasks Forced Onto Today (`hardDeadline <= today`)
        // Scheduled FIRST so they always appear on Today even when cup == 0, and claim Today's cup before non-deadline tasks.
        var templatesHandledForTodayDeadline: Set<String> = []
        for template in activeTemplates {
            guard let dl = template.normalizedHardDeadline(calendar: calendar), dl <= today else { continue }
            if template.recurrence == .once {
                let pKey = "once:\(template.id.uuidString)"
                let mapKey = "\(template.id.uuidString)|\(pKey)"
                let alreadyCompleted = survivingOccurrences.contains {
                    $0.template?.id == template.id && $0.status == .completed
                }
                guard !alreadyCompleted else {
                    templatesHandledForTodayDeadline.insert(mapKey)
                    continue
                }
                if let existing = occurrencesByTemplateAndPeriod[mapKey] {
                    if existing.status == .pending {
                        existing.scheduledDate = today
                        existing.bonusForDate = nil
                        existing.bonusSlot = 0
                        usedMinutesByDay[today, default: 0] += existing.effectiveLoadMinutes
                    }
                } else {
                    let created = TaskOccurrence(
                        scheduledDate: today,
                        periodKey: pKey,
                        status: .pending,
                        isManuallyPinned: false,
                        template: template
                    )
                    context.insert(created)
                    occurrencesByTemplateAndPeriod[mapKey] = created
                    usedMinutesByDay[today, default: 0] += created.effectiveLoadMinutes
                }
                templatesHandledForTodayDeadline.insert(mapKey)
            } else {
                let window = DateHelpers.periodWindow(for: template, containing: today, calendar: calendar)
                let mapKey = "\(template.id.uuidString)|\(window.key)"
                if let existing = occurrencesByTemplateAndPeriod[mapKey] {
                    if existing.status == .pending {
                        existing.scheduledDate = today
                        existing.bonusForDate = nil
                        existing.bonusSlot = 0
                        usedMinutesByDay[today, default: 0] += existing.effectiveLoadMinutes
                    }
                } else {
                    let created = TaskOccurrence(
                        scheduledDate: today,
                        periodKey: window.key,
                        status: .pending,
                        isManuallyPinned: false,
                        template: template
                    )
                    context.insert(created)
                    occurrencesByTemplateAndPeriod[mapKey] = created
                    usedMinutesByDay[today, default: 0] += created.effectiveLoadMinutes
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
                occurrencesMap: &occurrencesByTemplateAndPeriod,
                usedMinutesByDay: &usedMinutesByDay,
                capacityByDay: capacityByDay,
                unbookedByDay: unbookedByDay,
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

            var effectiveLoad: Int {
                existingOccurrence?.effectiveLoadMinutes ?? template.effectiveLoadMinutes
            }

            var windowDaySpan: Int {
                max(1, DateHelpers.daysBetween(candidateStart, and: candidateEnd) + 1)
            }
        }

        let baseTodayItems = occurrencesByTemplateAndPeriod.values.filter {
            $0.status != .skipped && $0.bonusForDate == nil && DateHelpers.isSameDay($0.scheduledDate, today, calendar: calendar)
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

                if let existing = occurrencesByTemplateAndPeriod[mapKey] {
                    if existing.status == .completed || existing.status == .skipped || existing.isManuallyPinned {
                        continue
                    }
                    let isTodayBonus = existing.bonusForDate.map { DateHelpers.isSameDay($0, today, calendar: calendar) } ?? false
                    var start = isTodayBonus ? tomorrow : defaultFlexibleFloor
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
                        existingOccurrence: existing
                    ))
                } else {
                    let alreadyDone = survivingOccurrences.contains {
                        $0.template?.id == template.id && $0.status == .completed
                    }
                    if !alreadyDone {
                        let baseAnchor = max(defaultFlexibleFloor, template.anchorDate)
                        var start = baseAnchor <= horizonEnd ? baseAnchor : defaultFlexibleFloor
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
                            existingOccurrence: nil
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

                        let applicableDeadline: Date? = {
                            guard let dl = templateDeadline, dl >= window.start && dl <= window.end else { return nil }
                            return dl
                        }()
                        if let dl = applicableDeadline {
                            cEnd = min(cEnd, max(today, dl))
                        }

                        if rawStart <= cEnd {
                            if let existing = occurrencesByTemplateAndPeriod[mapKey] {
                                if existing.status == .pending && !existing.isManuallyPinned {
                                    let isTodayBonus = existing.bonusForDate.map { DateHelpers.isSameDay($0, today, calendar: calendar) } ?? false
                                    let preferredStart = (isTodayBonus || isTodayAlreadyFinished) ? max(tomorrow, window.start) : rawStart
                                    let finalStart = preferredStart <= cEnd ? preferredStart : rawStart
                                    jobs.append(FlexibleJob(
                                        template: template,
                                        periodKey: window.key,
                                        candidateStart: finalStart,
                                        candidateEnd: cEnd,
                                        hardDeadline: applicableDeadline,
                                        existingOccurrence: existing
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
                                    existingOccurrence: nil
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

            let placedLoad: Int
            if let existing = job.existingOccurrence {
                existing.scheduledDate = chosenDay
                existing.status = .pending
                placedLoad = existing.effectiveLoadMinutes
            } else {
                let created = TaskOccurrence(
                    scheduledDate: chosenDay,
                    periodKey: job.periodKey,
                    status: .pending,
                    isManuallyPinned: false,
                    template: job.template
                )
                context.insert(created)
                let mapKey = "\(job.template.id.uuidString)|\(job.periodKey)"
                occurrencesByTemplateAndPeriod[mapKey] = created
                placedLoad = created.effectiveLoadMinutes
            }

            usedMinutesByDay[chosenDay, default: 0] += placedLoad
        }

        let updatedOccurrences = (try? context.fetch(FetchDescriptor<TaskOccurrence>())) ?? []
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

    // MARK: - Day Summaries for UI Visualization

    static func buildDaySummaries(
        from startDate: Date,
        days: Int,
        occurrences: [TaskOccurrence],
        preferences: CozyPreferences,
        overrides: [DayCapacityOverride],
        calendarBusyByDay: [Date: Int] = [:],
        calendar: Calendar = DateHelpers.calendar
    ) -> [DayCapacitySummary] {
        let first = DateHelpers.startOfDay(for: startDate, calendar: calendar)
        var overrideMap: [Date: Int] = [:]
        for item in overrides {
            overrideMap[DateHelpers.startOfDay(for: item.date, calendar: calendar)] = item.availableMinutes
        }

        var occByDay: [Date: [TaskOccurrence]] = [:]
        for occ in occurrences where occ.status != .skipped {
            let rawDate = occ.isCompleted ? (occ.bonusForDate ?? occ.scheduledDate) : occ.scheduledDate
            let key = DateHelpers.startOfDay(for: rawDate, calendar: calendar)
            occByDay[key, default: []].append(occ)
        }

        var summaries: [DayCapacitySummary] = []
        for offset in 0..<max(1, days) {
            let day = DateHelpers.addDays(offset, to: first, calendar: calendar)
            let busy = calendarBusyByDay[day] ?? 0
            let cap = computeDayCapacity(
                for: day,
                preferences: preferences,
                overrideMinutes: overrideMap[day],
                calendarBusyMinutes: busy,
                calendar: calendar
            )

            let dayItems = occByDay[day] ?? []
            let totalWeighted = dayItems.reduce(0) { $0 + $1.effectiveLoadMinutes }
            let totalClock = dayItems.reduce(0) { $0 + $1.displayDurationMinutes }
            let completedWeighted = dayItems.filter { $0.isCompleted }.reduce(0) { $0 + $1.effectiveLoadMinutes }
            let completedClock = dayItems.filter { $0.isCompleted }.reduce(0) { $0 + $1.displayDurationMinutes }

            summaries.append(
                DayCapacitySummary(
                    date: day,
                    baseBudgetMinutes: cap.baseBudget,
                    calendarBusyMinutes: busy,
                    effectiveCapacityMinutes: cap.effectiveCapacity,
                    unbookedWakingMinutes: cap.unbookedWaking,
                    scheduledMinutes: totalWeighted,
                    scheduledClockMinutes: totalClock,
                    completedMinutes: completedWeighted,
                    completedClockMinutes: completedClock,
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
        occurrencesMap: inout [String: TaskOccurrence],
        usedMinutesByDay: inout [Date: Int],
        capacityByDay: [Date: Int],
        unbookedByDay: [Date: Int],
        context: ModelContext,
        calendar: Calendar
    ) {
        let templateDeadline = template.normalizedHardDeadline(calendar: calendar)

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
                            context.delete(existing)
                            occurrencesMap.removeValue(forKey: mapKey)
                        }
                        continue
                    }
                }

                if let existing = occurrencesMap[mapKey] {
                    if existing.status == .pending && !existing.isManuallyPinned {
                        existing.scheduledDate = day
                        usedMinutesByDay[day, default: 0] += existing.effectiveLoadMinutes
                    }
                } else {
                    let created = TaskOccurrence(
                        scheduledDate: day,
                        periodKey: window.key,
                        status: .pending,
                        isManuallyPinned: false,
                        template: template
                    )
                    context.insert(created)
                    occurrencesMap[mapKey] = created
                    usedMinutesByDay[day, default: 0] += created.effectiveLoadMinutes
                }
            }
            return
        }

        // Non-daily, pinned (`isAutoScheduled == false`)
        if template.recurrence == .once {
            let pKey = "once:\(template.id.uuidString)"
            let mapKey = "\(template.id.uuidString)|\(pKey)"
            if handledMapKeys.contains(mapKey) {
                return
            }

            var target = min(horizonEnd, max(today, template.anchorDate))
            if let dl = templateDeadline {
                target = min(target, max(today, min(horizonEnd, dl)))
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
                    existing.scheduledDate = target
                    usedMinutesByDay[target, default: 0] += existing.effectiveLoadMinutes
                }
            } else {
                let alreadyDone = (try? context.fetch(FetchDescriptor<TaskOccurrence>()))?.contains {
                    $0.template?.id == template.id && $0.status == .completed
                } ?? false
                if !alreadyDone {
                    let created = TaskOccurrence(
                        scheduledDate: target,
                        periodKey: pKey,
                        status: .pending,
                        isManuallyPinned: false,
                        template: template
                    )
                    context.insert(created)
                    occurrencesMap[mapKey] = created
                    usedMinutesByDay[target, default: 0] += created.effectiveLoadMinutes
                }
            }
            return
        }

        // Recurring pinned (Weekly, Biweekly, Monthly, Custom)
        var cursor = today
        let anchorWeekday = calendar.component(.weekday, from: template.anchorDate)
        let anchorDayOfMonth = calendar.component(.day, from: template.anchorDate)

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

                if let dl = templateDeadline, dl >= window.start && dl <= window.end {
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
                            let forcedToday = templateDeadline.map { $0 <= today } ?? false
                            let todayRem = (capacityByDay[today] ?? 0) - (usedMinutesByDay[today] ?? 0)
                            if !forcedToday && (todayCupHours == 0 || todayRem < itemLoad) {
                                destination = tomorrow
                            }
                        }
                        existing.scheduledDate = destination
                        usedMinutesByDay[destination, default: 0] += existing.effectiveLoadMinutes
                    }
                } else if pinnedDay >= today && pinnedDay <= horizonEnd {
                    var destination = pinnedDay
                    if destination == today && hasTodayCup {
                        let forcedToday = templateDeadline.map { $0 <= today } ?? false
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
                        template: template
                    )
                    context.insert(created)
                    occurrencesMap[mapKey] = created
                    usedMinutesByDay[destination, default: 0] += created.effectiveLoadMinutes
                }
            }

            cursor = DateHelpers.addDays(1, to: window.end, calendar: calendar)
        }
    }
}
