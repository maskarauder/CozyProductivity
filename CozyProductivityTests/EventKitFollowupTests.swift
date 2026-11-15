import EventKit
import SwiftData
import XCTest
@testable import CozyProductivity

@MainActor
final class EventKitFollowupTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var calendar: Calendar!
    private var today: Date!

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
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar = utcCalendar
        today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15))!
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        calendar = nil
        today = nil
    }

    func testFallbackSweepReportsOnlyCommittedEventsInSelectedCalendarAndWindow() throws {
        let preferences = makePreferences()
        let current = makeOccurrence(title: "Current", day: today, oauthEventID: "rest-current")
        let oldDay = DateHelpers.addDays(-10, to: today, calendar: calendar)
        let old = makeOccurrence(title: "Older", day: oldDay, oauthEventID: "rest-old")
        let otherCalendar = makeOccurrence(title: "Other calendar", day: today, oauthEventID: "rest-other")
        otherCalendar.googleSyncedDestination = "google-oauth|alex@gmail.com|second-calendar"
        let backing = makeBacking()
        backing.seed(makeOAuthEvent(identifier: "ek-current", occurrence: current, calendarID: "google-primary"))
        backing.seed(makeOAuthEvent(identifier: "ek-old", occurrence: old, calendarID: "google-primary"))
        backing.seed(makeOAuthEvent(identifier: "ek-other", occurrence: otherCalendar, calendarID: "google-secondary"))

        let result = CalendarFreeTimeService(backing: backing).pushAndMergeViaGoogleBridge(
            occurrences: [current, old, otherCalendar],
            busyIntervalsByDay: [:],
            preferences: preferences,
            today: today,
            allowSlotChangingWrites: false,
            sweepStrandedOAuthEvents: true,
            calendar: calendar
        )

        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.confirmedOAuthRemovals, [
            EKConfirmedOAuthRemoval(
                occurrenceID: current.id,
                eventIdentifier: "ek-current",
                calendarIdentifier: "google-primary"
            )
        ])
        XCTAssertNil(backing.committedEvents["ek-current"])
        XCTAssertNotNil(backing.committedEvents["ek-old"])
        XCTAssertNotNil(backing.committedEvents["ek-other"])
        XCTAssertEqual(current.googleCalendarEventId, "rest-current")
        XCTAssertEqual(old.googleCalendarEventId, "rest-old")
        XCTAssertEqual(otherCalendar.googleCalendarEventId, "rest-other")
        XCTAssertEqual(otherCalendar.googleSyncedDestination, "google-oauth|alex@gmail.com|second-calendar")
        XCTAssertTrue(preferences.needsGoogleOAuthChannelSweep)
    }

    func testFallbackSweepCommitFailureDoesNotConfirmRemovalOrClearRetryTracking() throws {
        let preferences = makePreferences()
        let occurrence = makeOccurrence(title: "Keep tracked", day: today, oauthEventID: "rest-keep")
        let backing = makeBacking()
        backing.seed(makeOAuthEvent(identifier: "ek-keep", occurrence: occurrence, calendarID: "google-primary"))
        backing.shouldFailCommit = true

        let result = CalendarFreeTimeService(backing: backing).pushAndMergeViaGoogleBridge(
            occurrences: [occurrence],
            busyIntervalsByDay: [:],
            preferences: preferences,
            today: today,
            allowSlotChangingWrites: false,
            sweepStrandedOAuthEvents: true,
            calendar: calendar
        )

        XCTAssertEqual(result.removed, 0)
        XCTAssertGreaterThan(result.failed, 0)
        XCTAssertTrue(result.confirmedOAuthRemovals.isEmpty)
        XCTAssertEqual(backing.resetCount, 1)
        XCTAssertNotNil(backing.committedEvents["ek-keep"])
        XCTAssertEqual(occurrence.googleCalendarEventId, "rest-keep")
        XCTAssertEqual(occurrence.googleSyncedDestination, "google-oauth|alex@gmail.com|primary")
        XCTAssertTrue(preferences.needsGoogleOAuthChannelSweep)
    }

    func testFallbackSweepFailedRemovalIsReportedOnlyAfterQueuedRetryCommits() throws {
        let preferences = makePreferences()
        let occurrence = makeOccurrence(title: "Retry", day: today, oauthEventID: "rest-retry")
        let backing = makeBacking()
        backing.seed(makeOAuthEvent(identifier: "ek-retry", occurrence: occurrence, calendarID: "google-primary"))
        backing.failingRemoveIDs = ["ek-retry"]
        let service = CalendarFreeTimeService(backing: backing)

        let failed = service.pushAndMergeViaGoogleBridge(
            occurrences: [occurrence],
            busyIntervalsByDay: [:],
            preferences: preferences,
            today: today,
            allowSlotChangingWrites: false,
            sweepStrandedOAuthEvents: true,
            calendar: calendar
        )
        XCTAssertTrue(failed.confirmedOAuthRemovals.isEmpty)
        XCTAssertGreaterThan(failed.failed, 0)
        XCTAssertEqual(preferences.pendingEKDeletions.map(\.eventIdentifier), ["ek-retry"])

        backing.failingRemoveIDs = []
        let retried = service.pushAndMergeViaGoogleBridge(
            occurrences: [occurrence],
            busyIntervalsByDay: [:],
            preferences: preferences,
            today: today,
            allowSlotChangingWrites: false,
            sweepStrandedOAuthEvents: true,
            calendar: calendar
        )
        XCTAssertEqual(retried.failed, 0)
        XCTAssertEqual(retried.confirmedOAuthRemovals, [
            EKConfirmedOAuthRemoval(
                occurrenceID: occurrence.id,
                eventIdentifier: "ek-retry",
                calendarIdentifier: "google-primary"
            )
        ])
        XCTAssertNil(backing.committedEvents["ek-retry"])
        XCTAssertTrue(preferences.pendingEKDeletions.isEmpty)
        XCTAssertEqual(occurrence.googleCalendarEventId, "rest-retry")
        XCTAssertTrue(preferences.needsGoogleOAuthChannelSweep)
    }

    private func makePreferences() -> CozyPreferences {
        let preferences = CozyPreferences(
            pushTasksToGoogleCalendar: true,
            googleSyncMode: .iosGoogleAccount
        )
        preferences.needsGoogleOAuthChannelSweep = true
        context.insert(preferences)
        return preferences
    }

    private func makeOccurrence(title: String, day: Date, oauthEventID: String) -> TaskOccurrence {
        let template = TaskTemplate(
            title: title,
            recurrence: .once,
            durationMinutes: 30,
            isAutoScheduled: false,
            anchorDate: day,
            calendar: calendar
        )
        context.insert(template)
        let occurrence = TaskOccurrence(
            scheduledDate: day,
            periodKey: "once:\(template.id.uuidString)",
            status: .pending,
            template: template,
            calendar: calendar
        )
        occurrence.googleCalendarEventId = oauthEventID
        occurrence.googleSyncedDestination = "google-oauth|alex@gmail.com|primary"
        context.insert(occurrence)
        return occurrence
    }

    private func makeOAuthEvent(identifier: String, occurrence: TaskOccurrence, calendarID: String) -> BackingEventRecord {
        let start = occurrence.scheduledDay(calendar: calendar).addingTimeInterval(9 * 3600)
        return BackingEventRecord(
            eventIdentifier: identifier,
            calendarIdentifier: calendarID,
            title: occurrence.displayTitle,
            startDate: start,
            endDate: start.addingTimeInterval(1800),
            notes: CalendarFreeTimeService.formatCozyMetadataTag(channel: .googleOAuth, occurrenceID: occurrence.id)
        )
    }

    private func makeBacking() -> FollowupEventStoreBacking {
        let backing = FollowupEventStoreBacking()
        backing.calendarList = [
            BackingCalendarInfo(
                calendarIdentifier: "google-primary",
                title: "alex@gmail.com",
                sourceTitle: "Google",
                allowsContentModifications: true,
                isDefaultForNewEvents: true
            ),
            BackingCalendarInfo(
                calendarIdentifier: "google-secondary",
                title: "Second calendar",
                sourceTitle: "Google",
                allowsContentModifications: true,
                isDefaultForNewEvents: false
            )
        ]
        return backing
    }
}

@MainActor
final class FollowupEventStoreBacking: EventStoreBacking {
    private struct SimulatedFailure: Error {}

    var calendarList: [BackingCalendarInfo] = []
    private(set) var committedEvents: [String: BackingEventRecord] = [:]
    private var stagedSaves: [String: BackingEventRecord] = [:]
    private var stagedRemovals: Set<String> = []
    var failingRemoveIDs: Set<String> = []
    var shouldFailCommit = false
    private(set) var resetCount = 0
    private var nextID = 0

    func seed(_ event: BackingEventRecord) {
        committedEvents[event.eventIdentifier!] = Self.clone(event)
    }

    func authorizationStatus() -> EKAuthorizationStatus { .fullAccess }
    func requestFullAccess() async throws -> Bool { true }
    func calendars() -> [BackingCalendarInfo] { calendarList }

    func events(from startDate: Date, to endDate: Date, calendarIdentifiers: [String]?) -> [BackingEventRecord] {
        var visible = committedEvents.merging(stagedSaves) { _, saved in saved }
        for identifier in stagedRemovals { visible.removeValue(forKey: identifier) }
        return visible.values.filter { event in
            (calendarIdentifiers?.contains(event.calendarIdentifier) ?? true)
                && event.endDate > startDate && event.startDate < endDate
        }.map(Self.clone)
    }

    func event(withIdentifier identifier: String) -> BackingEventRecord? {
        guard !stagedRemovals.contains(identifier) else { return nil }
        return (stagedSaves[identifier] ?? committedEvents[identifier]).map(Self.clone)
    }

    func makeNewEvent(in calendarIdentifier: String) -> BackingEventRecord {
        nextID += 1
        return BackingEventRecord(eventIdentifier: "followup-new-\(nextID)", calendarIdentifier: calendarIdentifier)
    }

    func save(_ event: BackingEventRecord) throws {
        let identifier = event.eventIdentifier!
        stagedRemovals.remove(identifier)
        stagedSaves[identifier] = Self.clone(event)
    }

    func remove(_ event: BackingEventRecord) throws {
        guard let identifier = event.resolvedEventIdentifier else { return }
        if failingRemoveIDs.contains(identifier) { throw SimulatedFailure() }
        stagedSaves.removeValue(forKey: identifier)
        stagedRemovals.insert(identifier)
    }

    func commit() throws {
        if shouldFailCommit { throw SimulatedFailure() }
        committedEvents.merge(stagedSaves) { _, saved in saved }
        for identifier in stagedRemovals { committedEvents.removeValue(forKey: identifier) }
        stagedSaves.removeAll()
        stagedRemovals.removeAll()
    }

    func reset() {
        resetCount += 1
        stagedSaves.removeAll()
        stagedRemovals.removeAll()
    }

    private static func clone(_ event: BackingEventRecord) -> BackingEventRecord {
        BackingEventRecord(
            eventIdentifier: event.eventIdentifier,
            calendarIdentifier: event.calendarIdentifier,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            isFreeAvailability: event.isFreeAvailability,
            url: event.url,
            notes: event.notes
        )
    }
}
