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

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return testCalendar.date(from: comps)!
    }
}
