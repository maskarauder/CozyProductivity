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

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return testCalendar.date(from: comps)!
    }
}
