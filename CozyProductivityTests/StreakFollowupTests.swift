import Foundation
import SwiftData
import XCTest
@testable import CozyProductivity

@MainActor
final class StreakFollowupTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        let schema = Schema([
            TaskTemplate.self,
            TaskOccurrence.self,
            CozyPreferences.self,
            DayCapacityOverride.self
        ])
        container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        context = container.mainContext
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        cal.firstWeekday = 2
        calendar = cal
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        calendar = nil
    }

    func testPartialDayStaysIncompleteAfterActualDailyRollover() throws {
        let monday = date(2026, 11, 9)
        let tuesday = addDays(1, monday)
        let prefs = preferences()
        let first = dailyTask("Stretch", starting: monday)
        let second = dailyTask("Read", starting: monday)

        rebalance(on: monday, preferences: prefs)
        let mondayItems = try occurrences(on: monday)
        let completed = try XCTUnwrap(mondayItems.first { $0.template?.id == first.id })
        completed.markCompleted(at: monday.addingTimeInterval(18 * 3600), calendar: calendar)
        try context.save()

        let before = try snapshot(today: monday)
        XCTAssertEqual(before.summary(for: monday, calendar: calendar).baseTotalCount, 2)
        XCTAssertEqual(before.summary(for: monday, calendar: calendar).baseCompletedCount, 1)
        XCTAssertEqual(before.tier(for: monday, calendar: calendar), .none)

        rebalance(on: tuesday, preferences: prefs)

        let missed = try XCTUnwrap(occurrences(on: monday).first { $0.template?.id == second.id })
        XCTAssertEqual(missed.status, .missed)
        XCTAssertFalse(missed.status.isScheduled)
        let after = try snapshot(today: tuesday)
        XCTAssertEqual(after.summary(for: monday, calendar: calendar).baseTotalCount, 2)
        XCTAssertEqual(after.summary(for: monday, calendar: calendar).baseCompletedCount, 1)
        XCTAssertEqual(after.tier(for: monday, calendar: calendar), .none)
        XCTAssertEqual(after.totalGoldDays, 0)
    }

    func testEntirelyMissedDayBreaksExistingStreakAfterRollover() throws {
        let sunday = date(2026, 11, 8)
        let monday = addDays(1, sunday)
        let tuesday = addDays(2, sunday)
        let prefs = preferences()
        _ = dailyTask("Stretch", starting: sunday)
        _ = dailyTask("Read", starting: sunday)

        rebalance(on: sunday, preferences: prefs)
        for occurrence in try occurrences(on: sunday) {
            occurrence.markCompleted(at: sunday.addingTimeInterval(18 * 3600), calendar: calendar)
        }
        try context.save()
        rebalance(on: monday, preferences: prefs)
        XCTAssertEqual(try snapshot(today: monday).currentStreak, 1)

        // Leave both Monday commitments pending, then exercise the same rollover as app activation.
        rebalance(on: tuesday, preferences: prefs)

        XCTAssertTrue(try occurrences(on: monday).allSatisfy { $0.status == .missed })
        let result = try snapshot(today: tuesday)
        XCTAssertEqual(result.summary(for: monday, calendar: calendar).baseTotalCount, 2)
        XCTAssertEqual(result.summary(for: monday, calendar: calendar).baseCompletedCount, 0)
        XCTAssertEqual(result.currentStreak, 0)
        XCTAssertEqual(result.longestStreak, 1)
    }

    func testDeliberatelySkippedTaskRemainsExcludedAfterRollover() throws {
        let monday = date(2026, 11, 9)
        let tuesday = addDays(1, monday)
        let prefs = preferences()
        let first = dailyTask("Stretch", starting: monday)
        let second = dailyTask("Read", starting: monday)
        rebalance(on: monday, preferences: prefs)

        let items = try occurrences(on: monday)
        try XCTUnwrap(items.first { $0.template?.id == first.id })
            .markCompleted(at: monday.addingTimeInterval(18 * 3600), calendar: calendar)
        let deliberatelySkipped = try XCTUnwrap(items.first { $0.template?.id == second.id })
        deliberatelySkipped.status = .skipped
        try context.save()

        rebalance(on: tuesday, preferences: prefs)

        XCTAssertEqual(deliberatelySkipped.status, .skipped)
        let result = try snapshot(today: tuesday)
        XCTAssertEqual(result.summary(for: monday, calendar: calendar).baseTotalCount, 1)
        XCTAssertEqual(result.tier(for: monday, calendar: calendar), .gold)
        XCTAssertEqual(result.currentStreak, 1)
    }

    func testExpiredRecurringSpilloverIsMissedInItsOriginalPeriod() throws {
        let sunday = date(2026, 11, 15)
        let monday = addDays(1, sunday)
        let prefs = preferences()
        prefs.recordCupCheckIn(hours: 0, for: sunday, calendar: calendar)
        let weekly = TaskTemplate(
            title: "Laundry",
            recurrence: .weekly,
            durationMinutes: 30,
            isAutoScheduled: false,
            anchorDate: sunday,
            calendar: calendar
        )
        context.insert(weekly)
        rebalance(on: sunday, preferences: prefs)
        let previousPeriodKey = DateHelpers.weekWindow(containing: sunday, calendar: calendar).key
        let spilled = try XCTUnwrap(allOccurrences().first { $0.periodKey == previousPeriodKey })
        XCTAssertEqual(spilled.scheduledDay(calendar: calendar), monday)

        rebalance(on: monday, preferences: prefs)

        XCTAssertEqual(spilled.status, .missed)
        XCTAssertEqual(spilled.scheduledDay(calendar: calendar), sunday)
        XCTAssertEqual(try snapshot(today: monday).summary(for: sunday, calendar: calendar).baseTotalCount, 1)
        XCTAssertFalse(try occurrences(on: monday).contains { $0.status == .missed })
    }

    func testIncrementalArchiveMatchesRealRolloverHistoryWithMissedAndSkippedDays() throws {
        let start = date(2026, 11, 1)
        let prefs = preferences()
        let first = dailyTask("Stretch", starting: start)
        _ = dailyTask("Read", starting: start)

        for offset in 0...9 {
            let day = addDays(offset, start)
            rebalance(on: day, preferences: prefs)
            for occurrence in try occurrences(on: day) {
                if offset == 2 || (offset == 4 && occurrence.template?.id != first.id) {
                    continue // One entirely missed day and one partly missed day.
                }
                if offset == 6 && occurrence.template?.id != first.id {
                    occurrence.status = .skipped
                } else {
                    occurrence.markCompleted(at: day.addingTimeInterval(18 * 3600), calendar: calendar)
                }
            }
            try context.save()
        }

        let today = addDays(9, start)
        let all = try allOccurrences()
        XCTAssertEqual(try occurrences(on: addDays(2, start)).filter { $0.status == .missed }.count, 2)
        XCTAssertEqual(try occurrences(on: addDays(4, start)).filter { $0.status == .missed }.count, 1)
        let full = StreakAndBonusService.evaluate(
            occurrences: all,
            optionalBonusTasksEnabled: false,
            today: today,
            calendar: calendar
        )

        prefs.historicalStreakArchive = nil
        StreakAndBonusService.refreshHistoricalArchiveIfNeeded(
            context: context,
            preferences: prefs,
            operationalCutoff: addDays(4, start),
            today: today,
            calendar: calendar
        )
        let finalCutoff = addDays(6, start)
        StreakAndBonusService.refreshHistoricalArchiveIfNeeded(
            context: context,
            preferences: prefs,
            operationalCutoff: finalCutoff,
            today: today,
            calendar: calendar
        )

        let archived = StreakAndBonusService.evaluate(
            occurrences: all.filter { $0.scheduledDay(calendar: calendar) >= finalCutoff },
            optionalBonusTasksEnabled: false,
            historicalArchive: try XCTUnwrap(prefs.historicalStreakArchive),
            today: today,
            calendar: calendar
        )
        XCTAssertEqual(full.currentStreak, 5)
        XCTAssertEqual(full.totalGoldDays, 8)
        XCTAssertEqual(archived.currentStreak, full.currentStreak)
        XCTAssertEqual(archived.longestStreak, full.longestStreak)
        XCTAssertEqual(archived.totalGoldDays, full.totalGoldDays)
        XCTAssertEqual(archived.totalSilverDays, full.totalSilverDays)
        XCTAssertEqual(archived.totalBronzeOrPinkDays, full.totalBronzeOrPinkDays)
    }

    private func preferences() -> CozyPreferences {
        let preferences = CozyPreferences(optionalBonusTasksEnabled: false)
        context.insert(preferences)
        return preferences
    }

    private func dailyTask(_ title: String, starting day: Date) -> TaskTemplate {
        let template = TaskTemplate(
            title: title,
            recurrence: .daily,
            durationMinutes: 15,
            isAutoScheduled: false,
            anchorDate: day,
            calendar: calendar
        )
        context.insert(template)
        return template
    }

    private func rebalance(on day: Date, preferences: CozyPreferences) {
        SmartScheduler.rebalance(
            context: context,
            preferences: preferences,
            referenceDate: day,
            horizonDays: 7,
            calendar: calendar
        )
    }

    private func allOccurrences() throws -> [TaskOccurrence] {
        try context.fetch(FetchDescriptor<TaskOccurrence>())
    }

    private func occurrences(on day: Date) throws -> [TaskOccurrence] {
        try allOccurrences().filter { $0.scheduledDay(calendar: calendar) == day }
    }

    private func snapshot(today: Date) throws -> StreakSnapshot {
        StreakAndBonusService.evaluate(
            occurrences: try allOccurrences(),
            optionalBonusTasksEnabled: false,
            today: today,
            calendar: calendar
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func addDays(_ days: Int, _ day: Date) -> Date {
        DateHelpers.addDays(days, to: day, calendar: calendar)
    }
}
