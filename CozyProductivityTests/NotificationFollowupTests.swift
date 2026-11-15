import SwiftData
import UserNotifications
import XCTest
@testable import CozyProductivity

@MainActor
final class NotificationFollowupTests: XCTestCase {
    func testDisablingSummariesWhileAnAddIsSuspendedRemovesTheStaleAdd() async throws {
        let center = PausingNotificationCenter()
        let manager = NotificationManager(notificationCenter: center)
        let preferences = CozyPreferences()
        preferences.dailySummaryEnabled = true
        preferences.weeklySummaryEnabled = false
        preferences.monthlySummaryEnabled = false
        let calendar = makeCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12)))

        let oldSync = Task { @MainActor in
            await manager.syncSummaryNotifications(
                preferences: preferences,
                occurrences: [],
                now: now,
                calendar: calendar
            )
        }
        await fulfillment(of: [center.firstAddStarted], timeout: 2)

        preferences.dailySummaryEnabled = false
        let disablingRequestStarted = expectation(description: "Disabling rebuild entered")
        let disablingSync = Task { @MainActor in
            disablingRequestStarted.fulfill()
            await manager.syncSummaryNotifications(
                preferences: preferences,
                occurrences: [],
                now: now,
                calendar: calendar
            )
        }
        // Both tasks run on the main actor; the second call queues before yielding
        // back to this test, while the first center.add is deliberately suspended.
        await fulfillment(of: [disablingRequestStarted], timeout: 2)
        XCTAssertEqual(center.addedIdentifiers.count, 0)
        center.finishSuspendedAdd()
        await oldSync.value
        await disablingSync.value

        XCTAssertEqual(center.addedIdentifiers.count, 1, "The superseded loop must stop after its in-flight add")
        XCTAssertTrue(center.pendingRequests.isEmpty, "The final disabled configuration must remove that stale add")
        XCTAssertEqual(center.removedIdentifiers, center.addedIdentifiers)
    }

    func testSummaryFetchExcludesOldBonusHistoryButKeepsCurrentBonusWithOldScheduledDate() throws {
        let schema = Schema([
            TaskTemplate.self,
            TaskOccurrence.self,
            CozyPreferences.self,
            DayCapacityOverride.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let calendar = makeCalendar()
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15)))
        let oldDay = DateHelpers.addDays(-700, to: today, calendar: calendar)
        let template = TaskTemplate(title: "Bonus task", recurrence: .daily, anchorDate: oldDay, calendar: calendar)
        context.insert(template)

        var oldBonusIDs = Set<UUID>()
        for offset in 0..<120 {
            let day = DateHelpers.addDays(offset, to: oldDay, calendar: calendar)
            let occurrence = TaskOccurrence(
                scheduledDate: DateHelpers.addDays(1, to: day, calendar: calendar),
                periodKey: "old-bonus-\(offset)",
                status: .completed,
                completedAt: day,
                bonusForDate: day,
                bonusSlot: 1,
                template: template,
                calendar: calendar
            )
            context.insert(occurrence)
            oldBonusIDs.insert(occurrence.id)
        }

        let currentBonus = TaskOccurrence(
            scheduledDate: oldDay,
            periodKey: "current-bonus-old-schedule",
            status: .completed,
            completedAt: today,
            bonusForDate: today,
            bonusSlot: 1,
            template: template,
            calendar: calendar
        )
        let ordinaryCurrent = TaskOccurrence(
            scheduledDate: today,
            periodKey: "ordinary-current",
            template: template,
            calendar: calendar
        )
        context.insert(currentBonus)
        context.insert(ordinaryCurrent)
        try context.save()

        let fetched = NotificationManager.fetchOccurrencesForSummarySync(
            context: context,
            now: today.addingTimeInterval(12 * 3600),
            calendar: calendar
        )
        let fetchedIDs = Set(fetched.map(\.id))
        XCTAssertEqual(fetchedIDs, Set([currentBonus.id, ordinaryCurrent.id]))
        XCTAssertTrue(fetchedIDs.isDisjoint(with: oldBonusIDs))
    }

    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }
}

@MainActor
private final class PausingNotificationCenter: CozyNotificationCenter {
    let firstAddStarted = XCTestExpectation(description: "First notification add suspended")
    private var suspendedAdd: CheckedContinuation<Void, Never>?
    private var shouldPauseFirstAdd = true
    private(set) var pendingRequests: [String: UNNotificationRequest] = [:]
    private(set) var addedIdentifiers: [String] = []
    private(set) var removedIdentifiers: [String] = []

    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization() async throws -> Bool { true }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        Array(pendingRequests.values)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
        for identifier in identifiers {
            pendingRequests[identifier] = nil
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        if shouldPauseFirstAdd {
            shouldPauseFirstAdd = false
            await withCheckedContinuation { continuation in
                suspendedAdd = continuation
                firstAddStarted.fulfill()
            }
        }
        addedIdentifiers.append(request.identifier)
        pendingRequests[request.identifier] = request
    }

    func finishSuspendedAdd() {
        let continuation = suspendedAdd
        suspendedAdd = nil
        continuation?.resume()
    }
}
