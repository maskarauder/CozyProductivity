import EventKit
import SwiftData
import XCTest
@testable import CozyProductivity

@MainActor
final class SmartSchedulerTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var testCalendar: Calendar!

    override func setUpWithError() throws {
        let schema = Schema([
            TaskTemplate.self,
            TaskOccurrence.self,
            CozyPreferences.self,
            DayCapacityOverride.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        cal.firstWeekday = 2 // Monday -> Sunday week windows
        testCalendar = cal
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        testCalendar = nil
    }

    func testFlexibleTasksDistributeToFreestWeekendDays() throws {
        // Monday, Nov 9, 2026
        let monday = makeDate(year: 2026, month: 11, day: 9)
        let saturday = makeDate(year: 2026, month: 11, day: 14)
        let sunday = makeDate(year: 2026, month: 11, day: 15)

        let prefs = CozyPreferences(
            sundayBudgetMinutes: 180,
            mondayBudgetMinutes: 45,
            tuesdayBudgetMinutes: 45,
            wednesdayBudgetMinutes: 45,
            thursdayBudgetMinutes: 45,
            fridayBudgetMinutes: 45,
            saturdayBudgetMinutes: 180
        )
        context.insert(prefs)

        let laundry = TaskTemplate(
            title: "Wash & fold sheets",
            emoji: "🧺",
            recurrence: .weekly,
            durationMinutes: 60,
            isAutoScheduled: true,
            anchorDate: monday
        )
        let mealPrep = TaskTemplate(
            title: "Cozy Sunday meal prep",
            emoji: "🧁",
            recurrence: .weekly,
            durationMinutes: 75,
            isAutoScheduled: true,
            anchorDate: monday
        )
        context.insert(laundry)
        context.insert(mealPrep)

        SmartScheduler.rebalance(
            context: context,
            preferences: prefs,
            referenceDate: monday,
            horizonDays: 14,
            calendar: testCalendar
        )

        let occurrences = try context.fetch(FetchDescriptor<TaskOccurrence>())
        let firstWeekKey = DateHelpers.weekWindow(containing: monday, calendar: testCalendar).key

        let mealPrepFirstWeek = occurrences.first {
            $0.template?.id == mealPrep.id && $0.periodKey == firstWeekKey
        }
        let laundryFirstWeek = occurrences.first {
            $0.template?.id == laundry.id && $0.periodKey == firstWeekKey
        }

        XCTAssertNotNil(mealPrepFirstWeek)
        XCTAssertNotNil(laundryFirstWeek)

        // Longest task (75m) picks Sunday or Saturday (180m free), second task (60m) picks the other 180m day!
        let chosenDays = Set([mealPrepFirstWeek!.scheduledDate, laundryFirstWeek!.scheduledDate])
        XCTAssertEqual(chosenDays, Set([saturday, sunday]))
    }

    func testCalendarBusyTimeShiftsTaskAwayFromBusySaturday() throws {
        let monday = makeDate(year: 2026, month: 11, day: 9)
        let saturday = makeDate(year: 2026, month: 11, day: 14)
        let sunday = makeDate(year: 2026, month: 11, day: 15)

        let prefs = CozyPreferences(
            sundayBudgetMinutes: 150,
            mondayBudgetMinutes: 60,
            tuesdayBudgetMinutes: 60,
            wednesdayBudgetMinutes: 60,
            thursdayBudgetMinutes: 60,
            fridayBudgetMinutes: 60,
            saturdayBudgetMinutes: 180,
            useCalendarSync: true,
            calendarDeductionMode: .subtractFromBudget,
            wakingStartHour: 8,
            wakingEndHour: 21
        )
        context.insert(prefs)

        let closetReset = TaskTemplate(
            title: "Organize sweater shelf",
            recurrence: .once,
            durationMinutes: 60,
            isAutoScheduled: true,
            anchorDate: monday,
            flexibleWindowDays: 7
        )
        context.insert(closetReset)

        // Saturday has 160m of calendar events -> only 20m left; Sunday still has 150m free
        let busyMap: [Date: Int] = [saturday: 160]

        SmartScheduler.rebalance(
            context: context,
            preferences: prefs,
            calendarBusyByDay: busyMap,
            referenceDate: monday,
            horizonDays: 10,
            calendar: testCalendar
        )

        let occ = try context.fetch(FetchDescriptor<TaskOccurrence>()).first
        XCTAssertEqual(occ?.scheduledDate, sunday)
    }

    func testMissedDailySkipsCleanlyWhileUnfinishedOnceTaskRedistributes() throws {
        let monday = makeDate(year: 2026, month: 11, day: 9)
        let tuesday = makeDate(year: 2026, month: 11, day: 10)
        let wednesday = makeDate(year: 2026, month: 11, day: 11)

        let prefs = CozyPreferences(
            sundayBudgetMinutes: 60,
            mondayBudgetMinutes: 90,
            tuesdayBudgetMinutes: 30,
            wednesdayBudgetMinutes: 150,
            thursdayBudgetMinutes: 60,
            fridayBudgetMinutes: 60,
            saturdayBudgetMinutes: 60
        )
        context.insert(prefs)

        let dailyStretch = TaskTemplate(
            title: "Morning stretch",
            recurrence: .daily,
            durationMinutes: 15,
            isAutoScheduled: false,
            anchorDate: monday
        )
        let onceErrand = TaskTemplate(
            title: "Post office package",
            recurrence: .once,
            durationMinutes: 45,
            isAutoScheduled: false,
            anchorDate: monday
        )
        context.insert(dailyStretch)
        context.insert(onceErrand)

        // Day 1 (Monday): schedule both
        SmartScheduler.rebalance(
            context: context,
            preferences: prefs,
            referenceDate: monday,
            horizonDays: 7,
            calendar: testCalendar
        )

        // Convert once task to auto-scheduled or let Tuesday arrive with both Monday tasks left unfinished
        onceErrand.isAutoScheduled = true
        onceErrand.flexibleWindowDays = 5

        // Day 2 (Tuesday): neither Monday task was checked off
        SmartScheduler.rebalance(
            context: context,
            preferences: prefs,
            referenceDate: tuesday,
            horizonDays: 7,
            calendar: testCalendar
        )

        let occurrences = try context.fetch(FetchDescriptor<TaskOccurrence>())

        // 1. Monday's missed daily stretch must be marked .skipped
        let mondayStretch = occurrences.first {
            $0.template?.id == dailyStretch.id && $0.scheduledDate == monday
        }
        XCTAssertEqual(mondayStretch?.status, .skipped)

        // 2. Tuesday should have ONLY ONE pending daily stretch (no pile-up!)
        let tuesdayStretches = occurrences.filter {
            $0.template?.id == dailyStretch.id && $0.scheduledDate == tuesday && $0.status == .pending
        }
        XCTAssertEqual(tuesdayStretches.count, 1)

        // 3. Unfinished Monday once task (45m) redistributes to Wednesday (150m budget vs Tuesday's 30m)
        let errandOcc = occurrences.first { $0.template?.id == onceErrand.id }
        XCTAssertEqual(errandOcc?.status, .pending)
        XCTAssertEqual(errandOcc?.scheduledDate, wednesday)
    }

    func testMergedCalendarIntervalsAndSummaryDigests() throws {
        let base = makeDate(year: 2026, month: 11, day: 13)
        let t1 = base.addingTimeInterval(9 * 3600)   // 09:00
        let t2 = base.addingTimeInterval(10.5 * 3600) // 10:30 (90m)
        let t3 = base.addingTimeInterval(10 * 3600)   // 10:00 (overlaps!)
        let t4 = base.addingTimeInterval(11 * 3600)   // 11:00 -> merged [09:00, 11:00] = 120m

        XCTAssertEqual(CalendarFreeTimeService.mergedDurationMinutes(for: [(t1, t2), (t3, t4)]), 120)

        let task = TaskTemplate(title: "Water monstera", emoji: "🪴", recurrence: .weekly, durationMinutes: 25)
        context.insert(task)

        let occ = TaskOccurrence(
            scheduledDate: base,
            periodKey: "weekly:2026-11-09",
            status: .completed,
            completedAt: base.addingTimeInterval(14 * 3600),
            template: task
        )
        context.insert(occ)

        let daily = SummaryBuilder.dailyDigest(for: base, occurrences: [occ], calendar: testCalendar)
        XCTAssertEqual(daily.completedCount, 1)
        XCTAssertEqual(daily.totalCompletedMinutes, 25)
        XCTAssertTrue(daily.notificationBody.contains("Water monstera"))
    }

    func testBronzeSilverGoldTiersAndStreakPreservation() throws {
        let day1 = makeDate(year: 2026, month: 11, day: 1)
        let day2 = makeDate(year: 2026, month: 11, day: 2)
        let day3 = makeDate(year: 2026, month: 11, day: 3)
        let day4 = makeDate(year: 2026, month: 11, day: 4)
        let day5 = makeDate(year: 2026, month: 11, day: 5)
        let day6 = makeDate(year: 2026, month: 11, day: 6)

        let template = TaskTemplate(title: "Cozy habit", recurrence: .daily, durationMinutes: 15)
        let bonusTemplateA = TaskTemplate(title: "Wash curtains", recurrence: .once, durationMinutes: 30)
        let bonusTemplateB = TaskTemplate(title: "Polish mirror", recurrence: .once, durationMinutes: 20)
        context.insert(template)
        context.insert(bonusTemplateA)
        context.insert(bonusTemplateB)

        // Day 1: Base completed + 2 bonus tasks completed -> GOLD (Streak = 1)
        let d1Base = TaskOccurrence(scheduledDate: day1, periodKey: "daily:2026-11-01", status: .completed, completedAt: day1, template: template)
        let d1Bonus1 = TaskOccurrence(scheduledDate: day5, periodKey: "once:A1", status: .completed, completedAt: day1, bonusForDate: day1, bonusSlot: 1, template: bonusTemplateA)
        let d1Bonus2 = TaskOccurrence(scheduledDate: day6, periodKey: "once:B1", status: .completed, completedAt: day1, bonusForDate: day1, bonusSlot: 2, template: bonusTemplateB)

        // Day 2: Base completed + 1 bonus task completed -> SILVER (Preserves streak = 1 without adding)
        let d2Base = TaskOccurrence(scheduledDate: day2, periodKey: "daily:2026-11-02", status: .completed, completedAt: day2, template: template)
        let d2Bonus1 = TaskOccurrence(scheduledDate: day6, periodKey: "once:A2", status: .completed, completedAt: day2, bonusForDate: day2, bonusSlot: 1, template: bonusTemplateA)

        // Day 3: Base completed + 2 bonus tasks completed -> GOLD (Increments streak = 2)
        let d3Base = TaskOccurrence(scheduledDate: day3, periodKey: "daily:2026-11-03", status: .completed, completedAt: day3, template: template)
        let d3Bonus1 = TaskOccurrence(scheduledDate: day6, periodKey: "once:A3", status: .completed, completedAt: day3, bonusForDate: day3, bonusSlot: 1, template: bonusTemplateA)
        let d3Bonus2 = TaskOccurrence(scheduledDate: day6, periodKey: "once:B3", status: .completed, completedAt: day3, bonusForDate: day3, bonusSlot: 2, template: bonusTemplateB)

        // Day 4: Base completed only (0 bonus) -> BASE / BRONZE
        let d4Base = TaskOccurrence(scheduledDate: day4, periodKey: "daily:2026-11-04", status: .completed, completedAt: day4, template: template)

        // Day 5: Still pending today
        let d5Base = TaskOccurrence(scheduledDate: day5, periodKey: "daily:2026-11-05", status: .pending, template: template)

        let all = [d1Base, d1Bonus1, d1Bonus2, d2Base, d2Bonus1, d3Base, d3Bonus1, d3Bonus2, d4Base, d5Base]
        all.forEach { context.insert($0) }

        // Evaluate at end of Day 1 -> Gold, Current = 1, Longest = 1
        let snapDay1 = StreakAndBonusService.evaluate(occurrences: all, today: day1, calendar: testCalendar)
        XCTAssertEqual(snapDay1.tier(for: day1, calendar: testCalendar), .gold)
        XCTAssertEqual(snapDay1.currentStreak, 1)
        XCTAssertEqual(snapDay1.longestStreak, 1)

        // Evaluate at end of Day 2 -> Silver preserves streak at 1
        let snapDay2 = StreakAndBonusService.evaluate(occurrences: all, today: day2, calendar: testCalendar)
        XCTAssertEqual(snapDay2.tier(for: day2, calendar: testCalendar), .silver)
        XCTAssertEqual(snapDay2.currentStreak, 1)
        XCTAssertEqual(snapDay2.longestStreak, 1)

        // Evaluate at end of Day 3 -> Gold increments streak to 2
        let snapDay3 = StreakAndBonusService.evaluate(occurrences: all, today: day3, calendar: testCalendar)
        XCTAssertEqual(snapDay3.tier(for: day3, calendar: testCalendar), .gold)
        XCTAssertEqual(snapDay3.currentStreak, 2)
        XCTAssertEqual(snapDay3.longestStreak, 2)

        // Evaluate on Day 4 -> Base/Bronze day while Day 4 is still "today" keeps yesterday's streak alive (2),
        // then on Day 5 (after Day 4 ended below Silver), Current Streak resets to 0 while Longest stays 2!
        let snapDay4 = StreakAndBonusService.evaluate(occurrences: all, today: day4, calendar: testCalendar)
        XCTAssertEqual(snapDay4.tier(for: day4, calendar: testCalendar), .base)
        XCTAssertEqual(snapDay4.currentStreak, 2)

        let snapDay5 = StreakAndBonusService.evaluate(occurrences: all, today: day5, calendar: testCalendar)
        XCTAssertEqual(snapDay5.currentStreak, 0)
        XCTAssertEqual(snapDay5.longestStreak, 2)
    }

    func testOverlappingAppleAndGoogleCalendarIntervalsMergeWithoutDoubleCounting() throws {
        let monday = makeDate(year: 2026, month: 11, day: 9)
        let saturday = makeDate(year: 2026, month: 11, day: 14)
        let sunday = makeDate(year: 2026, month: 11, day: 15)

        // Apple Calendar has 10:00–11:30 (90m); Google Calendar has overlapping 11:00–12:30 (90m)
        // Union [10:00–12:30] must be 150m, NOT 180m!
        let appleSource: [Date: [(Date, Date)]] = [
            saturday: [(saturday.addingTimeInterval(10 * 3600), saturday.addingTimeInterval(11.5 * 3600))]
        ]
        let googleSource: [Date: [(Date, Date)]] = [
            saturday: [(saturday.addingTimeInterval(11 * 3600), saturday.addingTimeInterval(12.5 * 3600))]
        ]

        let mergedBusy = CalendarFreeTimeService.mergeBusyIntervalsByDay([appleSource, googleSource])
        XCTAssertEqual(mergedBusy[saturday], 150)

        // Verify Google Calendar busy sync alone (with Apple Calendar sync off) shifts flexible tasks away from busy Saturday
        let prefs = CozyPreferences(
            sundayBudgetMinutes: 140,
            mondayBudgetMinutes: 45,
            tuesdayBudgetMinutes: 45,
            wednesdayBudgetMinutes: 45,
            thursdayBudgetMinutes: 45,
            fridayBudgetMinutes: 45,
            saturdayBudgetMinutes: 180,
            useCalendarSync: false,
            calendarDeductionMode: .subtractFromBudget,
            useGoogleCalendarSync: true
        )
        context.insert(prefs)

        let bakeBread = TaskTemplate(
            title: "Bake sourdough loaf",
            emoji: "🥖",
            recurrence: .once,
            durationMinutes: 60,
            isAutoScheduled: true,
            anchorDate: monday,
            flexibleWindowDays: 7
        )
        context.insert(bakeBread)

        SmartScheduler.rebalance(
            context: context,
            preferences: prefs,
            calendarBusyByDay: mergedBusy,
            referenceDate: monday,
            horizonDays: 10,
            calendar: testCalendar
        )

        let occ = try context.fetch(FetchDescriptor<TaskOccurrence>()).first
        // Saturday has 180 - 150 = 30m left; Sunday has 140m free -> placed on Sunday!
        XCTAssertEqual(occ?.scheduledDate, sunday)
    }

    func testGoogleCalendarEventExtractionExcludesCozyPushedTasksAndFreeEvents() throws {
        let json = """
        {
          "items": [
            {
              "id": "evt_busy_1",
              "status": "confirmed",
              "summary": "Design Review",
              "start": { "dateTime": "2026-11-14T14:00:00Z" },
              "end": { "dateTime": "2026-11-14T15:00:00Z" }
            },
            {
              "id": "evt_cozy_self",
              "status": "confirmed",
              "summary": "🌸 Water plants",
              "start": { "dateTime": "2026-11-14T18:00:00Z" },
              "end": { "dateTime": "2026-11-14T18:30:00Z" },
              "extendedProperties": {
                "private": {
                  "cozyTaskOccurrenceId": "11111111-2222-3333-4444-555555555555",
                  "cozyApp": "CozyProductivity"
                }
              }
            },
            {
              "id": "evt_transparent",
              "status": "confirmed",
              "transparency": "transparent",
              "summary": "FYI Focus Block",
              "start": { "dateTime": "2026-11-14T16:00:00Z" },
              "end": { "dateTime": "2026-11-14T17:00:00Z" }
            },
            {
              "id": "evt_cancelled",
              "status": "cancelled",
              "start": { "dateTime": "2026-11-14T09:00:00Z" },
              "end": { "dateTime": "2026-11-14T10:00:00Z" }
            },
            {
              "id": "evt_all_day",
              "status": "confirmed",
              "start": { "date": "2026-11-14" },
              "end": { "date": "2026-11-15" }
            }
          ]
        }
        """.data(using: .utf8)!

        let intervals = GoogleCalendarService.extractBusyIntervals(from: json)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(CalendarFreeTimeService.mergedDurationMinutes(for: intervals), 60)
    }

    func testGoogleTaskPushSlotAvoidsBusyBlocksAndBuildsCompletionPayload() throws {
        let day = makeDate(year: 2026, month: 11, day: 14)
        // Dinner meeting occupies 18:00–19:00
        let dinnerBusy: [(Date, Date)] = [
            (day.addingTimeInterval(18 * 3600), day.addingTimeInterval(19 * 3600))
        ]

        let slot1 = CalendarFreeTimeService.assignSlotForTask(
            on: day,
            durationMinutes: 30,
            preferredStartHour: 18,
            wakingStartHour: 8,
            wakingEndHour: 21,
            existingBusyIntervals: dinnerBusy,
            calendar: testCalendar
        )
        // Automatically steps past 18:00–19:00 dinner to 19:00–19:30!
        XCTAssertEqual(slot1.0, day.addingTimeInterval(19 * 3600))
        XCTAssertEqual(slot1.1, day.addingTimeInterval(19.5 * 3600))

        let occID = UUID()
        let payload = GoogleCalendarService.buildEventPayload(
            occurrenceID: occID,
            title: "Organize vanity",
            emoji: "🎀",
            notes: "Wipe tray",
            recurrenceLabel: "Once",
            isCompleted: true,
            isBonus: true,
            start: slot1.0,
            end: slot1.1,
            timeZoneIdentifier: "UTC"
        )
        XCTAssertEqual(payload.summary, "✅ 🎀 Organize vanity")
        XCTAssertEqual(payload.extendedProperties.privateProperties?["cozyTaskOccurrenceId"], occID.uuidString)
        XCTAssertEqual(
            GoogleCalendarService.redirectScheme(for: "987654-cozy.apps.googleusercontent.com"),
            "com.googleusercontent.apps.987654-cozy"
        )
    }

    func testTaskWeightsAddRankingMinutesAndPrioritizeHeavyTasks() throws {
        XCTAssertEqual(TaskWeight.light.extraRankingMinutes, 0)
        XCTAssertEqual(TaskWeight.normal.extraRankingMinutes, 30)
        XCTAssertEqual(TaskWeight.heavy.extraRankingMinutes, 60)

        let monday = makeDate(year: 2026, month: 11, day: 9)
        let wednesday = makeDate(year: 2026, month: 11, day: 11)
        let saturday = makeDate(year: 2026, month: 11, day: 14)

        // Budgets: Monday = 65m, Wednesday = 35m, Saturday = 95m, all others = 0m
        let prefs = CozyPreferences(
            sundayBudgetMinutes: 0,
            mondayBudgetMinutes: 65,
            tuesdayBudgetMinutes: 0,
            wednesdayBudgetMinutes: 35,
            thursdayBudgetMinutes: 0,
            fridayBudgetMinutes: 0,
            saturdayBudgetMinutes: 95
        )
        context.insert(prefs)

        // All three have raw clock duration = 30m, but different weights:
        // - Light:  30 +  0 = 30m effective load -> fits Wednesday (35m)
        // - Normal: 30 + 30 = 60m effective load -> fits Monday (65m)
        // - Heavy:  30 + 60 = 90m effective load -> ranked first & placed on Saturday (95m)
        let lightTask = TaskTemplate(
            title: "Quick tidy",
            recurrence: .once,
            durationMinutes: 30,
            weight: .light,
            isAutoScheduled: true,
            anchorDate: monday,
            flexibleWindowDays: 7
        )
        let normalTask = TaskTemplate(
            title: "Fold laundry",
            recurrence: .once,
            durationMinutes: 30,
            weight: .normal,
            isAutoScheduled: true,
            anchorDate: monday,
            flexibleWindowDays: 7
        )
        let heavyTask = TaskTemplate(
            title: "Deep clean kitchen",
            recurrence: .once,
            durationMinutes: 30,
            weight: .heavy,
            isAutoScheduled: true,
            anchorDate: monday,
            flexibleWindowDays: 7
        )
        context.insert(lightTask)
        context.insert(normalTask)
        context.insert(heavyTask)

        XCTAssertEqual(lightTask.effectiveLoadMinutes, 30)
        XCTAssertEqual(normalTask.effectiveLoadMinutes, 60)
        XCTAssertEqual(heavyTask.effectiveLoadMinutes, 90)

        SmartScheduler.rebalance(
            context: context,
            preferences: prefs,
            referenceDate: monday,
            horizonDays: 7,
            calendar: testCalendar
        )

        let occurrences = try context.fetch(FetchDescriptor<TaskOccurrence>())
        let lightOcc = occurrences.first { $0.template?.id == lightTask.id }
        let normalOcc = occurrences.first { $0.template?.id == normalTask.id }
        let heavyOcc = occurrences.first { $0.template?.id == heavyTask.id }

        XCTAssertEqual(heavyOcc?.scheduledDate, saturday)
        XCTAssertEqual(normalOcc?.scheduledDate, monday)
        XCTAssertEqual(lightOcc?.scheduledDate, wednesday)
    }

    func testFourAMLogicalDayBoundaryAndEmptyCupMovesTasksBackEachDay() throws {
        let monday = makeDate(year: 2026, month: 11, day: 9)
        let tuesday = makeDate(year: 2026, month: 11, day: 10)
        let wednesday = makeDate(year: 2026, month: 11, day: 11)

        // 1. Verify 4:00 AM local reset boundary
        let tuesdayAt359AM = tuesday.addingTimeInterval(3 * 3600 + 59 * 60)
        let tuesdayAt400AM = tuesday.addingTimeInterval(4 * 3600)
        XCTAssertEqual(DateHelpers.logicalToday(now: tuesdayAt359AM, calendar: testCalendar), monday)
        XCTAssertEqual(DateHelpers.logicalToday(now: tuesdayAt400AM, calendar: testCalendar), tuesday)

        let prefs = CozyPreferences(
            sundayBudgetMinutes: 120,
            mondayBudgetMinutes: 120,
            tuesdayBudgetMinutes: 120,
            wednesdayBudgetMinutes: 120,
            thursdayBudgetMinutes: 120,
            fridayBudgetMinutes: 120,
            saturdayBudgetMinutes: 120
        )
        context.insert(prefs)

        XCTAssertTrue(prefs.needsCupCheckIn(for: monday, calendar: testCalendar))
        prefs.recordCupCheckIn(hours: 0, for: monday, calendar: testCalendar)
        XCTAssertFalse(prefs.needsCupCheckIn(for: monday, calendar: testCalendar))
        // Still Monday logical day at 3:59 AM Tuesday -> no new prompt yet
        XCTAssertFalse(prefs.needsCupCheckIn(for: DateHelpers.logicalToday(now: tuesdayAt359AM, calendar: testCalendar), calendar: testCalendar))
        // At 4:00 AM Tuesday -> logical day advances and prompts again!
        XCTAssertTrue(prefs.needsCupCheckIn(for: DateHelpers.logicalToday(now: tuesdayAt400AM, calendar: testCalendar), calendar: testCalendar))

        // 2. Verify Cup = 0 moves tasks back each day while future calendar days stay predicted
        let pinnedOnce = TaskTemplate(
            title: "Drop off parcel",
            recurrence: .once,
            durationMinutes: 30,
            weight: .light,
            isAutoScheduled: false,
            anchorDate: monday
        )
        let dailyHabit = TaskTemplate(
            title: "Journal 10m",
            recurrence: .daily,
            durationMinutes: 10,
            weight: .light,
            isAutoScheduled: false,
            anchorDate: monday
        )
        context.insert(pinnedOnce)
        context.insert(dailyHabit)

        // Monday Cup = 0 -> Monday has 0 pending tasks; parcel moves to Tuesday; future daily habits remain predicted!
        SmartScheduler.rebalance(
            context: context,
            preferences: prefs,
            referenceDate: monday,
            horizonDays: 7,
            calendar: testCalendar
        )

        var allOccs = try context.fetch(FetchDescriptor<TaskOccurrence>())
        XCTAssertTrue(allOccs.filter { $0.scheduledDate == monday && $0.status == .pending }.isEmpty)
        XCTAssertEqual(allOccs.first { $0.template?.id == pinnedOnce.id }?.scheduledDate, tuesday)
        XCTAssertFalse(allOccs.filter { $0.template?.id == dailyHabit.id && $0.scheduledDate >= tuesday }.isEmpty)

        // Tuesday arrives and Cup = 0 again -> parcel moves back again from Tuesday to Wednesday!
        prefs.recordCupCheckIn(hours: 0, for: tuesday, calendar: testCalendar)
        SmartScheduler.rebalance(
            context: context,
            preferences: prefs,
            referenceDate: tuesday,
            horizonDays: 7,
            calendar: testCalendar
        )

        allOccs = try context.fetch(FetchDescriptor<TaskOccurrence>())
        XCTAssertTrue(allOccs.filter { $0.scheduledDate == tuesday && $0.status == .pending }.isEmpty)
        XCTAssertEqual(allOccs.first { $0.template?.id == pinnedOnce.id }?.scheduledDate, wednesday)
    }

    func testEditingTaskWeightFromLightToHeavyReadjustsRemainingDaySchedule() throws {
        let monday = makeDate(year: 2026, month: 11, day: 9)
        let tuesday = makeDate(year: 2026, month: 11, day: 10)

        let prefs = CozyPreferences(
            sundayBudgetMinutes: 60,
            mondayBudgetMinutes: 120,
            tuesdayBudgetMinutes: 180,
            wednesdayBudgetMinutes: 60,
            thursdayBudgetMinutes: 60,
            fridayBudgetMinutes: 60,
            saturdayBudgetMinutes: 60
        )
        // User answers "How full is your cup today?" with 2 hours (120m) on Monday
        prefs.recordCupCheckIn(hours: 2, for: monday, calendar: testCalendar)
        context.insert(prefs)

        // Task A: 30m Light (30m load) pinned to Monday
        let taskA = TaskTemplate(
            title: "Clean desk drawer",
            recurrence: .once,
            durationMinutes: 30,
            weight: .light,
            isAutoScheduled: false,
            anchorDate: monday
        )
        // Task B: 45m Normal (45 + 30 = 75m load) pinned to Monday
        // Initial combined load = 30 + 75 = 105m <= 120m cup -> both fit on Monday!
        let taskB = TaskTemplate(
            title: "Sort winter coats",
            recurrence: .once,
            durationMinutes: 45,
            weight: .normal,
            isAutoScheduled: false,
            anchorDate: monday
        )
        context.insert(taskA)
        context.insert(taskB)

        SmartScheduler.rebalance(
            context: context,
            preferences: prefs,
            referenceDate: monday,
            horizonDays: 7,
            calendar: testCalendar
        )

        let initialOccs = try context.fetch(FetchDescriptor<TaskOccurrence>())
        let occA = try XCTUnwrap(initialOccs.first { $0.template?.id == taskA.id })
        let occB = try XCTUnwrap(initialOccs.first { $0.template?.id == taskB.id })
        XCTAssertEqual(occA.scheduledDate, monday)
        XCTAssertEqual(occB.scheduledDate, monday)

        // User edits Task A's weight from Light (+0m) to Heavy (+60m)
        // Task A now consumes 30 + 60 = 90m of Monday's 120m cup, leaving only 30m (< Task B's 75m load)!
        occA.isCompleted = true
        occA.applyWeightAdjustment(.heavy, updateTemplate: true)
        XCTAssertEqual(occA.effectiveLoadMinutes, 90)

        SmartScheduler.rebalance(
            context: context,
            preferences: prefs,
            referenceDate: monday,
            horizonDays: 7,
            calendar: testCalendar
        )

        // Completed Task A stays on Monday, while remaining Task B readjusts to Tuesday!
        XCTAssertEqual(occA.scheduledDate, monday)
        XCTAssertEqual(occB.scheduledDate, tuesday)
    }

    func testHardDeadlineForcesTaskBeforeDeadlineEvenWhenCupIsEmptyOrInsufficient() throws {
        let monday = makeDate(year: 2026, month: 11, day: 9)
        let tuesday = makeDate(year: 2026, month: 11, day: 10)
        let wednesday = makeDate(year: 2026, month: 11, day: 11)
        let saturday = makeDate(year: 2026, month: 11, day: 14)

        let prefs = CozyPreferences(
            sundayBudgetMinutes: 60,
            mondayBudgetMinutes: 60,
            tuesdayBudgetMinutes: 90,
            wednesdayBudgetMinutes: 60,
            thursdayBudgetMinutes: 60,
            fridayBudgetMinutes: 60,
            saturdayBudgetMinutes: 240
        )
        // Monday cup is 0 hours (empty!)
        prefs.recordCupCheckIn(hours: 0, for: monday, calendar: testCalendar)
        context.insert(prefs)

        // 1. Task with Hard Deadline TODAY (Monday): forced onto Monday despite 0h cup!
        let dueTodayTask = TaskTemplate(
            title: "Submit lease renewal",
            recurrence: .once,
            durationMinutes: 60,
            weight: .heavy,
            hasHardDeadline: true,
            hardDeadlineDate: monday,
            isAutoScheduled: true,
            anchorDate: monday,
            flexibleWindowDays: 7
        )

        // 2. Task with Hard Deadline on Wednesday: must appear on or before Wednesday (cannot drift to 240m Saturday!)
        let dueWednesdayTask = TaskTemplate(
            title: "Mail birthday card",
            recurrence: .once,
            durationMinutes: 30,
            weight: .normal,
            hasHardDeadline: true,
            hardDeadlineDate: wednesday,
            isAutoScheduled: true,
            anchorDate: monday,
            flexibleWindowDays: 7
        )

        // 3. Regular flexible task without deadline: moves off empty Monday to freest day (Saturday)
        let flexibleNoDeadline = TaskTemplate(
            title: "Reorganize bookshelf",
            recurrence: .once,
            durationMinutes: 60,
            weight: .normal,
            isAutoScheduled: true,
            anchorDate: monday,
            flexibleWindowDays: 7
        )

        context.insert(dueTodayTask)
        context.insert(dueWednesdayTask)
        context.insert(flexibleNoDeadline)

        SmartScheduler.rebalance(
            context: context,
            preferences: prefs,
            referenceDate: monday,
            horizonDays: 10,
            calendar: testCalendar
        )

        let occs = try context.fetch(FetchDescriptor<TaskOccurrence>())
        let dueTodayOcc = try XCTUnwrap(occs.first { $0.template?.id == dueTodayTask.id })
        let dueWedOcc = try XCTUnwrap(occs.first { $0.template?.id == dueWednesdayTask.id })
        let flexOcc = try XCTUnwrap(occs.first { $0.template?.id == flexibleNoDeadline.id })

        XCTAssertEqual(dueTodayOcc.scheduledDate, monday)
        XCTAssertEqual(dueWedOcc.scheduledDate, tuesday)
        XCTAssertLessThanOrEqual(dueWedOcc.scheduledDate, wednesday)
        XCTAssertEqual(flexOcc.scheduledDate, saturday)
    }

    func testDisablingDailyCupPromptSkipsCheckInAndUsesWeekdayBudget() throws {
        let monday = makeDate(year: 2026, month: 11, day: 9) // Weekday 2 (Monday)
        let prefs = CozyPreferences(
            mondayBudgetMinutes: 150,
            dailyCupPromptEnabled: true
        )
        context.insert(prefs)

        // Initially enabled: requires morning check-in
        XCTAssertTrue(prefs.needsCupCheckIn(for: monday, calendar: testCalendar))

        // Record a 1-hour cup (60m) for Monday
        prefs.recordCupCheckIn(hours: 1, for: monday, calendar: testCalendar)
        XCTAssertFalse(prefs.needsCupCheckIn(for: monday, calendar: testCalendar))
        XCTAssertEqual(
            SmartScheduler.effectiveCapacityMinutes(
                for: monday,
                preferences: prefs,
                overridesByDay: [:],
                calendarBusyMinutesByDay: [:],
                today: monday,
                calendar: testCalendar
            ),
            60
        )

        // Disable the "How full is your cup?" morning dialogue
        prefs.setDailyCupPromptEnabled(false)
        XCTAssertFalse(prefs.dailyCupPromptEnabled)
        XCTAssertFalse(prefs.needsCupCheckIn(for: monday, calendar: testCalendar))
        XCTAssertNil(prefs.cupHours(for: monday, calendar: testCalendar))

        // Capacity automatically falls back to Monday's standard 150m weekday budget
        XCTAssertEqual(
            SmartScheduler.effectiveCapacityMinutes(
                for: monday,
                preferences: prefs,
                overridesByDay: [:],
                calendarBusyMinutesByDay: [:],
                today: monday,
                calendar: testCalendar
            ),
            150
        )
    }

    func testAutoSyncPreferencesAndManagedCalendarEventExtraction() throws {
        let prefs = CozyPreferences()
        XCTAssertTrue(prefs.autoSyncCalendarChanges)
        XCTAssertFalse(prefs.hasAnyCalendarPushEnabled)
        XCTAssertFalse(prefs.shouldAutoSyncCalendarsOnChange)

        // Apple Calendar only
        prefs.pushTasksToAppleCalendar = true
        XCTAssertTrue(prefs.hasAnyCalendarPushEnabled)
        XCTAssertTrue(prefs.shouldAutoSyncCalendarsOnChange)

        // Both Google and Apple Calendars enabled simultaneously
        prefs.pushTasksToGoogleCalendar = true
        XCTAssertTrue(prefs.hasAnyCalendarPushEnabled)
        XCTAssertTrue(prefs.shouldAutoSyncCalendarsOnChange)

        // Turning off auto-sync disables automatic triggers while preserving target calendar selections
        prefs.autoSyncCalendarChanges = false
        XCTAssertFalse(prefs.shouldAutoSyncCalendarsOnChange)
        XCTAssertTrue(prefs.hasAnyCalendarPushEnabled)

        // Verify EventKit URL extraction for Apple Calendar / Google Bridge orphan cleanup
        let occID = UUID()
        let cozyURL = URL(string: "cozyproductivity://occurrence/\(occID.uuidString)")
        let externalURL = URL(string: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(CalendarFreeTimeService.extractCozyOccurrenceID(fromURL: cozyURL), occID)
        XCTAssertNil(CalendarFreeTimeService.extractCozyOccurrenceID(fromURL: externalURL))

        // Verify Google Calendar REST v3 managed-event reconciliation parser
        let googleOccID = UUID()
        let sampleJSON = """
        {
          "items": [
            {
              "id": "gcal_cozy_active",
              "status": "confirmed",
              "summary": "🌸 Organize vanity tray",
              "description": "Scheduled by Cozy Tasks [CozyProductivity]",
              "extendedProperties": {
                "private": {
                  "cozyApp": "CozyProductivity",
                  "cozyTaskOccurrenceId": "\(googleOccID.uuidString)"
                }
              }
            },
            {
              "id": "gcal_cozy_cancelled",
              "status": "cancelled",
              "extendedProperties": {
                "private": {
                  "cozyApp": "CozyProductivity",
                  "cozyTaskOccurrenceId": "\(UUID().uuidString)"
                }
              }
            },
            {
              "id": "gcal_external_meeting",
              "status": "confirmed",
              "summary": "Team Standup"
            }
          ]
        }
        """.data(using: .utf8)!

        let extracted = GoogleCalendarService.extractCozyManagedEvents(from: sampleJSON)
        XCTAssertEqual(extracted.count, 1)
        XCTAssertEqual(extracted.first?.eventID, "gcal_cozy_active")
        XCTAssertEqual(extracted.first?.occurrenceID, googleOccID)
    }

    func testDefaultTaskIsLightThirtyMinutesOnceAndEditable() throws {
        let monday = makeDate(year: 2026, month: 11, day: 9)
        let template = TaskTemplate(title: "Take out the trash", anchorDate: monday)
        XCTAssertEqual(template.recurrence, .once)
        XCTAssertEqual(template.durationMinutes, 30)
        XCTAssertEqual(template.weight, .light)
        XCTAssertEqual(template.effectiveLoadMinutes, 30)

        let occ = TaskOccurrence(
            scheduledDate: monday,
            periodKey: "once|\(template.id.uuidString)",
            template: template
        )
        XCTAssertEqual(occ.displayWeight, .light)
        XCTAssertEqual(occ.displayDurationMinutes, 30)
        XCTAssertEqual(occ.effectiveLoadMinutes, 30)

        // Users can adjust each task to increase weight and/or duration
        template.weight = .heavy
        template.durationMinutes = 60
        occ.weightSnapshotRaw = TaskWeight.heavy.rawValue
        occ.durationMinutesSnapshot = 60
        XCTAssertEqual(template.effectiveLoadMinutes, 120)
        XCTAssertEqual(occ.effectiveLoadMinutes, 120)
    }

    func testSiriTaskPhraseParserExtractsWeightDurationRecurrenceAndCleanTitle() throws {
        // 1. "Hey Siri, add a Cozy task to take out the trash." -> Light, 30m, Once
        let cozyDefault = SiriTaskPhraseParser.parse(
            rawInput: "Hey Siri, add a Cozy task to take out the trash."
        )
        XCTAssertEqual(
            cozyDefault,
            ParsedSiriTask(
                title: "Take out the trash",
                weight: .light,
                durationMinutes: 30,
                recurrence: .once
            )
        )

        // 2. Siri captured trailing slot after matching "Add a Cozy task"
        let trailingSlot = SiriTaskPhraseParser.parse(
            rawInput: "to take out the trash"
        )
        XCTAssertEqual(
            trailingSlot,
            ParsedSiriTask(
                title: "Take out the trash",
                weight: .light,
                durationMinutes: 30,
                recurrence: .once
            )
        )

        // 3. "Add a heavy 1-hour task to take out the trash." -> Heavy, 60m, Once
        let heavyOneHour = SiriTaskPhraseParser.parse(
            rawInput: "Add a heavy 1-hour task to take out the trash."
        )
        XCTAssertEqual(
            heavyOneHour,
            ParsedSiriTask(
                title: "Take out the trash",
                weight: .heavy,
                durationMinutes: 60,
                recurrence: .once
            )
        )

        // 4. With weight, minutes, and weekly recurrence
        let normalWeekly = SiriTaskPhraseParser.parse(
            rawInput: "a normal 45-minute weekly Cozy task to water plants"
        )
        XCTAssertEqual(
            normalWeekly,
            ParsedSiriTask(
                title: "Water plants",
                weight: .normal,
                durationMinutes: 45,
                recurrence: .weekly
            )
        )

        // 5. Spoken "an hour and a half" + "half-hour"
        let ninetyMinHeavy = SiriTaskPhraseParser.parse(
            rawInput: "an hour and a half heavy task to meal prep"
        )
        XCTAssertEqual(
            ninetyMinHeavy,
            ParsedSiriTask(
                title: "Meal prep",
                weight: .heavy,
                durationMinutes: 90,
                recurrence: .once
            )
        )

        let halfHourDaily = SiriTaskPhraseParser.parse(
            rawInput: "half-hour daily task to stretch"
        )
        XCTAssertEqual(
            halfHourDaily,
            ParsedSiriTask(
                title: "Stretch",
                weight: .light,
                durationMinutes: 30,
                recurrence: .daily
            )
        )

        // 6. Normal task titles containing words like "task" or "light" remain untouched
        let normalTaskWord = SiriTaskPhraseParser.parse(rawInput: "Review project task list")
        XCTAssertEqual(normalTaskWord.title, "Review project task list")
        XCTAssertEqual(normalTaskWord.weight, .light)
        XCTAssertEqual(normalTaskWord.durationMinutes, 30)

        let lightBulbs = SiriTaskPhraseParser.parse(rawInput: "Buy light bulbs")
        XCTAssertEqual(lightBulbs.title, "Buy light bulbs")
        XCTAssertEqual(lightBulbs.weight, .light)
    }

    func testOptionalGamificationSettingsAndDefaultGoldDaysWhenBonusDisabled() throws {
        let monday = makeDate(year: 2026, month: 11, day: 9)
        let wednesday = makeDate(year: 2026, month: 11, day: 11)
        let thursday = makeDate(year: 2026, month: 11, day: 12)

        let prefs = CozyPreferences()
        XCTAssertTrue(prefs.streaksEnabled)
        XCTAssertTrue(prefs.optionalBonusTasksEnabled)
        XCTAssertTrue(prefs.dayRanksEnabled)
        XCTAssertTrue(prefs.confettiEnabled)
        XCTAssertFalse(prefs.addFriendlyMode)
        context.insert(prefs)

        let todayTask = TaskTemplate(title: "Take out the trash", recurrence: .daily, anchorDate: monday)
        let futureOne = TaskTemplate(title: "Organize closet", recurrence: .once, anchorDate: wednesday)
        let futureTwo = TaskTemplate(title: "Wash curtains", recurrence: .once, anchorDate: thursday)
        context.insert(todayTask)
        context.insert(futureOne)
        context.insert(futureTwo)

        let occToday = TaskOccurrence(scheduledDate: monday, periodKey: "day|2026-11-09", status: .pending, template: todayTask, calendar: testCalendar)
        let occFuture1 = TaskOccurrence(scheduledDate: wednesday, periodKey: "once|1", status: .pending, template: futureOne, calendar: testCalendar)
        let occFuture2 = TaskOccurrence(scheduledDate: thursday, periodKey: "once|2", status: .pending, template: futureTwo, calendar: testCalendar)
        context.insert(occToday)
        context.insert(occFuture1)
        context.insert(occFuture2)

        let allOccurrences = [occToday, occFuture1, occFuture2]

        // While today's base task is still pending, optional bonus slots stay hidden
        StreakAndBonusService.syncBonusSlots(
            context: context,
            occurrences: allOccurrences,
            preferences: prefs,
            today: monday,
            calendar: testCalendar
        )
        XCTAssertEqual(allOccurrences.filter { $0.bonusDay(calendar: testCalendar) == monday }.count, 0)

        // Once today's base task is completed, 2 optional bonus slots unlock for Monday while Monday's tier is Bronze/Pink (.base)
        occToday.markCompleted(at: monday, calendar: testCalendar)
        XCTAssertTrue(occToday.isCompleted)
        XCTAssertEqual(occToday.completedAt, monday)

        StreakAndBonusService.syncBonusSlots(
            context: context,
            occurrences: allOccurrences,
            preferences: prefs,
            today: monday,
            calendar: testCalendar
        )
        XCTAssertEqual(allOccurrences.filter { $0.bonusDay(calendar: testCalendar) == monday }.count, 2)

        let withBonusEnabled = StreakAndBonusService.evaluate(
            occurrences: allOccurrences,
            optionalBonusTasksEnabled: true,
            today: monday,
            calendar: testCalendar
        )
        XCTAssertEqual(withBonusEnabled.tier(for: monday, calendar: testCalendar), .base)
        XCTAssertEqual(withBonusEnabled.currentStreak, 0)

        // Disabling optional bonus tasks clears pending bonus slots and defaults completed days to Gold!
        prefs.optionalBonusTasksEnabled = false
        StreakAndBonusService.syncBonusSlots(
            context: context,
            occurrences: allOccurrences,
            preferences: prefs,
            today: monday,
            calendar: testCalendar
        )
        XCTAssertEqual(allOccurrences.filter { $0.bonusForDate != nil }.count, 0)

        let withBonusDisabled = StreakAndBonusService.evaluate(
            occurrences: allOccurrences,
            optionalBonusTasksEnabled: false,
            today: monday,
            calendar: testCalendar
        )
        XCTAssertEqual(withBonusDisabled.tier(for: monday, calendar: testCalendar), .gold)
        XCTAssertEqual(withBonusDisabled.totalGoldDays, 1)
        XCTAssertEqual(withBonusDisabled.currentStreak, 1)

        // Verify CelebrationController respects confetti, ranks, streaks, and ADD Friendly options
        let controller = CelebrationController()
        controller.celebrateGoldPerfect(
            streakDays: 3,
            options: .init(
                confettiEnabled: false,
                streaksEnabled: false,
                dayRanksEnabled: true,
                optionalBonusTasksEnabled: false,
                addFriendlyMode: true
            )
        )
        XCTAssertTrue(controller.particles.isEmpty)
        XCTAssertNotNil(controller.perfectOverlay)
        XCTAssertEqual(controller.perfectOverlay?.showStreak, false)
        XCTAssertNil(controller.bannerMessage)
    }

    func testFixedDateOnceTaskBeyondHorizonPreservesExactRequestedDate() throws {
        let nov14 = makeDate(year: 2026, month: 11, day: 14)
        let dec31 = makeDate(year: 2026, month: 12, day: 31)
        let jan10 = makeDate(year: 2027, month: 1, day: 10)

        let prefs = CozyPreferences()
        context.insert(prefs)

        // Pinned (`isAutoScheduled == false`) Once task on Dec 31 must NOT be clamped to Nov 14 + 34d (Dec 18)
        let newYearsEveTask = TaskTemplate(
            title: "Prepare New Year's Eve tray",
            recurrence: .once,
            durationMinutes: 45,
            isAutoScheduled: false,
            anchorDate: dec31,
            calendar: testCalendar
        )

        // Flexible (`isAutoScheduled == true`) Once task anchored on Jan 10 (beyond 35-day horizon) defers occurrence creation until in horizon
        let futureFlexibleTask = TaskTemplate(
            title: "January closet refresh",
            recurrence: .once,
            durationMinutes: 30,
            isAutoScheduled: true,
            anchorDate: jan10,
            flexibleWindowDays: 7,
            calendar: testCalendar
        )

        context.insert(newYearsEveTask)
        context.insert(futureFlexibleTask)

        SmartScheduler.rebalance(
            context: context,
            preferences: prefs,
            referenceDate: nov14,
            horizonDays: 35,
            calendar: testCalendar
        )

        var occs = try context.fetch(FetchDescriptor<TaskOccurrence>())
        let nyeOcc = try XCTUnwrap(occs.first { $0.template?.id == newYearsEveTask.id })
        XCTAssertEqual(nyeOcc.scheduledDay(calendar: testCalendar), dec31)
        XCTAssertNil(occs.first { $0.template?.id == futureFlexibleTask.id })

        // Once time advances to Dec 20 (so Jan 10 is within the 35-day horizon), the deferred flexible task is created >= Jan 10
        let dec20 = makeDate(year: 2026, month: 12, day: 20)
        SmartScheduler.rebalance(
            context: context,
            preferences: prefs,
            referenceDate: dec20,
            horizonDays: 35,
            calendar: testCalendar
        )

        occs = try context.fetch(FetchDescriptor<TaskOccurrence>())
        let janOcc = try XCTUnwrap(occs.first { $0.template?.id == futureFlexibleTask.id })
        XCTAssertGreaterThanOrEqual(janOcc.scheduledDay(calendar: testCalendar), jan10)
    }

    func testMissedDailyTaskWithExpiredHardDeadlineDoesNotAccumulate() throws {
        let monday = makeDate(year: 2026, month: 11, day: 9)
        let tuesday = makeDate(year: 2026, month: 11, day: 10)
        let wednesday = makeDate(year: 2026, month: 11, day: 11)
        let thursday = makeDate(year: 2026, month: 11, day: 12)

        let prefs = CozyPreferences()
        context.insert(prefs)

        let dailyWithDeadline = TaskTemplate(
            title: "Evening vitamins",
            recurrence: .daily,
            durationMinutes: 10,
            weight: .light,
            hasHardDeadline: true,
            hardDeadlineDate: monday,
            isAutoScheduled: false,
            anchorDate: monday,
            calendar: testCalendar
        )
        context.insert(dailyWithDeadline)

        for day in [monday, tuesday, wednesday, thursday] {
            SmartScheduler.rebalance(
                context: context,
                preferences: prefs,
                referenceDate: day,
                horizonDays: 7,
                calendar: testCalendar
            )
        }

        let occs = try context.fetch(FetchDescriptor<TaskOccurrence>())
            .filter { $0.template?.id == dailyWithDeadline.id }

        let pendingOnThursday = occs.filter {
            $0.status == .pending && $0.scheduledDay(calendar: testCalendar) == thursday
        }
        let skippedPastDays = occs.filter {
            $0.status == .skipped && $0.scheduledDay(calendar: testCalendar) < thursday
        }

        XCTAssertEqual(pendingOnThursday.count, 1)
        XCTAssertEqual(skippedPastDays.count, 3)
    }

    func testEditingOrDeletingTemplatePreservesCompletedTaskHistoryAndQueuesRemoteDeletions() throws {
        let monday = makeDate(year: 2026, month: 11, day: 9)
        let tuesday = makeDate(year: 2026, month: 11, day: 10)

        let prefs = CozyPreferences()
        context.insert(prefs)

        let template = TaskTemplate(
            title: "Quick kitchen wipe",
            notes: "Original note",
            emoji: "🧽",
            category: .home,
            recurrence: .daily,
            durationMinutes: 15,
            weight: .light,
            isAutoScheduled: false,
            anchorDate: monday,
            calendar: testCalendar
        )
        context.insert(template)

        let completedMonday = TaskOccurrence(
            scheduledDate: monday,
            periodKey: "daily:2026-11-09",
            status: .pending,
            template: template,
            calendar: testCalendar
        )
        let pendingTuesday = TaskOccurrence(
            scheduledDate: tuesday,
            periodKey: "daily:2026-11-10",
            status: .pending,
            googleCalendarEventId: "c021deadbeef",
            appleCalendarEventIdentifier: "ek-apple-123",
            template: template,
            calendar: testCalendar
        )
        pendingTuesday.googleSyncedDestination = "google-oauth|alice@example.com|primary"
        context.insert(completedMonday)
        context.insert(pendingTuesday)

        // Complete Monday's occurrence while it is 15m Light
        completedMonday.markCompleted(at: monday.addingTimeInterval(18 * 3600), calendar: testCalendar)

        // Later edit the template to 90m Heavy with a new title, emoji, notes, category, and recurrence
        template.title = "Full kitchen deep clean"
        template.emoji = "🫧"
        template.notes = "Updated heavy checklist"
        template.category = .errands
        template.recurrence = .weekly
        template.durationMinutes = 90
        template.weight = .heavy
        pendingTuesday.refreshPendingSnapshotsFromTemplate(periodDeadline: nil, calendar: testCalendar)

        // Pending occurrence reflects updated template, while completed occurrence preserves frozen 15m Light history!
        XCTAssertEqual(pendingTuesday.displayTitle, "Full kitchen deep clean")
        XCTAssertEqual(pendingTuesday.displayDurationMinutes, 90)
        XCTAssertEqual(pendingTuesday.displayWeight, .heavy)

        XCTAssertEqual(completedMonday.displayTitle, "Quick kitchen wipe")
        XCTAssertEqual(completedMonday.displayEmoji, "🧽")
        XCTAssertEqual(completedMonday.displayNotes, "Original note")
        XCTAssertEqual(completedMonday.displayCategory, .home)
        XCTAssertEqual(completedMonday.displayRecurrenceKind, .daily)
        XCTAssertEqual(completedMonday.recurrenceLabel, "Daily")
        XCTAssertEqual(completedMonday.displayDurationMinutes, 15)
        XCTAssertEqual(completedMonday.displayWeight, .light)
        XCTAssertEqual(completedMonday.effectiveLoadMinutes, 15)

        // Now delete the template and pending occurrence (preserving completed history & queueing remote calendar deletions)
        prefs.enqueuePendingDeletions(for: pendingTuesday)
        context.delete(pendingTuesday)
        completedMonday.freezeSnapshotsFromCurrentState(calendar: testCalendar)
        context.delete(template)
        try context.save()

        XCTAssertEqual(completedMonday.displayTitle, "Quick kitchen wipe")
        XCTAssertEqual(completedMonday.displayDurationMinutes, 15)
        XCTAssertEqual(completedMonday.displayWeight, .light)

        let digest = SummaryBuilder.dailyDigest(for: monday, occurrences: [completedMonday], calendar: testCalendar)
        XCTAssertEqual(digest.completedCount, 1)
        XCTAssertEqual(digest.totalCompletedMinutes, 15)

        XCTAssertEqual(prefs.pendingGoogleDeletions.count, 1)
        XCTAssertEqual(prefs.pendingGoogleDeletions.first?.accountKey, "alice@example.com")
        XCTAssertEqual(prefs.pendingGoogleDeletions.first?.calendarID, "primary")
        XCTAssertEqual(prefs.pendingGoogleDeletions.first?.eventID, "c021deadbeef")
        XCTAssertEqual(prefs.pendingEKDeletions.count, 1)
        XCTAssertEqual(prefs.pendingEKDeletions.first?.eventIdentifier, "ek-apple-123")
    }

    func testTimezoneShiftPreservesCivilScheduledDateAndSummaryUses4AMLogicalDay() throws {
        var tokyoCal = Calendar(identifier: .gregorian)
        tokyoCal.timeZone = TimeZone(identifier: "Asia/Tokyo")! // GMT+9
        tokyoCal.firstWeekday = 2

        var laCal = Calendar(identifier: .gregorian)
        laCal.timeZone = TimeZone(identifier: "America/Los_Angeles")! // GMT-8
        laCal.firstWeekday = 2

        var tokyoComps = DateComponents()
        tokyoComps.year = 2026
        tokyoComps.month = 11
        tokyoComps.day = 20
        let nov20Tokyo = tokyoCal.date(from: tokyoComps)!

        let prefs = CozyPreferences()
        context.insert(prefs)

        // User schedules a pinned task for Nov 20 while in Tokyo (2026-11-20 00:00 JST == 2026-11-19 07:00 PST)
        let tripTask = TaskTemplate(
            title: "Call hotel front desk",
            recurrence: .once,
            durationMinutes: 20,
            isAutoScheduled: false,
            anchorDate: nov20Tokyo,
            calendar: tokyoCal
        )
        context.insert(tripTask)

        SmartScheduler.rebalance(
            context: context,
            preferences: prefs,
            referenceDate: nov20Tokyo,
            horizonDays: 7,
            calendar: tokyoCal
        )

        let occ = try XCTUnwrap(context.fetch(FetchDescriptor<TaskOccurrence>()).first)
        XCTAssertEqual(occ.scheduledDayKey, "2026-11-20")

        // User flies to Los Angeles (GMT-8) on Nov 19 local date; civil date "2026-11-20" must stay Nov 20 in LA!
        var laNov19Comps = DateComponents()
        laNov19Comps.year = 2026
        laNov19Comps.month = 11
        laNov19Comps.day = 19
        let nov19LA = laCal.date(from: laNov19Comps)!
        var laNov20Comps = DateComponents()
        laNov20Comps.year = 2026
        laNov20Comps.month = 11
        laNov20Comps.day = 20
        let nov20LA = laCal.date(from: laNov20Comps)!

        SmartScheduler.rebalance(
            context: context,
            preferences: prefs,
            referenceDate: nov19LA,
            horizonDays: 7,
            calendar: laCal
        )

        XCTAssertEqual(occ.scheduledDay(calendar: laCal), nov20LA)
        XCTAssertEqual(DateHelpers.dayKeyString(for: occ.scheduledDay(calendar: laCal), calendar: laCal), "2026-11-20")

        // Verify 01:30 AM completion on Nov 15 attributes to Nov 14's 4:00 AM Cozy logical day in SummaryBuilder
        let nov14 = makeDate(year: 2026, month: 11, day: 14)
        let nov15 = makeDate(year: 2026, month: 11, day: 15)
        let nov15At130AM = nov15.addingTimeInterval(1.5 * 3600)

        let lateNightTemplate = TaskTemplate(
            title: "Herbal tea & journal",
            recurrence: .once,
            durationMinutes: 20,
            isAutoScheduled: false,
            anchorDate: nov14,
            calendar: testCalendar
        )
        context.insert(lateNightTemplate)
        let lateNightOcc = TaskOccurrence(
            scheduledDate: nov14,
            periodKey: "once:late",
            status: .pending,
            template: lateNightTemplate,
            calendar: testCalendar
        )
        context.insert(lateNightOcc)
        lateNightOcc.markCompleted(at: nov15At130AM, calendar: testCalendar)

        let nov14Digest = SummaryBuilder.dailyDigest(for: nov14, occurrences: [lateNightOcc], calendar: testCalendar)
        let nov15Digest = SummaryBuilder.dailyDigest(for: nov15, occurrences: [lateNightOcc], calendar: testCalendar)
        XCTAssertEqual(nov14Digest.completedCount, 1)
        XCTAssertEqual(nov15Digest.completedCount, 0)
    }

    func testGooglePaginationDuplicateReconciliationDestinationSignatureAndChannelIsolation() throws {
        let activeOccID = UUID()
        let orphanOccID = UUID()

        // 1. Multi-page Google Calendar v3 event list decoding
        let page1 = """
        {
          "nextPageToken": "tok_page_2",
          "items": [
            {
              "id": "c021dup1",
              "status": "confirmed",
              "summary": "🌸 Wash sheets",
              "extendedProperties": {
                "private": {
                  "cozyApp": "CozyProductivity",
                  "cozyChannel": "google-oauth",
                  "cozyTaskOccurrenceId": "\(activeOccID.uuidString)"
                }
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let page2 = """
        {
          "items": [
            {
              "id": "c021dup2",
              "status": "confirmed",
              "summary": "🌸 Wash sheets",
              "extendedProperties": {
                "private": {
                  "cozyApp": "CozyProductivity",
                  "cozyChannel": "google-oauth",
                  "cozyTaskOccurrenceId": "\(activeOccID.uuidString)"
                }
              }
            },
            {
              "id": "c021orphan",
              "status": "confirmed",
              "summary": "🌸 Old deleted task",
              "extendedProperties": {
                "private": {
                  "cozyApp": "CozyProductivity",
                  "cozyChannel": "google-oauth",
                  "cozyTaskOccurrenceId": "\(orphanOccID.uuidString)"
                }
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let allItems = try GoogleCalendarService.decodePaginatedEventPages([page1, page2])
        XCTAssertEqual(allItems.count, 3)

        // 2. Duplicate & orphan reconciliation keeps canonical preferred ID and deletes both duplicate & orphan
        let managed = GoogleCalendarService.extractCozyManagedEvents(fromItems: allItems)
        let reconciled = GoogleCalendarService.reconcileRemoteManagedEvents(
            managedEvents: managed,
            activeOccurrenceIDs: [activeOccID],
            preferredEventIDByOccurrence: [activeOccID: "c021dup2"]
        )
        XCTAssertEqual(reconciled.canonicalEventIDByOccurrence[activeOccID], "c021dup2")
        XCTAssertEqual(Set(reconciled.eventIDsToDelete), Set(["c021dup1", "c021orphan"]))

        // 3. Deterministic ID uses strictly valid RFC 2938 base32hex chars (`[0-9a-v]`) and changes across destinations
        let destA = GoogleCalendarService.makeGoogleDestinationKey(accountKey: "user1@gmail.com", calendarID: "primary")
        let destB = GoogleCalendarService.makeGoogleDestinationKey(accountKey: "user2@gmail.com", calendarID: "primary")
        let destC = GoogleCalendarService.makeGoogleDestinationKey(accountKey: "user1@gmail.com", calendarID: "work_cal")

        let detID = GoogleCalendarService.deterministicGoogleEventID(occurrenceID: activeOccID, destinationKey: destA)
        let allowedBase32Hex = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuv")
        XCTAssertTrue(detID.unicodeScalars.allSatisfy { allowedBase32Hex.contains($0) })
        XCTAssertGreaterThanOrEqual(detID.count, 5)
        XCTAssertNotEqual(
            GoogleCalendarService.deterministicGoogleEventID(occurrenceID: activeOccID, destinationKey: destA),
            GoogleCalendarService.deterministicGoogleEventID(occurrenceID: activeOccID, destinationKey: destB)
        )

        let now = makeDate(year: 2026, month: 11, day: 14)
        let samplePayload = GoogleCalendarService.buildEventPayload(
            occurrenceID: activeOccID,
            title: "Water plants",
            emoji: "🪴",
            notes: "",
            recurrenceLabel: "Once",
            isCompleted: false,
            isBonus: false,
            start: now.addingTimeInterval(18 * 3600),
            end: now.addingTimeInterval(18.5 * 3600),
            timeZoneIdentifier: "UTC"
        )
        let sigA = GoogleCalendarService.buildGoogleSyncSignature(destinationKey: destA, payload: samplePayload)
        let sigB = GoogleCalendarService.buildGoogleSyncSignature(destinationKey: destB, payload: samplePayload)
        let sigC = GoogleCalendarService.buildGoogleSyncSignature(destinationKey: destC, payload: samplePayload)
        XCTAssertNotEqual(sigA, sigB)
        XCTAssertNotEqual(sigA, sigC)

        // 4. HTTP DELETE confirmation status validation
        XCTAssertTrue(GoogleCalendarService.isConfirmedDeleteStatus(204))
        XCTAssertTrue(GoogleCalendarService.isConfirmedDeleteStatus(404))
        XCTAssertTrue(GoogleCalendarService.isConfirmedDeleteStatus(410))
        XCTAssertFalse(GoogleCalendarService.isConfirmedDeleteStatus(500))
        XCTAssertFalse(GoogleCalendarService.isConfirmedDeleteStatus(403))

        // 5. Channel isolation prevents Apple/EventKit sync from deleting OAuth-managed Google events on bridged calendars
        let googleOAuthTag = CalendarFreeTimeService.formatCozyMetadataTag(channel: .googleOAuth, occurrenceID: activeOccID)
        XCTAssertTrue(CalendarFreeTimeService.metadataBelongsToChannel(url: nil, notes: googleOAuthTag, targetChannel: .googleOAuth))
        XCTAssertFalse(CalendarFreeTimeService.metadataBelongsToChannel(url: nil, notes: googleOAuthTag, targetChannel: .apple))
        XCTAssertFalse(CalendarFreeTimeService.metadataBelongsToChannel(url: nil, notes: googleOAuthTag, targetChannel: .googleBridge))
    }

    func testConfettiStaggeredParticlesPruneCompletelyAndHistoricalStreakArchiveMatchesFullScan() throws {
        // 1. Staggered Gold confetti particles prune completely to 0 after `latestParticleExpiry`
        let controller = CelebrationController()
        controller.celebrateGoldPerfect(streakDays: 5)
        XCTAssertEqual(controller.particles.count, 240)
        let finalExpiry = try XCTUnwrap(controller.latestParticleExpiry)

        // Pruning after the last staggered particle expires leaves `particles` empty so TimelineView(.animation) unmounts
        controller.pruneExpiredParticles(at: finalExpiry + 0.001)
        XCTAssertTrue(controller.particles.isEmpty)
        XCTAssertNil(controller.latestParticleExpiry)

        // 2. Incremental historical streak archive + operational window matches full-history scan
        let startDay = makeDate(year: 2026, month: 8, day: 1)
        let today = DateHelpers.addDays(95, to: startDay, calendar: testCalendar) // Nov 4, 2026
        let prefs = CozyPreferences(optionalBonusTasksEnabled: false)
        context.insert(prefs)

        let dailyHabit = TaskTemplate(
            title: "Morning tea",
            recurrence: .daily,
            durationMinutes: 10,
            isAutoScheduled: false,
            anchorDate: startDay,
            calendar: testCalendar
        )
        context.insert(dailyHabit)

        var allOccurrences: [TaskOccurrence] = []
        for offset in 0...95 {
            let d = DateHelpers.addDays(offset, to: startDay, calendar: testCalendar)
            let completed = (offset != 20) // Missed day 20 -> 75 consecutive Gold days from offset 21...95!
            let occ = TaskOccurrence(
                scheduledDate: d,
                periodKey: "daily:\(DateHelpers.dayKeyString(for: d, calendar: testCalendar))",
                status: completed ? .completed : .pending,
                completedAt: completed ? d.addingTimeInterval(9 * 3600) : nil,
                template: dailyHabit,
                calendar: testCalendar
            )
            if !completed && d < today {
                occ.status = .skipped
                // Wait: skipped occurrences are excluded; leave an uncompleted non-skipped past task on offset 20 to break streak!
            }
            context.insert(occ)
            allOccurrences.append(occ)
        }
        // Make offset 20 an uncompleted past day (not completed, status pending in past archive) to verify streak reset + 75-day rebuild
        allOccurrences[20].statusRaw = OccurrenceStatus.pending.rawValue

        let fullSnapshot = StreakAndBonusService.evaluate(
            occurrences: allOccurrences,
            optionalBonusTasksEnabled: false,
            historicalArchive: nil,
            today: today,
            calendar: testCalendar
        )

        let archiveCutoff = DateHelpers.addDays(-SmartScheduler.streakArchiveCutoffDays, to: today, calendar: testCalendar)
        StreakAndBonusService.refreshHistoricalArchiveIfNeeded(
            context: context,
            preferences: prefs,
            operationalCutoff: archiveCutoff,
            today: today,
            calendar: testCalendar
        )
        XCTAssertNotNil(prefs.historicalStreakArchive)

        let operationalSlice = allOccurrences.filter { $0.scheduledDay(calendar: testCalendar) >= archiveCutoff }
        XCTAssertLessThan(operationalSlice.count, allOccurrences.count)

        let archivedSnapshot = StreakAndBonusService.evaluate(
            occurrences: operationalSlice,
            persistedLongestStreak: prefs.longestRecordedStreak,
            optionalBonusTasksEnabled: false,
            historicalArchive: prefs.historicalStreakArchive,
            today: today,
            calendar: testCalendar
        )

        XCTAssertEqual(archivedSnapshot.currentStreak, fullSnapshot.currentStreak)
        XCTAssertEqual(archivedSnapshot.currentStreak, 75)
        XCTAssertEqual(archivedSnapshot.longestStreak, fullSnapshot.longestStreak)
        XCTAssertEqual(archivedSnapshot.totalGoldDays, fullSnapshot.totalGoldDays)
    }

    // MARK: - Review Round 2 Regression Suite (Findings 1–7)

    func testGoogleBusyReadFailureDefersSlotWritesWhilePreservingCompletionAndFreshIntervalCache() async throws {
        let today = makeDate(year: 2026, month: 11, day: 14) // Saturday
        let refNow = today.addingTimeInterval(10 * 3600)

        let prefs = CozyPreferences(
            useGoogleCalendarSync: true,
            pushTasksToGoogleCalendar: true,
            autoSyncCalendarChanges: true,
            googleSyncMode: .oauthREST,
            googleClientID: "123456-test.apps.googleusercontent.com",
            googleCalendarID: "primary",
            googleTaskPushStartHour: 18
        )
        context.insert(prefs)

        let syncedTemplate = TaskTemplate(
            title: "Water ferns",
            emoji: "🌿",
            recurrence: .once,
            durationMinutes: 30,
            isAutoScheduled: false,
            anchorDate: today,
            calendar: testCalendar
        )
        let newTemplate = TaskTemplate(
            title: "Tidy desk",
            emoji: "🗂️",
            recurrence: .once,
            durationMinutes: 30,
            isAutoScheduled: false,
            anchorDate: today,
            calendar: testCalendar
        )
        context.insert(syncedTemplate)
        context.insert(newTemplate)

        let existingStart = today.addingTimeInterval(19.5 * 3600) // 19:30 UTC (after an unseen 18:00-19:00 meeting)
        let existingEnd = today.addingTimeInterval(20.0 * 3600)   // 20:00 UTC

        let syncedOcc = TaskOccurrence(
            scheduledDate: today,
            periodKey: "once:\(syncedTemplate.id.uuidString)",
            status: .completed,
            completedAt: refNow,
            template: syncedTemplate,
            calendar: testCalendar
        )
        let destKey = GoogleCalendarService.makeGoogleDestinationKey(accountKey: "alex@gmail.com", calendarID: "primary")
        let syncedRemoteID = GoogleCalendarService.deterministicGoogleEventID(occurrenceID: syncedOcc.id, destinationKey: destKey)
        syncedOcc.googleCalendarEventId = syncedRemoteID
        syncedOcc.googleSyncedDestination = destKey

        let newUnsyncedOcc = TaskOccurrence(
            scheduledDate: today,
            periodKey: "once:\(newTemplate.id.uuidString)",
            status: .pending,
            template: newTemplate,
            calendar: testCalendar
        )
        context.insert(syncedOcc)
        context.insert(newUnsyncedOcc)
        try context.save()

        var failBusyRead = true
        var patchedPayloads: [GoogleUpsertEventPayload] = []
        var createdPayloads: [GoogleUpsertEventPayload] = []
        var remoteCozyEvents: [String: GoogleEventDTO] = [
            syncedRemoteID: GoogleEventDTO(
                id: syncedRemoteID,
                status: "confirmed",
                summary: "🌿 Water ferns",
                description: "Scheduled by Cozy \(CalendarFreeTimeService.formatCozyMetadataTag(channel: .googleOAuth, occurrenceID: syncedOcc.id))",
                transparency: "opaque",
                start: GoogleEventDateTimeDTO(dateTime: GoogleCalendarService.formatRFC3339(existingStart), date: nil, timeZone: "UTC"),
                end: GoogleEventDateTimeDTO(dateTime: GoogleCalendarService.formatRFC3339(existingEnd), date: nil, timeZone: "UTC"),
                extendedProperties: GoogleExtendedPropertiesDTO(privateProperties: [
                    "cozyApp": "CozyProductivity",
                    "cozyChannel": "google-oauth",
                    "cozyTaskOccurrenceId": syncedOcc.id.uuidString
                ])
            )
        ]

        let meetingStart = today.addingTimeInterval(18 * 3600) // 18:00 UTC
        let meetingEnd = today.addingTimeInterval(19 * 3600)   // 19:00 UTC
        let meetingItem = GoogleEventDTO(
            id: "ext-meeting-1",
            status: "confirmed",
            summary: "Team Sync",
            description: "External meeting",
            transparency: "opaque",
            start: GoogleEventDateTimeDTO(dateTime: GoogleCalendarService.formatRFC3339(meetingStart), date: nil, timeZone: "UTC"),
            end: GoogleEventDateTimeDTO(dateTime: GoogleCalendarService.formatRFC3339(meetingEnd), date: nil, timeZone: "UTC"),
            extendedProperties: nil
        )

        let mockBacking = MockEventStoreBacking()
        let ekService = CalendarFreeTimeService(backing: mockBacking)
        let testToken = GoogleOAuthToken(
            accessToken: "mock-access-token",
            refreshToken: "mock-refresh",
            expiresAt: Date().addingTimeInterval(86400),
            accountSummary: "alex@gmail.com",
            accountKey: "alex@gmail.com"
        )

        let googleService = GoogleCalendarService(
            httpLoader: { req in
                let url = try XCTUnwrap(req.url)
                let method = req.httpMethod ?? "GET"
                let query = url.query ?? ""

                if method == "GET" {
                    if query.contains("privateExtendedProperty") {
                        let body = try JSONEncoder().encode(GoogleEventListResponse(items: Array(remoteCozyEvents.values), nextPageToken: nil))
                        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                    }
                    if failBusyRead {
                        return (Data("Service Unavailable".utf8), HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!)
                    }
                    var allItems = Array(remoteCozyEvents.values)
                    allItems.append(meetingItem)
                    let body = try JSONEncoder().encode(GoogleEventListResponse(items: allItems, nextPageToken: nil))
                    return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }

                if method == "PATCH" {
                    let payload = try JSONDecoder().decode(GoogleUpsertEventPayload.self, from: req.httpBody ?? Data())
                    patchedPayloads.append(payload)
                    let eventID = url.lastPathComponent
                    let updated = GoogleEventDTO(
                        id: eventID,
                        status: "confirmed",
                        summary: payload.summary,
                        description: payload.description,
                        transparency: "opaque",
                        start: payload.start,
                        end: payload.end,
                        extendedProperties: payload.extendedProperties
                    )
                    remoteCozyEvents[eventID] = updated
                    let body = try JSONEncoder().encode(updated)
                    return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }

                if method == "POST" {
                    let payload = try JSONDecoder().decode(GoogleUpsertEventPayload.self, from: req.httpBody ?? Data())
                    createdPayloads.append(payload)
                    let createdID = payload.id ?? UUID().uuidString
                    let created = GoogleEventDTO(
                        id: createdID,
                        status: "confirmed",
                        summary: payload.summary,
                        description: payload.description,
                        transparency: "opaque",
                        start: payload.start,
                        end: payload.end,
                        extendedProperties: payload.extendedProperties
                    )
                    remoteCozyEvents[createdID] = created
                    let body = try JSONEncoder().encode(created)
                    return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }

                return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            },
            initialToken: testToken,
            freeTimeService: ekService,
            persistTokensToKeychain: false
        )

        // Part A: Busy read fails (503) with NO cached snapshot -> new slot write is DEFERRED (never placed over 18:00 meeting!),
        //         while completion-only PATCH on `syncedOcc` preserves its exact 19:30-20:00 timestamps!
        let degradedReport = await googleService.pushOccurrenceChangesWithoutRebalance(
            context: context,
            preferences: prefs,
            referenceDate: refNow,
            calendar: testCalendar
        )
        XCTAssertEqual(createdPayloads.count, 0)
        XCTAssertNil(newUnsyncedOcc.googleCalendarEventId)
        XCTAssertEqual(degradedReport.deferredCount, 1)
        XCTAssertEqual(degradedReport.upsertedCount, 1)
        XCTAssertEqual(patchedPayloads.count, 1)
        XCTAssertTrue(patchedPayloads[0].summary.hasPrefix("✅"))
        XCTAssertEqual(
            GoogleCalendarService.parseRFC3339(patchedPayloads[0].start.dateTime ?? ""),
            existingStart
        )
        XCTAssertEqual(
            GoogleCalendarService.parseRFC3339(patchedPayloads[0].end.dateTime ?? ""),
            existingEnd
        )

        // Part B: Busy read succeeds -> caches complete 18:00-19:00 meeting interval -> next sync fails busy read (503)
        //         within freshness window -> uses fresh interval cache so new task avoids 18:00-19:00!
        failBusyRead = false
        let healthyReport = await googleService.syncCalendarsAndRebalance(
            context: context,
            preferences: prefs,
            referenceDate: refNow,
            calendar: testCalendar
        )
        XCTAssertEqual(healthyReport.deferredCount, 0)
        XCTAssertNotNil(newUnsyncedOcc.googleCalendarEventId)
        let firstCreatedStart = try XCTUnwrap(createdPayloads.first?.start.dateTime.flatMap(GoogleCalendarService.parseRFC3339))
        XCTAssertGreaterThanOrEqual(firstCreatedStart, meetingEnd)
        XCTAssertEqual(prefs.cachedGoogleBusySnapshot?.hasCompleteIntervals, true)

        createdPayloads.removeAll()
        failBusyRead = true
        let cachedTaskTemplate = TaskTemplate(
            title: "Journal",
            emoji: "📓",
            recurrence: .once,
            durationMinutes: 30,
            isAutoScheduled: false,
            anchorDate: today,
            calendar: testCalendar
        )
        context.insert(cachedTaskTemplate)
        let cachedOcc = TaskOccurrence(
            scheduledDate: today,
            periodKey: "once:\(cachedTaskTemplate.id.uuidString)",
            status: .pending,
            template: cachedTaskTemplate,
            calendar: testCalendar
        )
        context.insert(cachedOcc)
        try context.save()

        let freshFallbackReport = await googleService.syncCalendarsAndRebalance(
            context: context,
            preferences: prefs,
            referenceDate: refNow.addingTimeInterval(300), // 5 minutes later (fresh)
            calendar: testCalendar
        )
        XCTAssertTrue(freshFallbackReport.usedCachedBusySnapshot)
        XCTAssertEqual(freshFallbackReport.deferredCount, 0)
        XCTAssertEqual(createdPayloads.count, 1)
        let cachedFallbackStart = try XCTUnwrap(createdPayloads[0].start.dateTime.flatMap(GoogleCalendarService.parseRFC3339))
        XCTAssertGreaterThanOrEqual(cachedFallbackStart, meetingEnd)

        // Part C: Once snapshot expires past TTL, failed busy read refuses stale intervals and defers new slot writes
        createdPayloads.removeAll()
        let staleTaskTemplate = TaskTemplate(
            title: "Read chapter",
            emoji: "📖",
            recurrence: .once,
            durationMinutes: 30,
            isAutoScheduled: false,
            anchorDate: today,
            calendar: testCalendar
        )
        context.insert(staleTaskTemplate)
        let staleOcc = TaskOccurrence(
            scheduledDate: today,
            periodKey: "once:\(staleTaskTemplate.id.uuidString)",
            status: .pending,
            template: staleTaskTemplate,
            calendar: testCalendar
        )
        context.insert(staleOcc)
        try context.save()

        let expiredReport = await googleService.syncCalendarsAndRebalance(
            context: context,
            preferences: prefs,
            referenceDate: refNow.addingTimeInterval(8 * 3600), // 8 hours later (> 6h TTL)
            calendar: testCalendar
        )
        XCTAssertFalse(expiredReport.usedCachedBusySnapshot)
        XCTAssertGreaterThanOrEqual(expiredReport.deferredCount, 1)
        XCTAssertNil(staleOcc.googleCalendarEventId)
        XCTAssertEqual(createdPayloads.count, 0)
    }

    func testConcurrentDeletionQueuesPreserveItemsAddedDuringAsyncWaitAndEKMigration() async throws {
        let today = makeDate(year: 2026, month: 11, day: 14)
        let prefs = CozyPreferences(
            pushTasksToGoogleCalendar: true,
            googleSyncMode: .oauthREST,
            googleClientID: "123456-test.apps.googleusercontent.com",
            googleCalendarID: "primary"
        )
        context.insert(prefs)

        // 1. Google OAuth queue: item A is awaiting network DELETE while item B is appended mid-flight -> B MUST survive!
        let itemA = CozyPreferences.PendingGoogleEventDeletion(
            accountKey: "alex@gmail.com",
            calendarID: "primary",
            eventID: "evt-delete-a"
        )
        let itemB = CozyPreferences.PendingGoogleEventDeletion(
            accountKey: "alex@gmail.com",
            calendarID: "primary",
            eventID: "evt-delete-b"
        )
        prefs.enqueueGoogleDeletion(itemA)

        var deleteEnteredContinuation: CheckedContinuation<Void, Never>?
        var releaseDeleteAContinuation: CheckedContinuation<Void, Never>?

        let testToken = GoogleOAuthToken(
            accessToken: "mock-token",
            refreshToken: "mock-refresh",
            expiresAt: Date().addingTimeInterval(86400),
            accountSummary: "alex@gmail.com",
            accountKey: "alex@gmail.com"
        )
        let googleService = GoogleCalendarService(
            httpLoader: { req in
                let url = try XCTUnwrap(req.url)
                let method = req.httpMethod ?? "GET"
                if method == "DELETE" && url.path.hasSuffix("/evt-delete-a") {
                    deleteEnteredContinuation?.resume()
                    deleteEnteredContinuation = nil
                    await withCheckedContinuation { cont in
                        releaseDeleteAContinuation = cont
                    }
                    return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!)
                }
                let emptyList = try JSONEncoder().encode(GoogleEventListResponse(items: [], nextPageToken: nil))
                return (emptyList, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            initialToken: testToken,
            freeTimeService: CalendarFreeTimeService(backing: MockEventStoreBacking()),
            persistTokensToKeychain: false
        )

        let inFlightTask = Task { @MainActor in
            try await googleService.pushAndMergeOccurrencesToGoogleAPI(
                occurrences: [],
                busyIntervalsByDay: [:],
                preferences: prefs,
                today: today,
                calendar: testCalendar
            )
        }

        await withCheckedContinuation { cont in
            deleteEnteredContinuation = cont
        }

        // Enqueue deletion B while deletion A is suspended awaiting network completion!
        prefs.enqueueGoogleDeletion(itemB)
        XCTAssertEqual(prefs.pendingGoogleDeletions, [itemA, itemB])

        releaseDeleteAContinuation?.resume()
        let outcome = try await inFlightTask.value

        XCTAssertEqual(outcome.removed, 1)
        XCTAssertEqual(prefs.pendingGoogleDeletions, [itemB])

        // 2. EventKit queue: queued item 1 succeeds, while a destination migration failure enqueues item 2 during the same pass!
        let mockBacking = MockEventStoreBacking()
        mockBacking.calendarsList = [
            BackingCalendarInfo(
                calendarIdentifier: "cal-old",
                title: "Old Personal",
                sourceTitle: "iCloud",
                allowsContentModifications: true,
                isDefaultForNewEvents: false
            ),
            BackingCalendarInfo(
                calendarIdentifier: "cal-new",
                title: "New Cozy",
                sourceTitle: "iCloud",
                allowsContentModifications: true,
                isDefaultForNewEvents: true
            )
        ]
        mockBacking.seedCommittedEvent(
            BackingEventRecord(
                eventIdentifier: "ek-queued-ok",
                calendarIdentifier: "cal-old",
                title: "Old Task",
                startDate: today.addingTimeInterval(9 * 3600),
                endDate: today.addingTimeInterval(9.5 * 3600)
            )
        )
        mockBacking.seedCommittedEvent(
            BackingEventRecord(
                eventIdentifier: "ek-migrate-fail",
                calendarIdentifier: "cal-old",
                title: "Migrating Task",
                startDate: today.addingTimeInterval(10 * 3600),
                endDate: today.addingTimeInterval(10.5 * 3600)
            )
        )
        mockBacking.failingRemoveIDs = ["ek-migrate-fail"]

        prefs.enqueueEKDeletion(
            .init(channelRaw: CozySyncChannel.apple.rawValue, eventIdentifier: "ek-queued-ok")
        )
        prefs.appleTargetCalendarIdentifier = "cal-new"

        let template = TaskTemplate(
            title: "Stretch",
            recurrence: .once,
            durationMinutes: 30,
            isAutoScheduled: false,
            anchorDate: today,
            calendar: testCalendar
        )
        context.insert(template)
        let migratingOcc = TaskOccurrence(
            scheduledDate: today,
            periodKey: "once:\(template.id.uuidString)",
            status: .pending,
            template: template,
            calendar: testCalendar
        )
        migratingOcc.appleCalendarEventIdentifier = "ek-migrate-fail"
        migratingOcc.appleSyncedDestination = "apple|cal-old"
        context.insert(migratingOcc)

        let ekService = CalendarFreeTimeService(backing: mockBacking)
        let ekOutcome = ekService.syncOccurrencesToAppleCalendar(
            occurrences: [migratingOcc],
            busyIntervalsByDay: [:],
            preferences: prefs,
            today: today,
            calendar: testCalendar
        )
        XCTAssertEqual(ekOutcome.upserted, 1)
        XCTAssertEqual(ekOutcome.removed, 1)
        XCTAssertGreaterThanOrEqual(ekOutcome.failed, 1)
        XCTAssertEqual(prefs.pendingEKDeletions.map(\.eventIdentifier), ["ek-migrate-fail"])
    }

    func testEventKitFailedRemovalRetainsTrackingAndFailedCommitLeavesMetadataUntouched() throws {
        let today = makeDate(year: 2026, month: 11, day: 14)
        let prefs = CozyPreferences(
            pushTasksToAppleCalendar: true,
            appleTargetCalendarIdentifier: "cal-apple"
        )
        context.insert(prefs)

        let mockBacking = MockEventStoreBacking()
        mockBacking.calendarsList = [
            BackingCalendarInfo(
                calendarIdentifier: "cal-apple",
                title: "Home",
                sourceTitle: "iCloud",
                allowsContentModifications: true,
                isDefaultForNewEvents: true
            )
        ]
        mockBacking.seedCommittedEvent(
            BackingEventRecord(
                eventIdentifier: "ek-skip-fail",
                calendarIdentifier: "cal-apple",
                title: "Skipped Task",
                startDate: today.addingTimeInterval(18 * 3600),
                endDate: today.addingTimeInterval(18.5 * 3600),
                notes: CalendarFreeTimeService.formatCozyMetadataTag(channel: .apple, occurrenceID: UUID())
            )
        )
        mockBacking.failingRemoveIDs = ["ek-skip-fail"]

        let t1 = TaskTemplate(title: "Skip me", recurrence: .once, durationMinutes: 30, isAutoScheduled: false, anchorDate: today, calendar: testCalendar)
        let t2 = TaskTemplate(title: "Keep me", recurrence: .once, durationMinutes: 30, isAutoScheduled: false, anchorDate: today, calendar: testCalendar)
        context.insert(t1)
        context.insert(t2)

        let skippedOcc = TaskOccurrence(
            scheduledDate: today,
            periodKey: "once:\(t1.id.uuidString)",
            status: .skipped,
            template: t1,
            calendar: testCalendar
        )
        skippedOcc.appleCalendarEventIdentifier = "ek-skip-fail"
        skippedOcc.appleSyncedDestination = "apple|cal-apple"

        let activeOcc = TaskOccurrence(
            scheduledDate: today,
            periodKey: "once:\(t2.id.uuidString)",
            status: .pending,
            template: t2,
            calendar: testCalendar
        )
        context.insert(skippedOcc)
        context.insert(activeOcc)

        let ekService = CalendarFreeTimeService(backing: mockBacking)

        // 1. Removal of `skippedOcc` fails while `activeOcc` commits: `skippedOcc` MUST retain its event identifier & enqueue retry!
        let partialOutcome = ekService.syncOccurrencesToAppleCalendar(
            occurrences: [skippedOcc, activeOcc],
            busyIntervalsByDay: [:],
            preferences: prefs,
            today: today,
            calendar: testCalendar
        )
        XCTAssertEqual(partialOutcome.upserted, 1)
        XCTAssertGreaterThanOrEqual(partialOutcome.failed, 1)
        XCTAssertNotNil(activeOcc.appleCalendarEventIdentifier)
        XCTAssertEqual(skippedOcc.appleCalendarEventIdentifier, "ek-skip-fail")
        XCTAssertTrue(prefs.pendingEKDeletions.contains(where: { $0.eventIdentifier == "ek-skip-fail" }))

        // 2. When `commit()` itself fails, staged local metadata MUST NOT be applied and backing store is reset!
        let t3 = TaskTemplate(title: "Uncommitted task", recurrence: .once, durationMinutes: 30, isAutoScheduled: false, anchorDate: today, calendar: testCalendar)
        context.insert(t3)
        let uncommittedOcc = TaskOccurrence(
            scheduledDate: today,
            periodKey: "once:\(t3.id.uuidString)",
            status: .pending,
            template: t3,
            calendar: testCalendar
        )
        context.insert(uncommittedOcc)

        mockBacking.shouldFailCommit = true
        let failedCommitOutcome = ekService.syncOccurrencesToAppleCalendar(
            occurrences: [uncommittedOcc],
            busyIntervalsByDay: [:],
            preferences: prefs,
            today: today,
            calendar: testCalendar
        )
        XCTAssertEqual(failedCommitOutcome.upserted, 0)
        XCTAssertGreaterThanOrEqual(failedCommitOutcome.failed, 1)
        XCTAssertNotNil(failedCommitOutcome.errorMessage)
        XCTAssertNil(uncommittedOcc.appleCalendarEventIdentifier)
        XCTAssertNil(uncommittedOcc.lastAppleCalendarSyncSignature)
        XCTAssertEqual(mockBacking.resetCount, 1)
    }

    func testPersistentStoreUpgradeMigratesLegacySnapshotsAndCivilDayKeysWithoutMislabelingHistory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CozyMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let storeURL = tempDir.appendingPathComponent("LegacyUpgrade.store")
        let schema = Schema([
            TaskTemplate.self,
            TaskOccurrence.self,
            CozyPreferences.self,
            DayCapacityOverride.self
        ])

        var laCalendar = Calendar(identifier: .gregorian)
        laCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        laCalendar.firstWeekday = 2

        // 2026-06-10 23:00 PDT == 2026-06-11 06:00 UTC (crosses UTC midnight!)
        var pdtLateComps = DateComponents()
        pdtLateComps.year = 2026
        pdtLateComps.month = 6
        pdtLateComps.day = 10
        pdtLateComps.hour = 23
        pdtLateComps.minute = 0
        let lateEveningPDT = laCalendar.date(from: pdtLateComps)!

        let legacyWeeklyOccID: UUID
        let orphanCustomOccID: UUID

        // Phase 1: Write simulated pre-upgrade rows into an on-disk SQLite SwiftData container
        do {
            let diskConfig = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
            let container1 = try ModelContainer(for: schema, configurations: [diskConfig])
            let ctx1 = container1.mainContext

            let prefs = CozyPreferences()
            prefs.appliedDataMigrationVersion = 0
            ctx1.insert(prefs)

            let kitchenTemplate = TaskTemplate(
                title: "Clean kitchen",
                emoji: "🧽",
                category: .home,
                recurrence: .weekly,
                durationMinutes: 15,
                weight: .normal,
                isAutoScheduled: true,
                anchorDate: lateEveningPDT,
                calendar: laCalendar
            )
            ctx1.insert(kitchenTemplate)

            let legacyWeeklyOcc = TaskOccurrence(
                scheduledDate: lateEveningPDT,
                periodKey: "weekly:2026-06-08",
                status: .completed,
                completedAt: lateEveningPDT,
                template: kitchenTemplate,
                calendar: laCalendar
            )
            // Simulate an upgraded SQLite row from 8dde195 where snapshotSchemaVersion == 0,
            // scheduledDate was stored as 23:00 PDT (06:00 UTC next day!) with empty scheduledDayKey,
            // and non-empty property defaults ("once"/"Once"/"selfCare") populated SQLite!
            legacyWeeklyOcc.scheduledDate = lateEveningPDT
            legacyWeeklyOcc.scheduledDayKey = ""
            legacyWeeklyOcc.scheduledTimezoneID = ""
            legacyWeeklyOcc.snapshotSchemaVersion = 0
            legacyWeeklyOcc.recurrenceKindSnapshotRaw = "once"
            legacyWeeklyOcc.recurrenceLabelSnapshot = "Once"
            legacyWeeklyOcc.categorySnapshotRaw = "selfCare"
            ctx1.insert(legacyWeeklyOcc)
            legacyWeeklyOccID = legacyWeeklyOcc.id

            let orchidTemplate = TaskTemplate(
                title: "Deep water orchids",
                emoji: "🌺",
                category: .home,
                recurrence: .customDays,
                durationMinutes: 20,
                customIntervalDays: 5,
                isAutoScheduled: true,
                anchorDate: lateEveningPDT,
                calendar: laCalendar
            )
            ctx1.insert(orchidTemplate)

            let orphanCustomOcc = TaskOccurrence(
                scheduledDate: lateEveningPDT,
                periodKey: "custom5:4021",
                status: .completed,
                completedAt: lateEveningPDT,
                template: orchidTemplate,
                calendar: laCalendar
            )
            orphanCustomOcc.scheduledDate = lateEveningPDT
            orphanCustomOcc.scheduledDayKey = ""
            orphanCustomOcc.scheduledTimezoneID = ""
            orphanCustomOcc.snapshotSchemaVersion = 0
            orphanCustomOcc.recurrenceKindSnapshotRaw = "once"
            orphanCustomOcc.recurrenceLabelSnapshot = "Once"
            orphanCustomOcc.categorySnapshotRaw = ""
            ctx1.insert(orphanCustomOcc)
            orphanCustomOccID = orphanCustomOcc.id

            // Delete `orchidTemplate` before upgrade so `orphanCustomOcc.template` is nil in SQLite
            ctx1.delete(orchidTemplate)

            try ctx1.save()
        }

        // Phase 2: Reopen on-disk SQLite store in a fresh ModelContainer, run CozyDataMigrator, then edit & delete template
        let reopenConfig = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        let container2 = try ModelContainer(for: schema, configurations: [reopenConfig])
        let ctx2 = container2.mainContext

        let reopenedPrefs = try XCTUnwrap(try ctx2.fetch(FetchDescriptor<CozyPreferences>()).first)
        XCTAssertEqual(reopenedPrefs.appliedDataMigrationVersion, 0)

        CozyDataMigrator.migrateIfNeeded(
            context: ctx2,
            preferences: reopenedPrefs,
            calendar: laCalendar
        )
        XCTAssertEqual(reopenedPrefs.appliedDataMigrationVersion, CozyDataMigrator.currentVersion)

        // Mutate & delete the template AFTER migration to verify completed history is permanently frozen & accurate
        if let liveTemplate = try ctx2.fetch(FetchDescriptor<TaskTemplate>()).first {
            liveTemplate.title = "Mutated Garage Overhaul"
            liveTemplate.recurrence = .monthly
            liveTemplate.category = .lifeAdmin
            liveTemplate.durationMinutes = 120
            ctx2.delete(liveTemplate)
            try ctx2.save()
        }

        let migratedOccurrences = try ctx2.fetch(FetchDescriptor<TaskOccurrence>())
        let migratedWeekly = try XCTUnwrap(migratedOccurrences.first(where: { $0.id == legacyWeeklyOccID }))
        let migratedOrphan = try XCTUnwrap(migratedOccurrences.first(where: { $0.id == orphanCustomOccID }))

        XCTAssertEqual(migratedWeekly.snapshotSchemaVersion, TaskOccurrence.currentSnapshotSchemaVersion)
        XCTAssertEqual(migratedWeekly.scheduledDayKey, "2026-06-10")
        XCTAssertEqual(
            migratedWeekly.completedLogicalDay(calendar: laCalendar).map { DateHelpers.dayKeyString(for: $0, calendar: laCalendar) },
            "2026-06-10"
        )
        XCTAssertEqual(migratedWeekly.displayTitle, "Clean kitchen")
        XCTAssertEqual(migratedWeekly.displayDurationMinutes, 15)
        XCTAssertEqual(migratedWeekly.displayRecurrenceKind, .weekly)
        XCTAssertEqual(migratedWeekly.recurrenceLabel, "Weekly")
        XCTAssertEqual(migratedWeekly.displayCategory, .home)

        XCTAssertEqual(migratedOrphan.displayRecurrenceKind, .customDays)
        XCTAssertEqual(migratedOrphan.recurrenceLabel, "Every 5d")
        XCTAssertEqual(migratedOrphan.scheduledDayKey, "2026-06-10")
    }

    func testSwitchingGoogleConnectionModesCleansUpPreviousChannelWithoutDuplicateEventSets() async throws {
        let today = makeDate(year: 2026, month: 11, day: 14)
        let prefs = CozyPreferences(
            useGoogleCalendarSync: false,
            pushTasksToGoogleCalendar: true,
            googleSyncMode: .oauthREST,
            googleClientID: "123456-test.apps.googleusercontent.com",
            googleCalendarID: "primary"
        )
        context.insert(prefs)

        let template = TaskTemplate(
            title: "Bake sourdough",
            emoji: "🍞",
            recurrence: .once,
            durationMinutes: 45,
            isAutoScheduled: false,
            anchorDate: today,
            calendar: testCalendar
        )
        context.insert(template)
        let occ = TaskOccurrence(
            scheduledDate: today,
            periodKey: "once:\(template.id.uuidString)",
            status: .pending,
            template: template,
            calendar: testCalendar
        )
        context.insert(occ)
        try context.save()

        let mockBacking = MockEventStoreBacking()
        mockBacking.calendarsList = [
            BackingCalendarInfo(
                calendarIdentifier: "ek-google-cal",
                title: "alex@gmail.com",
                sourceTitle: "Gmail",
                allowsContentModifications: true,
                isDefaultForNewEvents: false
            )
        ]
        let ekService = CalendarFreeTimeService(backing: mockBacking)

        var remoteOAuthEvents: [String: GoogleEventDTO] = [:]
        let testToken = GoogleOAuthToken(
            accessToken: "mock-token",
            refreshToken: "mock-refresh",
            expiresAt: Date().addingTimeInterval(86400),
            accountSummary: "alex@gmail.com",
            accountKey: "alex@gmail.com"
        )

        let googleService = GoogleCalendarService(
            httpLoader: { req in
                let url = try XCTUnwrap(req.url)
                let method = req.httpMethod ?? "GET"
                switch method {
                case "GET":
                    let body = try JSONEncoder().encode(GoogleEventListResponse(items: Array(remoteOAuthEvents.values), nextPageToken: nil))
                    return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                case "POST":
                    let payload = try JSONDecoder().decode(GoogleUpsertEventPayload.self, from: req.httpBody ?? Data())
                    let id = payload.id ?? UUID().uuidString
                    let dto = GoogleEventDTO(
                        id: id,
                        status: "confirmed",
                        summary: payload.summary,
                        description: payload.description,
                        transparency: "opaque",
                        start: payload.start,
                        end: payload.end,
                        extendedProperties: payload.extendedProperties
                    )
                    remoteOAuthEvents[id] = dto
                    let body = try JSONEncoder().encode(dto)
                    return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                case "PATCH":
                    let payload = try JSONDecoder().decode(GoogleUpsertEventPayload.self, from: req.httpBody ?? Data())
                    let id = url.lastPathComponent
                    let dto = GoogleEventDTO(
                        id: id,
                        status: "confirmed",
                        summary: payload.summary,
                        description: payload.description,
                        transparency: "opaque",
                        start: payload.start,
                        end: payload.end,
                        extendedProperties: payload.extendedProperties
                    )
                    remoteOAuthEvents[id] = dto
                    let body = try JSONEncoder().encode(dto)
                    return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                case "DELETE":
                    let id = url.lastPathComponent
                    remoteOAuthEvents.removeValue(forKey: id)
                    return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!)
                default:
                    return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
            },
            initialToken: testToken,
            freeTimeService: ekService,
            persistTokensToKeychain: false
        )

        // 1. Initial sync in `.oauthREST` mode -> 1 Google OAuth event, 0 Google Bridge events
        _ = await googleService.syncCalendarsAndRebalance(
            context: context,
            preferences: prefs,
            referenceDate: today,
            calendar: testCalendar
        )
        XCTAssertEqual(remoteOAuthEvents.count, 1)
        XCTAssertEqual(mockBacking.committedEvents.count, 0)
        XCTAssertNotNil(occ.googleCalendarEventId)
        XCTAssertNil(occ.syncedEKEventIdentifier)

        // 2. Switch mode `.oauthREST` -> `.iosGoogleAccount`: OAuth event MUST be deleted and 1 Bridge event created!
        prefs.googleSyncMode = .iosGoogleAccount
        XCTAssertTrue(prefs.needsGoogleOAuthChannelSweep)

        _ = await googleService.syncCalendarsAndRebalance(
            context: context,
            preferences: prefs,
            referenceDate: today,
            calendar: testCalendar
        )
        XCTAssertEqual(remoteOAuthEvents.count, 0)
        XCTAssertNil(occ.googleCalendarEventId)
        XCTAssertFalse(prefs.needsGoogleOAuthChannelSweep)
        XCTAssertEqual(mockBacking.committedEvents.count, 1)
        XCTAssertNotNil(occ.syncedEKEventIdentifier)

        // 3. Switch mode `.iosGoogleAccount` -> `.oauthREST`: Bridge event MUST be deleted and 1 OAuth event created!
        prefs.googleSyncMode = .oauthREST
        XCTAssertTrue(prefs.needsGoogleBridgeChannelSweep)

        _ = await googleService.syncCalendarsAndRebalance(
            context: context,
            preferences: prefs,
            referenceDate: today,
            calendar: testCalendar
        )
        XCTAssertEqual(mockBacking.committedEvents.count, 0)
        XCTAssertNil(occ.syncedEKEventIdentifier)
        XCTAssertFalse(prefs.needsGoogleBridgeChannelSweep)
        XCTAssertEqual(remoteOAuthEvents.count, 1)
        XCTAssertNotNil(occ.googleCalendarEventId)
    }

    func testIncrementalHistoricalStreakArchiveAndScopedCalendarSyncFetch() throws {
        let startDay = makeDate(year: 2026, month: 6, day: 1)
        let checkpointDay = DateHelpers.addDays(70, to: startDay, calendar: testCalendar)
        let finalToday = DateHelpers.addDays(130, to: startDay, calendar: testCalendar)

        let prefs = CozyPreferences(optionalBonusTasksEnabled: false)
        context.insert(prefs)

        let habit = TaskTemplate(
            title: "Evening stretch",
            recurrence: .daily,
            durationMinutes: 15,
            isAutoScheduled: false,
            anchorDate: startDay,
            calendar: testCalendar
        )
        context.insert(habit)

        var allOccurrences: [TaskOccurrence] = []
        for offset in 0...130 {
            let day = DateHelpers.addDays(offset, to: startDay, calendar: testCalendar)
            let completed = (offset != 12 && offset != 88) // Streak breaks at day 12 and day 88
            let occ = TaskOccurrence(
                scheduledDate: day,
                periodKey: "daily:\(DateHelpers.dayKeyString(for: day, calendar: testCalendar))",
                status: completed ? .completed : .pending,
                completedAt: completed ? day.addingTimeInterval(20 * 3600) : nil,
                template: habit,
                calendar: testCalendar
            )
            context.insert(occ)
            allOccurrences.append(occ)
        }
        // Attach a stale remote Google ID to day 5 (125 days before `finalToday`) to verify scoped sync fetch retains it
        allOccurrences[5].googleCalendarEventId = "c021legacyremote"
        try context.save()

        // Step 1: Build initial archive up to `checkpointDay - 45`
        let cutoff1 = DateHelpers.addDays(-SmartScheduler.streakArchiveCutoffDays, to: checkpointDay, calendar: testCalendar)
        StreakAndBonusService.refreshHistoricalArchiveIfNeeded(
            context: context,
            preferences: prefs,
            operationalCutoff: cutoff1,
            today: checkpointDay,
            calendar: testCalendar
        )
        let firstArchiveKey = try XCTUnwrap(prefs.historicalStreakArchive?.archivedThroughDayKey)
        XCTAssertEqual(
            firstArchiveKey,
            DateHelpers.dayKeyString(for: DateHelpers.addDays(-1, to: cutoff1, calendar: testCalendar), calendar: testCalendar)
        )

        // Step 2: Advance incrementally to `finalToday - 45` (extends from `firstArchiveKey + 1d` instead of scanning from day 0)
        let cutoff2 = DateHelpers.addDays(-SmartScheduler.streakArchiveCutoffDays, to: finalToday, calendar: testCalendar)
        StreakAndBonusService.refreshHistoricalArchiveIfNeeded(
            context: context,
            preferences: prefs,
            operationalCutoff: cutoff2,
            today: finalToday,
            calendar: testCalendar
        )

        let fullScan = StreakAndBonusService.evaluate(
            occurrences: allOccurrences,
            optionalBonusTasksEnabled: false,
            historicalArchive: nil,
            today: finalToday,
            calendar: testCalendar
        )
        let operationalSlice = allOccurrences.filter { $0.scheduledDay(calendar: testCalendar) >= cutoff2 }
        let incrementalEval = StreakAndBonusService.evaluate(
            occurrences: operationalSlice,
            persistedLongestStreak: prefs.longestRecordedStreak,
            optionalBonusTasksEnabled: false,
            historicalArchive: prefs.historicalStreakArchive,
            today: finalToday,
            calendar: testCalendar
        )

        XCTAssertEqual(incrementalEval.currentStreak, fullScan.currentStreak)
        XCTAssertEqual(incrementalEval.longestStreak, fullScan.longestStreak)
        XCTAssertEqual(incrementalEval.totalGoldDays, fullScan.totalGoldDays)
        XCTAssertEqual(incrementalEval.totalSilverDays, fullScan.totalSilverDays)
        XCTAssertEqual(incrementalEval.totalBronzeOrPinkDays, fullScan.totalBronzeOrPinkDays)

        // Step 3: Scoped calendar sync & notification digest fetches exclude old unlinked history rows while keeping needed items
        let syncCandidates = GoogleCalendarService.fetchOccurrencesForCalendarSync(
            context: context,
            today: finalToday,
            calendar: testCalendar
        )
        XCTAssertLessThan(syncCandidates.count, 25)
        XCTAssertTrue(syncCandidates.contains(where: { $0.id == allOccurrences[5].id }))
        XCTAssertFalse(syncCandidates.contains(where: { $0.id == allOccurrences[10].id }))

        let summaryCandidates = NotificationManager.fetchOccurrencesForSummarySync(
            context: context,
            now: finalToday.addingTimeInterval(12 * 3600),
            calendar: testCalendar
        )
        XCTAssertLessThan(summaryCandidates.count, allOccurrences.count)
        XCTAssertFalse(summaryCandidates.contains(where: { $0.id == allOccurrences[0].id }))
        XCTAssertTrue(summaryCandidates.contains(where: { $0.id == allOccurrences[130].id }))
    }

    func testPinnedDueTodayHardDeadlineTaskCountsCapacityOnce() throws {
        // Monday Nov 9, 2026: Today cup = 2h (120m); Tuesday budget = 45m; Wed-Sun = 0m
        let monday = makeDate(year: 2026, month: 11, day: 9)
        let tuesday = makeDate(year: 2026, month: 11, day: 10)

        let prefs = CozyPreferences(
            sundayBudgetMinutes: 0,
            mondayBudgetMinutes: 120,
            tuesdayBudgetMinutes: 45,
            wednesdayBudgetMinutes: 0,
            thursdayBudgetMinutes: 0,
            fridayBudgetMinutes: 0,
            saturdayBudgetMinutes: 0
        )
        prefs.recordCupCheckIn(hours: 2, for: monday, calendar: testCalendar)
        context.insert(prefs)

        let urgentTemplate = TaskTemplate(
            title: "Submit rent check",
            emoji: "🏠",
            recurrence: .once,
            durationMinutes: 60,
            weight: .light,
            hasHardDeadline: true,
            hardDeadlineDate: monday,
            isAutoScheduled: true,
            anchorDate: monday,
            calendar: testCalendar
        )
        let flexibleTemplate = TaskTemplate(
            title: "Fold laundry",
            emoji: "🧺",
            recurrence: .weekly,
            durationMinutes: 60,
            weight: .light,
            isAutoScheduled: true,
            anchorDate: monday,
            calendar: testCalendar
        )
        context.insert(urgentTemplate)
        context.insert(flexibleTemplate)

        // Pre-existing manually pinned occurrence due today (60m):
        // - If counted ONCE: Monday remaining after 60m flexible task = 120 - 60 - 60 = 0m (> Tuesday's 45 - 60 = -15m) -> stays Monday!
        // - If DOUBLE-COUNTED: Monday remaining = 120 - 120 - 60 = -60m (< Tuesday's -15m) -> wrongly displaced to Tuesday!
        let pinnedUrgentOcc = TaskOccurrence(
            scheduledDate: monday,
            periodKey: "once:\(urgentTemplate.id.uuidString)",
            status: .pending,
            isManuallyPinned: true,
            template: urgentTemplate,
            calendar: testCalendar
        )
        context.insert(pinnedUrgentOcc)
        try context.save()

        SmartScheduler.rebalance(
            context: context,
            preferences: prefs,
            calendarBusyByDay: [:],
            referenceDate: monday,
            calendar: testCalendar
        )

        let all = try context.fetch(FetchDescriptor<TaskOccurrence>())
        let flexOcc = try XCTUnwrap(all.first(where: { $0.template?.id == flexibleTemplate.id }))

        XCTAssertEqual(pinnedUrgentOcc.scheduledDay(calendar: testCalendar), monday)
        XCTAssertEqual(
            flexOcc.scheduledDay(calendar: testCalendar),
            monday,
            "Pinned due-today deadline task must only consume its 60m load once, leaving 60m on Monday (not Tuesday)"
        )
        XCTAssertNotEqual(flexOcc.scheduledDay(calendar: testCalendar), tuesday)
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return testCalendar.date(from: comps)!
    }
}

@MainActor
private final class MockEventStoreBacking: EventStoreBacking {
    struct MockBackingError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    var authStatus: EKAuthorizationStatus = .fullAccess
    var calendarsList: [BackingCalendarInfo] = []
    private(set) var committedEvents: [String: BackingEventRecord] = [:]
    private var stagedSaves: [String: BackingEventRecord] = [:]
    private var stagedRemovals: Set<String> = []
    var failingRemoveIDs: Set<String> = []
    var failingSaveIDs: Set<String> = []
    var shouldFailCommit: Bool = false
    private(set) var resetCount: Int = 0
    private var counter: Int = 0

    func seedCommittedEvent(_ record: BackingEventRecord) {
        let id = record.eventIdentifier ?? "mock-seed-\(UUID().uuidString)"
        record.eventIdentifier = id
        committedEvents[id] = Self.clone(record)
    }

    func authorizationStatus() -> EKAuthorizationStatus {
        authStatus
    }

    func requestFullAccess() async throws -> Bool {
        authStatus == .fullAccess
    }

    func calendars() -> [BackingCalendarInfo] {
        calendarsList
    }

    func events(from startDate: Date, to endDate: Date, calendarIdentifiers: [String]?) -> [BackingEventRecord] {
        let filterSet = calendarIdentifiers.map(Set.init)
        var visible = committedEvents
        for (id, saved) in stagedSaves {
            visible[id] = saved
        }
        for removedID in stagedRemovals {
            visible.removeValue(forKey: removedID)
        }
        return visible.values
            .filter { ev in
                if let filterSet, !filterSet.contains(ev.calendarIdentifier) {
                    return false
                }
                return ev.endDate > startDate && ev.startDate < endDate
            }
            .map(Self.clone)
    }

    func event(withIdentifier identifier: String) -> BackingEventRecord? {
        if stagedRemovals.contains(identifier) {
            return nil
        }
        if let staged = stagedSaves[identifier] {
            return Self.clone(staged)
        }
        return committedEvents[identifier].map(Self.clone)
    }

    func makeNewEvent(in calendarIdentifier: String) -> BackingEventRecord {
        counter += 1
        return BackingEventRecord(
            eventIdentifier: "mock-ek-\(counter)",
            calendarIdentifier: calendarIdentifier
        )
    }

    func save(_ event: BackingEventRecord) throws {
        if event.eventIdentifier == nil {
            counter += 1
            event.eventIdentifier = "mock-ek-\(counter)"
        }
        let id = event.eventIdentifier!
        if failingSaveIDs.contains(id) {
            throw MockBackingError(message: "Simulated save failure for \(id)")
        }
        stagedRemovals.remove(id)
        stagedSaves[id] = Self.clone(event)
    }

    func remove(_ event: BackingEventRecord) throws {
        guard let id = event.resolvedEventIdentifier else { return }
        if failingRemoveIDs.contains(id) {
            throw MockBackingError(message: "Simulated remove failure for \(id)")
        }
        stagedSaves.removeValue(forKey: id)
        stagedRemovals.insert(id)
    }

    func commit() throws {
        if shouldFailCommit {
            throw MockBackingError(message: "Simulated EventKit commit failure")
        }
        for (id, saved) in stagedSaves {
            committedEvents[id] = Self.clone(saved)
        }
        for removedID in stagedRemovals {
            committedEvents.removeValue(forKey: removedID)
        }
        stagedSaves.removeAll()
        stagedRemovals.removeAll()
    }

    func reset() {
        resetCount += 1
        stagedSaves.removeAll()
        stagedRemovals.removeAll()
    }

    private static func clone(_ src: BackingEventRecord) -> BackingEventRecord {
        BackingEventRecord(
            eventIdentifier: src.eventIdentifier,
            calendarIdentifier: src.calendarIdentifier,
            title: src.title,
            startDate: src.startDate,
            endDate: src.endDate,
            isAllDay: src.isAllDay,
            isFreeAvailability: src.isFreeAvailability,
            url: src.url,
            notes: src.notes
        )
    }
}

