import Foundation
import SwiftData

struct DayCapacitySummary: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let baseBudgetMinutes: Int
    let calendarBusyMinutes: Int
    let effectiveCapacityMinutes: Int
    let unbookedWakingMinutes: Int
    let scheduledMinutes: Int
    let completedMinutes: Int

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
        referenceDate: Date = Date(),
        horizonDays: Int = defaultHorizonDays,
        calendar: Calendar = DateHelpers.calendar
    ) {
        let templates = (try? context.fetch(FetchDescriptor<TaskTemplate>())) ?? []
        let allOccurrences = (try? context.fetch(FetchDescriptor<TaskOccurrence>())) ?? []
        let overrides = (try? context.fetch(FetchDescriptor<DayCapacityOverride>())) ?? []

        let today = DateHelpers.startOfDay(for: referenceDate, calendar: calendar)
        let safeHorizon = max(7, horizonDays)
        let horizonEnd = DateHelpers.addDays(safeHorizon - 1, to: today, calendar: calendar)

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

            // Refresh snapshots on pending items in case user edited title, emoji, or duration
            if occ.status == .pending {
                occ.titleSnapshot = template.title
                occ.emojiSnapshot = template.emoji
                occ.durationMinutesSnapshot = template.durationMinutes

                if !periodKeyMatchesRecurrence(occ.periodKey, recurrence: template.recurrence, intervalDays: template.customIntervalDays) {
                    context.delete(occ)
                    continue
                }
            }

            // Handle unfinished occurrences strictly before today
            if occDay < today && occ.status == .pending {
                switch template.recurrence {
                case .daily:
                    // Never pile missed daily tasks onto today
                    occ.status = .skipped
                    survivingOccurrences.append(occ)
                case .once:
                    // Unfinished once task rolls forward to be placed onto an upcoming free day
                    occ.isManuallyPinned = false
                    survivingOccurrences.append(occ)
                case .weekly, .biweekly, .monthly, .customDays:
                    let currentWindow = DateHelpers.periodWindow(for: template, containing: today, calendar: calendar)
                    if occ.periodKey == currentWindow.key {
                        // Still inside the current week/month/window: redistribute among remaining days
                        occ.isManuallyPinned = false
                        survivingOccurrences.append(occ)
                    } else {
                        // Previous period ended; skip cleanly so recurring tasks never snowball
                        occ.status = .skipped
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
                // Prefer completed over pending if a duplicate ever existed
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

        // Count completed occurrences (including orphaned historical ones) & manually-pinned pending items toward daily load
        for occ in survivingOccurrences {
            if occ.status == .completed {
                let effectiveDay = DateHelpers.startOfDay(for: occ.bonusForDate ?? occ.scheduledDate, calendar: calendar)
                if effectiveDay >= today && effectiveDay <= horizonEnd {
                    usedMinutesByDay[effectiveDay, default: 0] += occ.displayDurationMinutes
                }
            }
        }
        for occ in occurrencesByTemplateAndPeriod.values {
            let d = occ.scheduledDate
            guard d >= today && d <= horizonEnd else { continue }
            if occ.status == .pending && occ.isManuallyPinned {
                usedMinutesByDay[d, default: 0] += occ.displayDurationMinutes
            }
        }

        let activeTemplates = templates.filter { $0.isActive }

        // 3. Phase 1: Fixed commitments (Daily tasks + non-auto-scheduled templates)
        for template in activeTemplates where template.recurrence == .daily || !template.isAutoScheduled {
            scheduleFixedTemplate(
                template,
                today: today,
                horizonEnd: horizonEnd,
                occurrencesMap: &occurrencesByTemplateAndPeriod,
                usedMinutesByDay: &usedMinutesByDay,
                capacityByDay: capacityByDay,
                unbookedByDay: unbookedByDay,
                context: context,
                calendar: calendar
            )
        }

        // 4. Phase 2: Flexible auto-scheduled tasks (Once, Weekly, Biweekly, Monthly, Custom)
        struct FlexibleJob {
            let template: TaskTemplate
            let periodKey: String
            let candidateStart: Date
            let candidateEnd: Date
            let existingOccurrence: TaskOccurrence?

            var windowDaySpan: Int {
                max(1, DateHelpers.daysBetween(candidateStart, and: candidateEnd) + 1)
            }
        }

        let tomorrow = min(horizonEnd, DateHelpers.addDays(1, to: today, calendar: calendar))
        let baseTodayItems = occurrencesByTemplateAndPeriod.values.filter {
            $0.status != .skipped && $0.bonusForDate == nil && DateHelpers.isSameDay($0.scheduledDate, today, calendar: calendar)
        }
        let isTodayAlreadyFinished = !baseTodayItems.isEmpty && baseTodayItems.allSatisfy(\.isCompleted)
        let defaultFlexibleFloor = isTodayAlreadyFinished ? tomorrow : today

        var jobs: [FlexibleJob] = []

        for template in activeTemplates where template.recurrence != .daily && template.isAutoScheduled {
            if template.recurrence == .once {
                let pKey = "once:\(template.id.uuidString)"
                let mapKey = "\(template.id.uuidString)|\(pKey)"
                if let existing = occurrencesByTemplateAndPeriod[mapKey] {
                    if existing.status == .completed || existing.status == .skipped || existing.isManuallyPinned {
                        continue
                    }
                    let isTodayBonus = existing.bonusForDate.map { DateHelpers.isSameDay($0, today, calendar: calendar) } ?? false
                    let start = isTodayBonus ? tomorrow : defaultFlexibleFloor
                    let end = min(horizonEnd, DateHelpers.addDays(max(0, template.flexibleWindowDays - 1), to: start, calendar: calendar))
                    jobs.append(FlexibleJob(
                        template: template,
                        periodKey: pKey,
                        candidateStart: start,
                        candidateEnd: max(start, end),
                        existingOccurrence: existing
                    ))
                } else {
                    // Check if any historical occurrence was already completed for this once template
                    let alreadyDone = survivingOccurrences.contains {
                        $0.template?.id == template.id && $0.status == .completed
                    }
                    if !alreadyDone {
                        let baseAnchor = max(defaultFlexibleFloor, template.anchorDate)
                        let start = baseAnchor <= horizonEnd ? baseAnchor : defaultFlexibleFloor
                        let end = min(horizonEnd, DateHelpers.addDays(max(0, template.flexibleWindowDays - 1), to: start, calendar: calendar))
                        jobs.append(FlexibleJob(
                            template: template,
                            periodKey: pKey,
                            candidateStart: start,
                            candidateEnd: max(start, end),
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
                    let rawStart = max(today, window.start)
                    let cEnd = min(horizonEnd, window.end)

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
                                existingOccurrence: nil
                            ))
                        }
                    }

                    cursor = DateHelpers.addDays(1, to: window.end, calendar: calendar)
                }
            }
        }

        // Sort jobs: tightest candidate window first, then longest task duration first (Best-Fit / LPT load balancing)
        jobs.sort { lhs, rhs in
            if lhs.windowDaySpan != rhs.windowDaySpan {
                return lhs.windowDaySpan < rhs.windowDaySpan
            }
            if lhs.template.durationMinutes != rhs.template.durationMinutes {
                return lhs.template.durationMinutes > rhs.template.durationMinutes
            }
            return lhs.template.createdAt < rhs.template.createdAt
        }

        for job in jobs {
            let chosenDay = chooseFreestDay(
                from: job.candidateStart,
                to: job.candidateEnd,
                taskDuration: job.template.durationMinutes,
                capacityByDay: capacityByDay,
                unbookedByDay: unbookedByDay,
                usedMinutesByDay: usedMinutesByDay,
                calendar: calendar
            )

            if let existing = job.existingOccurrence {
                existing.scheduledDate = chosenDay
                existing.status = .pending
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
            }

            usedMinutesByDay[chosenDay, default: 0] += job.template.durationMinutes
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
        let weekday = calendar.component(.weekday, from: date)
        let baseBudget = overrideMinutes ?? preferences.baseBudgetMinutes(forWeekday: weekday)
        let wakingMinutes = max(60, (preferences.wakingEndHour - preferences.wakingStartHour) * 60)

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
            let totalScheduled = dayItems.reduce(0) { $0 + $1.displayDurationMinutes }
            let completedMins = dayItems.filter { $0.isCompleted }.reduce(0) { $0 + $1.displayDurationMinutes }

            summaries.append(
                DayCapacitySummary(
                    date: day,
                    baseBudgetMinutes: cap.baseBudget,
                    calendarBusyMinutes: busy,
                    effectiveCapacityMinutes: cap.effectiveCapacity,
                    unbookedWakingMinutes: cap.unbookedWaking,
                    scheduledMinutes: totalScheduled,
                    completedMinutes: completedMins
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

        let today = DateHelpers.startOfDay(for: Date())
        let starters: [TaskTemplate] = [
            TaskTemplate(
                title: "Morning stretch & make the bed",
                notes: "Open the blinds, sip water, and take 3 slow breaths.",
                emoji: "🌸",
                category: .selfCare,
                recurrence: .daily,
                durationMinutes: 15,
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
        horizonEnd: Date,
        occurrencesMap: inout [String: TaskOccurrence],
        usedMinutesByDay: inout [Date: Int],
        capacityByDay: [Date: Int],
        unbookedByDay: [Date: Int],
        context: ModelContext,
        calendar: Calendar
    ) {
        if template.recurrence == .daily {
            let span = max(0, DateHelpers.daysBetween(today, and: horizonEnd, calendar: calendar))
            for offset in 0...span {
                let day = DateHelpers.addDays(offset, to: today, calendar: calendar)
                let window = DateHelpers.dailyWindow(for: day, calendar: calendar)
                let mapKey = "\(template.id.uuidString)|\(window.key)"

                if let existing = occurrencesMap[mapKey] {
                    if existing.status == .pending && !existing.isManuallyPinned {
                        existing.scheduledDate = day
                        usedMinutesByDay[day, default: 0] += template.durationMinutes
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
                    usedMinutesByDay[day, default: 0] += template.durationMinutes
                }
            }
            return
        }

        // Non-daily, pinned (`isAutoScheduled == false`)
        if template.recurrence == .once {
            let pKey = "once:\(template.id.uuidString)"
            let mapKey = "\(template.id.uuidString)|\(pKey)"
            let target = min(horizonEnd, max(today, template.anchorDate))

            if let existing = occurrencesMap[mapKey] {
                if existing.status == .pending && !existing.isManuallyPinned {
                    existing.scheduledDate = target
                    usedMinutesByDay[target, default: 0] += template.durationMinutes
                }
            } else {
                let created = TaskOccurrence(
                    scheduledDate: target,
                    periodKey: pKey,
                    status: .pending,
                    isManuallyPinned: false,
                    template: template
                )
                context.insert(created)
                occurrencesMap[mapKey] = created
                usedMinutesByDay[target, default: 0] += template.durationMinutes
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

            let pinnedDay: Date = {
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

            if let existing = occurrencesMap[mapKey] {
                if existing.status == .pending && !existing.isManuallyPinned {
                    let destination: Date
                    if pinnedDay >= today && pinnedDay <= horizonEnd {
                        destination = pinnedDay
                    } else {
                        // Pinned day in this period already passed unfinished -> redistribute to freest remaining day
                        destination = chooseFreestDay(
                            from: max(today, window.start),
                            to: min(horizonEnd, window.end),
                            taskDuration: template.durationMinutes,
                            capacityByDay: capacityByDay,
                            unbookedByDay: unbookedByDay,
                            usedMinutesByDay: usedMinutesByDay,
                            calendar: calendar
                        )
                    }
                    existing.scheduledDate = destination
                    usedMinutesByDay[destination, default: 0] += template.durationMinutes
                }
            } else if pinnedDay >= today && pinnedDay <= horizonEnd {
                let created = TaskOccurrence(
                    scheduledDate: pinnedDay,
                    periodKey: window.key,
                    status: .pending,
                    isManuallyPinned: false,
                    template: template
                )
                context.insert(created)
                occurrencesMap[mapKey] = created
                usedMinutesByDay[pinnedDay, default: 0] += template.durationMinutes
            }

            cursor = DateHelpers.addDays(1, to: window.end, calendar: calendar)
        }
    }
}
