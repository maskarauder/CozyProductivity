import Foundation
import SwiftData
import XCTest
@testable import CozyProductivity

@MainActor
final class GoogleCalendarFollowupTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var calendar: Calendar!
    private var day: Date!

    override func setUpWithError() throws {
        let schema = Schema([TaskTemplate.self, TaskOccurrence.self, CozyPreferences.self, DayCapacityOverride.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = container.mainContext
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14))!
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        calendar = nil
        day = nil
    }

    func testBusyCacheUsesWallClockEvenWhenCallerPassesLogicalMidnight() async throws {
        var wallNow = day.addingTimeInterval(5 * 3600)
        let prefs = CozyPreferences(useGoogleCalendarSync: true, googleClientID: "test-client", dailyCupPromptEnabled: false)
        context.insert(prefs)
        var failBusyRead = false
        var returnMeeting = true
        var postCount = 0
        let meeting = GoogleEventDTO(
            id: "meeting", status: "confirmed", summary: "Meeting", description: nil, transparency: "opaque",
            start: GoogleEventDateTimeDTO(dateTime: GoogleCalendarService.formatRFC3339(day.addingTimeInterval(18 * 3600)), date: nil, timeZone: "UTC"),
            end: GoogleEventDateTimeDTO(dateTime: GoogleCalendarService.formatRFC3339(day.addingTimeInterval(19 * 3600)), date: nil, timeZone: "UTC"),
            extendedProperties: nil
        )
        let service = GoogleCalendarService(
            httpLoader: { request in
                let url = try XCTUnwrap(request.url)
                if request.httpMethod == "POST" { postCount += 1 }
                let isManagedRead = (url.query ?? "").contains("privateExtendedProperty")
                if !isManagedRead && failBusyRead {
                    return Self.response(url, status: 503)
                }
                let items = !isManagedRead && returnMeeting ? [meeting] : []
                return Self.response(url, data: try JSONEncoder().encode(GoogleEventListResponse(items: items, nextPageToken: nil)))
            },
            initialToken: token(expiringAt: wallNow.addingTimeInterval(2 * 86400)),
            now: { wallNow }
        )

        let initial = await service.syncCalendarsAndRebalance(context: context, preferences: prefs, referenceDate: day, calendar: calendar)
        XCTAssertTrue(initial.busyReadSucceeded)
        XCTAssertEqual(prefs.cachedGoogleBusySnapshot?.fetchedAt, wallNow)
        XCTAssertEqual(initial.mergedBusyByDay[day], 60)

        failBusyRead = true
        wallNow = day.addingTimeInterval(23 * 3600)
        prefs.pushTasksToGoogleCalendar = true
        let occurrence = insertOccurrence(title: "Late task", scheduled: day)
        try context.save()
        let expired = await service.pushOccurrenceChangesWithoutRebalance(context: context, preferences: prefs, referenceDate: day, calendar: calendar)
        XCTAssertFalse(expired.usedCachedBusySnapshot)
        XCTAssertFalse(expired.busyReadSucceeded)
        XCTAssertEqual(expired.deferredCount, 1)
        XCTAssertEqual(postCount, 0)
        XCTAssertNil(occurrence.googleCalendarEventId)

        failBusyRead = false
        returnMeeting = false
        prefs.pushTasksToGoogleCalendar = false
        let cleared = await service.syncCalendarsAndRebalance(context: context, preferences: prefs, referenceDate: day, calendar: calendar)
        XCTAssertTrue(cleared.busyReadSucceeded)
        XCTAssertTrue(cleared.mergedBusyByDay.isEmpty)
        XCTAssertEqual(prefs.cachedGoogleBusySnapshot?.fetchedAt, wallNow)
    }

    func testDisconnectWaitsForInFlightCreateThenRemovesItBeforeSigningOut() async throws {
        let now = day.addingTimeInterval(10 * 3600)
        let prefs = CozyPreferences(pushTasksToGoogleCalendar: true, googleClientID: "test-client", dailyCupPromptEnabled: false)
        context.insert(prefs)
        let occurrence = insertOccurrence(title: "In flight", scheduled: day)
        try context.save()
        let postEntered = GoogleFollowupGate()
        let releasePost = GoogleFollowupGate()
        let disconnectEntered = GoogleFollowupGate()
        var remote: [String: GoogleEventDTO] = [:]
        var operations: [String] = []
        let service = GoogleCalendarService(
            httpLoader: { request in
                let url = try XCTUnwrap(request.url)
                switch request.httpMethod ?? "GET" {
                case "POST":
                    postEntered.open()
                    await releasePost.wait()
                    let payload = try JSONDecoder().decode(GoogleUpsertEventPayload.self, from: XCTUnwrap(request.httpBody))
                    let id = try XCTUnwrap(payload.id)
                    let event = Self.event(id: id, payload: payload)
                    remote[id] = event
                    operations.append("created")
                    return Self.response(url, data: try JSONEncoder().encode(event))
                case "DELETE":
                    remote.removeValue(forKey: url.lastPathComponent)
                    operations.append("deleted")
                    return Self.response(url, status: 204)
                default:
                    return Self.response(url, data: try JSONEncoder().encode(GoogleEventListResponse(items: Array(remote.values), nextPageToken: nil)))
                }
            },
            initialToken: token(expiringAt: now.addingTimeInterval(86400)),
            now: { now }
        )
        let sync = Task { @MainActor in
            await service.pushOccurrenceChangesWithoutRebalance(context: context, preferences: prefs, referenceDate: day, calendar: calendar)
        }
        await postEntered.wait()
        let disconnect = Task { @MainActor in
            disconnectEntered.open()
            return await service.disconnect(context: context, preferences: prefs, referenceDate: day, calendar: calendar)
        }
        await disconnectEntered.wait()
        XCTAssertTrue(service.isDisconnecting)
        let deferred = await service.pushOccurrenceChangesWithoutRebalance(context: context, preferences: prefs, referenceDate: day, calendar: calendar)
        XCTAssertEqual(deferred.upsertedCount, 0)
        XCTAssertTrue(operations.isEmpty)

        releasePost.open()
        _ = await sync.value
        let disconnected = await disconnect.value
        XCTAssertEqual(operations, ["created", "deleted"])
        XCTAssertEqual(disconnected.failedCount, 0)
        XCTAssertTrue(remote.isEmpty)
        XCTAssertNil(occurrence.googleCalendarEventId)
        XCTAssertNil(service.token)
        XCTAssertFalse(service.isDisconnecting)
        XCTAssertFalse(service.isSyncing)
        XCTAssertFalse(prefs.needsGoogleOAuthChannelSweep)
    }

    func testLateRefreshCannotRestoreSignedOutToken() async throws {
        let now = day.addingTimeInterval(10 * 3600)
        let entered = GoogleFollowupGate()
        let release = GoogleFollowupGate()
        let prefs = CozyPreferences(googleClientID: "test-client")
        let service = GoogleCalendarService(
            httpLoader: { request in
                let url = try XCTUnwrap(request.url)
                XCTAssertEqual(url.host, "oauth2.googleapis.com")
                entered.open()
                await release.wait()
                return Self.response(url, data: Data(#"{"access_token":"new-token","expires_in":3600}"#.utf8))
            },
            initialToken: token(expiringAt: now.addingTimeInterval(-60)),
            now: { now }
        )
        let refresh = Task { @MainActor in
            try await service.fetchGoogleBusyIntervalsByDay(from: day, to: day, preferences: prefs, calendar: calendar)
        }
        await entered.wait()
        service.signOut()
        release.open()
        do {
            _ = try await refresh.value
            XCTFail("A retired refresh must not return an access token")
        } catch {
            XCTAssertFalse(service.isSignedInWithOAuth)
            XCTAssertNil(service.token)
        }
    }

    func testScopedFetchExcludesOldBonusesButRetainsTrackedCleanupAndCurrentBonus() throws {
        let oldDay = calendar.date(byAdding: .day, value: -100, to: day)!
        var old: [TaskOccurrence] = []
        for index in 0..<100 {
            let occurrence = insertOccurrence(title: "Old bonus \(index)", scheduled: oldDay)
            occurrence.setBonusDay(oldDay, slot: 1, calendar: calendar)
            occurrence.markCompleted(at: oldDay.addingTimeInterval(12 * 3600), calendar: calendar)
            old.append(occurrence)
        }
        old[0].googleCalendarEventId = "pending-cleanup"
        let future = calendar.date(byAdding: .day, value: 30, to: day)!
        let currentBonus = insertOccurrence(title: "Current bonus", scheduled: future)
        currentBonus.setBonusDay(day, slot: 1, calendar: calendar)
        try context.save()
        let fetched = try GoogleCalendarService.fetchOccurrencesForCalendarSync(context: context, today: day, calendar: calendar)
        XCTAssertEqual(Set(fetched.map(\.id)), Set([old[0].id, currentBonus.id]))
    }

    func testRepeatedPageTokenFailsInsteadOfReturningPartialBusyData() async throws {
        let now = day.addingTimeInterval(10 * 3600)
        var reads = 0
        let service = GoogleCalendarService(
            httpLoader: { request in
                reads += 1
                return Self.response(try XCTUnwrap(request.url), data: try JSONEncoder().encode(GoogleEventListResponse(items: [], nextPageToken: "repeated")))
            },
            initialToken: token(expiringAt: now.addingTimeInterval(86400)),
            now: { now }
        )
        do {
            _ = try await service.fetchGoogleBusyIntervalsByDay(from: day, to: day, preferences: CozyPreferences(), calendar: calendar)
            XCTFail("Incomplete pagination must fail closed")
        } catch {
            XCTAssertEqual(reads, 2)
        }
    }

    func testAccountSwitchKeepsOldAccountDeletionForLaterReconnection() async throws {
        let now = day.addingTimeInterval(10 * 3600)
        let prefs = CozyPreferences(pushTasksToGoogleCalendar: true, googleClientID: "test-client")
        let occurrence = insertOccurrence(title: "Switch account", scheduled: day)
        occurrence.googleCalendarEventId = "old-account-event"
        occurrence.googleSyncedDestination = "google-oauth|old@example.com|primary"
        var deletedIDs: [String] = []
        let service = GoogleCalendarService(
            httpLoader: { request in
                let url = try XCTUnwrap(request.url)
                if request.httpMethod == "DELETE" {
                    deletedIDs.append(url.lastPathComponent)
                    return Self.response(url, status: 204)
                }
                if request.httpMethod == "POST" {
                    let payload = try JSONDecoder().decode(GoogleUpsertEventPayload.self, from: XCTUnwrap(request.httpBody))
                    return Self.response(url, data: try JSONEncoder().encode(Self.event(id: try XCTUnwrap(payload.id), payload: payload)))
                }
                return Self.response(url, data: try JSONEncoder().encode(GoogleEventListResponse(items: [], nextPageToken: nil)))
            },
            initialToken: token(expiringAt: now.addingTimeInterval(86400)),
            now: { now }
        )
        _ = try await service.pushAndMergeOccurrencesToGoogleAPI(occurrences: [occurrence], busyIntervalsByDay: [:], preferences: prefs, today: day, calendar: calendar)
        XCTAssertTrue(deletedIDs.isEmpty)
        XCTAssertEqual(prefs.pendingGoogleDeletions, [.init(accountKey: "old@example.com", calendarID: "primary", eventID: "old-account-event")])
        XCTAssertEqual(occurrence.googleSyncedDestination, "google-oauth|current@example.com|primary")
    }

    func testUnsignedBridgeFallbackPreservesRESTTrackingBeyondItsConfirmedSweep() async throws {
        let prefs = CozyPreferences(pushTasksToGoogleCalendar: true, googleSyncMode: .iosGoogleAccount)
        prefs.needsGoogleOAuthChannelSweep = true
        context.insert(prefs)
        let current = insertOccurrence(title: "Current", scheduled: day)
        let old = insertOccurrence(title: "Outside sweep", scheduled: DateHelpers.addDays(-10, to: day, calendar: calendar))
        let other = insertOccurrence(title: "Other calendar", scheduled: day)
        let backing = FollowupEventStoreBacking()
        backing.calendarList = [
            BackingCalendarInfo(calendarIdentifier: "google-primary", title: "current@example.com", sourceTitle: "Google", allowsContentModifications: true, isDefaultForNewEvents: true),
            BackingCalendarInfo(calendarIdentifier: "google-secondary", title: "Other", sourceTitle: "Google", allowsContentModifications: true, isDefaultForNewEvents: false)
        ]
        for (occurrence, label, calendarID, restCalendarID) in [
            (current, "current", "google-primary", "primary"),
            (old, "old", "google-primary", "primary"),
            (other, "other", "google-secondary", "second-calendar")
        ] {
            occurrence.googleCalendarEventId = "rest-\(label)"
            occurrence.googleSyncedDestination = "google-oauth|current@example.com|\(restCalendarID)"
            let start = occurrence.scheduledDay(calendar: calendar).addingTimeInterval(9 * 3600)
            backing.seed(BackingEventRecord(
                eventIdentifier: "ek-\(label)", calendarIdentifier: calendarID, title: occurrence.displayTitle,
                startDate: start, endDate: start.addingTimeInterval(1800),
                notes: CalendarFreeTimeService.formatCozyMetadataTag(channel: .googleOAuth, occurrenceID: occurrence.id)
            ))
        }
        try context.save()
        let service = GoogleCalendarService(
            httpLoader: { _ in
                XCTFail("Signed-out fallback must not make OAuth requests")
                throw GoogleCalendarError.notSignedIn
            },
            freeTimeService: CalendarFreeTimeService(backing: backing)
        )
        let report = await service.pushOccurrenceChangesWithoutRebalance(context: context, preferences: prefs, referenceDate: day, calendar: calendar)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertNil(backing.committedEvents["ek-current"])
        XCTAssertNotNil(backing.committedEvents["ek-old"])
        XCTAssertNotNil(backing.committedEvents["ek-other"])
        XCTAssertEqual(current.googleCalendarEventId, "rest-current")
        XCTAssertEqual(old.googleCalendarEventId, "rest-old")
        XCTAssertEqual(other.googleCalendarEventId, "rest-other")
        XCTAssertEqual(other.googleSyncedDestination, "google-oauth|current@example.com|second-calendar")
        XCTAssertTrue(prefs.needsGoogleOAuthChannelSweep)
    }

    private func insertOccurrence(title: String, scheduled: Date) -> TaskOccurrence {
        let template = TaskTemplate(title: title, recurrence: .once, isAutoScheduled: false, anchorDate: scheduled, calendar: calendar)
        context.insert(template)
        let occurrence = TaskOccurrence(scheduledDate: scheduled, periodKey: "once:\(template.id.uuidString)", template: template, calendar: calendar)
        context.insert(occurrence)
        return occurrence
    }

    private func token(expiringAt expiry: Date) -> GoogleOAuthToken {
        GoogleOAuthToken(accessToken: "test-token", refreshToken: "test-refresh", expiresAt: expiry, accountSummary: "current@example.com", accountKey: "current@example.com")
    }

    private static func response(_ url: URL, status: Int = 200, data: Data = Data()) -> (Data, URLResponse) {
        (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private static func event(id: String, payload: GoogleUpsertEventPayload) -> GoogleEventDTO {
        GoogleEventDTO(id: id, status: "confirmed", summary: payload.summary, description: payload.description, transparency: "opaque", start: payload.start, end: payload.end, extendedProperties: payload.extendedProperties)
    }
}

@MainActor
private final class GoogleFollowupGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
