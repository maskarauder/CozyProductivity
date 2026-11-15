import XCTest
@testable import CozyProductivity

@MainActor
final class SettingsFollowupTests: XCTestCase {
    func testDisablingLastApplePushQueuesCleanupWithoutBusyReadsOrAutoSync() {
        let preferences = CozyPreferences(
            useCalendarSync: false,
            useGoogleCalendarSync: false,
            pushTasksToAppleCalendar: true,
            autoSyncCalendarChanges: false
        )

        preferences.setAppleTaskPushEnabled(false)

        XCTAssertFalse(preferences.hasAnyCalendarPushEnabled)
        XCTAssertFalse(preferences.hasAnyCalendarBusySyncEnabled)
        XCTAssertTrue(preferences.needsAppleChannelSweep)
        XCTAssertTrue(preferences.hasPendingCalendarCleanup)
    }

    func testDisablingGooglePushQueuesCleanupForItsConnectionMode() {
        for mode in GoogleCalendarSyncMode.allCases {
            let preferences = CozyPreferences(
                useGoogleCalendarSync: false,
                pushTasksToGoogleCalendar: true,
                googleSyncMode: mode
            )

            preferences.setGoogleTaskPushEnabled(false)

            XCTAssertFalse(preferences.pushTasksToGoogleCalendar)
            XCTAssertTrue(preferences.hasPendingCalendarCleanup)
            XCTAssertEqual(preferences.needsGoogleOAuthChannelSweep, mode == .oauthREST)
            XCTAssertEqual(preferences.needsGoogleBridgeChannelSweep, mode == .iosGoogleAccount)
        }
    }

    func testReenablingPushDoesNotDiscardQueuedCleanup() {
        let preferences = CozyPreferences(pushTasksToGoogleCalendar: true, pushTasksToAppleCalendar: true)
        preferences.setAppleTaskPushEnabled(false)
        preferences.setGoogleTaskPushEnabled(false)
        preferences.setAppleTaskPushEnabled(true)
        preferences.setGoogleTaskPushEnabled(true)

        XCTAssertTrue(preferences.hasAnyCalendarPushEnabled)
        XCTAssertTrue(preferences.needsAppleChannelSweep)
        XCTAssertTrue(preferences.needsGoogleOAuthChannelSweep)
    }
}
