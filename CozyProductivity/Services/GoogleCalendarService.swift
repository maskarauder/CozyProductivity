import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import SwiftData
import UIKit

struct GoogleOAuthToken: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var accountSummary: String?
    var accountKey: String?

    var isExpiredOrNearExpiry: Bool {
        Date().addingTimeInterval(60) >= expiresAt
    }
}

struct GoogleEventDateTimeDTO: Codable, Equatable {
    var dateTime: String?
    var date: String?
    var timeZone: String?
}

struct GoogleExtendedPropertiesDTO: Codable, Equatable {
    var privateProperties: [String: String]?

    enum CodingKeys: String, CodingKey {
        case privateProperties = "private"
    }
}

struct GoogleEventDTO: Codable, Equatable {
    var id: String?
    var status: String?
    var summary: String?
    var description: String?
    var transparency: String?
    var start: GoogleEventDateTimeDTO?
    var end: GoogleEventDateTimeDTO?
    var extendedProperties: GoogleExtendedPropertiesDTO?
}

struct GoogleEventListResponse: Codable {
    var items: [GoogleEventDTO]?
    var nextPageToken: String?
}

struct GoogleUpsertEventPayload: Codable, Equatable {
    var id: String? = nil
    var status: String? = nil
    var summary: String
    var description: String
    var start: GoogleEventDateTimeDTO
    var end: GoogleEventDateTimeDTO
    var extendedProperties: GoogleExtendedPropertiesDTO
}

struct CalendarSyncReport {
    let mergedBusyByDay: [Date: Int]
    let upsertedCount: Int
    let removedCount: Int
    let failedCount: Int
    let usedCachedBusySnapshot: Bool
    let statusMessage: String

    init(
        mergedBusyByDay: [Date: Int],
        upsertedCount: Int,
        removedCount: Int,
        failedCount: Int = 0,
        usedCachedBusySnapshot: Bool = false,
        statusMessage: String
    ) {
        self.mergedBusyByDay = mergedBusyByDay
        self.upsertedCount = upsertedCount
        self.removedCount = removedCount
        self.failedCount = failedCount
        self.usedCachedBusySnapshot = usedCachedBusySnapshot
        self.statusMessage = statusMessage
    }
}

enum GoogleCalendarError: LocalizedError {
    case missingClientID
    case invalidAuthURL
    case authenticationCancelled
    case missingAuthorizationCode
    case notSignedIn
    case tokenExchangeFailed(String)
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Enter your Google iOS OAuth Client ID first, or switch to the iPhone Google Account Bridge."
        case .invalidAuthURL:
            return "Could not construct the Google OAuth URL."
        case .authenticationCancelled:
            return "Google sign-in was cancelled."
        case .missingAuthorizationCode:
            return "Google sign-in did not return an authorization code."
        case .notSignedIn:
            return "Connect your Google account in Settings first."
        case .tokenExchangeFailed(let detail):
            return "Google token exchange failed: \(detail)"
        case .apiError(let code, let detail):
            return "Google Calendar API (\(code)): \(detail)"
        }
    }
}

private final class WebAuthPresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return keyWindow
        }
        if let anyWindow = scenes.flatMap(\.windows).first {
            return anyWindow
        }
        return ASPresentationAnchor()
    }
}

@MainActor
@Observable
final class GoogleCalendarService {
    static let shared = GoogleCalendarService()

    private static let tokenKeychainAccount = "google_calendar_oauth_token"
    private static let maxPaginationPages = 50
    private let presentationProvider = WebAuthPresentationAnchorProvider()
    private var activeAuthSession: ASWebAuthenticationSession?

    // Serialized sync coordinator state: prevents concurrent overlapping syncs and coalesces mid-flight edits
    private struct QueuedSyncRequest {
        var includeRebalance: Bool
        var referenceDate: Date
        var calendar: Calendar
    }

    private var isCoordinatorRunning = false
    private var pendingQueuedRequest: QueuedSyncRequest?
    private var queuedWaiters: [CheckedContinuation<CalendarSyncReport, Never>] = []

    private(set) var token: GoogleOAuthToken?
    private(set) var isSyncing: Bool = false
    private(set) var lastSyncedAt: Date?
    var lastSyncStatusMessage: String?

    init() {
        self.token = KeychainHelper.loadCodable(GoogleOAuthToken.self, account: Self.tokenKeychainAccount)
    }

    var isSignedInWithOAuth: Bool {
        token != nil
    }

    var connectedAccountLabel: String {
        token?.accountSummary ?? "Google Account Connected"
    }

    var activeOAuthAccountIdentity: String {
        if let explicitKey = token?.accountKey, !explicitKey.isEmpty {
            return explicitKey
        }
        if let summary = token?.accountSummary, !summary.isEmpty {
            return summary.lowercased()
        }
        return "anonymous-oauth"
    }

    // MARK: - OAuth 2.0 PKCE Sign-In & Sign-Out

    func signOut() {
        token = nil
        KeychainHelper.delete(account: Self.tokenKeychainAccount)
        lastSyncStatusMessage = "Disconnected Google OAuth account."
    }

    func signInWithGoogle(clientID rawClientID: String) async throws {
        let clientID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            throw GoogleCalendarError.missingClientID
        }

        let verifier = Self.makeCodeVerifier()
        let challenge = Self.makeCodeChallenge(for: verifier)
        let callbackScheme = Self.redirectScheme(for: clientID)
        let redirectURI = "\(callbackScheme):/oauth2redirect"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(
                name: "scope",
                value: "https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.readonly"
            ),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let authURL = components?.url else {
            throw GoogleCalendarError.invalidAuthURL
        }

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: GoogleCalendarError.authenticationCancelled)
                }
            }
            session.presentationContextProvider = presentationProvider
            session.prefersEphemeralWebBrowserSession = false
            self.activeAuthSession = session
            if !session.start() {
                self.activeAuthSession = nil
                continuation.resume(throwing: GoogleCalendarError.invalidAuthURL)
            }
        }
        activeAuthSession = nil

        let callbackItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = callbackItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw GoogleCalendarError.missingAuthorizationCode
        }

        var exchangedToken = try await exchangeCodeForToken(
            code: code,
            clientID: clientID,
            redirectURI: redirectURI,
            codeVerifier: verifier
        )

        if let primaryMeta = try? await fetchPrimaryCalendarIdentity(accessToken: exchangedToken.accessToken) {
            if let summary = primaryMeta.summary, !summary.isEmpty {
                exchangedToken.accountSummary = summary
            }
            if let primaryID = primaryMeta.id, !primaryID.isEmpty {
                exchangedToken.accountKey = primaryID.lowercased()
            }
        }

        self.token = exchangedToken
        _ = KeychainHelper.saveCodable(exchangedToken, account: Self.tokenKeychainAccount)
        lastSyncStatusMessage = "Signed in as \(exchangedToken.accountSummary ?? "Google Calendar") 🌸"
    }

    // MARK: - Unified Serialized Sync Coordinator (Google & Apple)

    /// Reads & union-merges busy intervals from Apple Calendar + Google Calendar, rebalances tasks to freer days,
    /// pushes/merges scheduled Cozy Tasks onto Google Calendar and/or Apple Calendar, and refreshes summary notifications.
    func syncCalendarsAndRebalance(
        context: ModelContext,
        preferences: CozyPreferences,
        referenceDate: Date = Date(),
        calendar: Calendar = DateHelpers.calendar
    ) async -> CalendarSyncReport {
        await enqueueCoordinatedSync(
            context: context,
            preferences: preferences,
            referenceDate: referenceDate,
            calendar: calendar,
            includeRebalance: true
        )
    }

    /// Pushes task completion (✅), manual date moves, bonus swaps, or deletions to Google and/or Apple Calendars
    /// without re-running `SmartScheduler.rebalance` so Today's remaining checklist stays untouched.
    func pushOccurrenceChangesWithoutRebalance(
        context: ModelContext,
        preferences: CozyPreferences,
        referenceDate: Date = Date(),
        calendar: Calendar = DateHelpers.calendar
    ) async -> CalendarSyncReport {
        guard preferences.hasAnyCalendarPushEnabled else {
            return CalendarSyncReport(
                mergedBusyByDay: [:],
                upsertedCount: 0,
                removedCount: 0,
                statusMessage: "Calendar task push is turned off."
            )
        }

        return await enqueueCoordinatedSync(
            context: context,
            preferences: preferences,
            referenceDate: referenceDate,
            calendar: calendar,
            includeRebalance: false
        )
    }

    private func enqueueCoordinatedSync(
        context: ModelContext,
        preferences: CozyPreferences,
        referenceDate: Date,
        calendar: Calendar,
        includeRebalance: Bool
    ) async -> CalendarSyncReport {
        if isCoordinatorRunning {
            // Coalesce into a single follow-up pass (upgrading `includeRebalance` if any caller requested rebalance)
            if var existing = pendingQueuedRequest {
                existing.includeRebalance = existing.includeRebalance || includeRebalance
                existing.referenceDate = referenceDate
                existing.calendar = calendar
                pendingQueuedRequest = existing
            } else {
                pendingQueuedRequest = QueuedSyncRequest(
                    includeRebalance: includeRebalance,
                    referenceDate: referenceDate,
                    calendar: calendar
                )
            }
            return await withCheckedContinuation { continuation in
                queuedWaiters.append(continuation)
            }
        }

        isCoordinatorRunning = true
        isSyncing = true

        var latestReport = await executeSingleSyncPass(
            context: context,
            preferences: preferences,
            referenceDate: referenceDate,
            calendar: calendar,
            includeRebalance: includeRebalance
        )

        // Drain any coalesced requests that arrived while `executeSingleSyncPass` was suspended at `await` points
        while let next = pendingQueuedRequest {
            pendingQueuedRequest = nil
            let batchWaiters = queuedWaiters
            queuedWaiters.removeAll()

            latestReport = await executeSingleSyncPass(
                context: context,
                preferences: preferences,
                referenceDate: next.referenceDate,
                calendar: next.calendar,
                includeRebalance: next.includeRebalance
            )

            for waiter in batchWaiters {
                waiter.resume(returning: latestReport)
            }
        }

        isSyncing = false
        isCoordinatorRunning = false
        return latestReport
    }

    private func executeSingleSyncPass(
        context: ModelContext,
        preferences: CozyPreferences,
        referenceDate: Date,
        calendar: Calendar,
        includeRebalance: Bool
    ) async -> CalendarSyncReport {
        let today = DateHelpers.startOfDay(for: referenceDate, calendar: calendar)
        let horizonEnd = DateHelpers.addDays(SmartScheduler.defaultHorizonDays - 1, to: today, calendar: calendar)

        let readResult = await collectMergedBusyIntervals(
            from: today,
            to: horizonEnd,
            preferences: preferences,
            calendar: calendar
        )
        var statusParts = readResult.statusParts

        if includeRebalance {
            if readResult.deferRebalanceDueToReadFailure {
                statusParts.append("Deferred schedule rebalance until calendar busy times can be read")
            } else {
                SmartScheduler.rebalance(
                    context: context,
                    preferences: preferences,
                    calendarBusyByDay: readResult.mergedBusyMinutesByDay,
                    referenceDate: today,
                    calendar: calendar
                )
            }
        }

        let pushResult = await pushOccurrencesToEnabledCalendars(
            context: context,
            combinedIntervalsByDay: readResult.combinedIntervalsByDay,
            preferences: preferences,
            today: today,
            calendar: calendar
        )
        statusParts.append(contentsOf: pushResult.statusParts)

        if includeRebalance {
            let finalOccurrences = (try? context.fetch(FetchDescriptor<TaskOccurrence>())) ?? []
            await NotificationManager.shared.syncSummaryNotifications(
                preferences: preferences,
                occurrences: finalOccurrences,
                calendar: calendar
            )
        }

        try? context.save()

        let defaultMessage = includeRebalance
            ? "Schedule balanced across your free-time budgets 🌸"
            : "Calendars are up to date 🌸"
        let summaryText = statusParts.isEmpty
            ? defaultMessage
            : statusParts.joined(separator: " · ")

        if preferences.hasAnyCalendarIntegrationEnabled || !includeRebalance {
            lastSyncedAt = Date()
            lastSyncStatusMessage = summaryText
        }

        return CalendarSyncReport(
            mergedBusyByDay: readResult.mergedBusyMinutesByDay,
            upsertedCount: pushResult.upsertedCount,
            removedCount: pushResult.removedCount,
            failedCount: pushResult.failedCount,
            usedCachedBusySnapshot: readResult.usedCachedSnapshot,
            statusMessage: summaryText
        )
    }

    private func collectMergedBusyIntervals(
        from today: Date,
        to horizonEnd: Date,
        preferences: CozyPreferences,
        calendar: Calendar
    ) async -> (
        combinedIntervalsByDay: [Date: [(Date, Date)]],
        mergedBusyMinutesByDay: [Date: Int],
        usedCachedSnapshot: Bool,
        deferRebalanceDueToReadFailure: Bool,
        statusParts: [String]
    ) {
        var intervalSources: [[Date: [(Date, Date)]]] = []
        var fallbackMinuteOverlay: [Date: Int] = [:]
        var usedCachedSnapshot = false
        var deferRebalanceDueToReadFailure = false
        var statusParts: [String] = []

        if preferences.useCalendarSync {
            CalendarFreeTimeService.shared.refreshAuthorizationStatus()
            if CalendarFreeTimeService.shared.hasReadAccess {
                let appleIntervals = CalendarFreeTimeService.shared.busyIntervalsByDay(
                    from: today,
                    to: horizonEnd,
                    wakingStartHour: preferences.wakingStartHour,
                    wakingEndHour: preferences.wakingEndHour,
                    calendar: calendar
                )
                intervalSources.append(appleIntervals)
            } else {
                statusParts.append("Apple Calendar read skipped (permission not granted)")
                deferRebalanceDueToReadFailure = true
            }
        }

        if preferences.useGoogleCalendarSync {
            switch preferences.googleSyncMode {
            case .oauthREST:
                let rawCalID = preferences.googleCalendarID.trimmingCharacters(in: .whitespacesAndNewlines)
                let calID = rawCalID.isEmpty ? "primary" : rawCalID
                let destinationKey = Self.makeGoogleDestinationKey(
                    accountKey: activeOAuthAccountIdentity,
                    calendarID: calID
                )
                do {
                    let googleIntervals = try await fetchGoogleBusyIntervalsByDay(
                        from: today,
                        to: horizonEnd,
                        preferences: preferences,
                        calendar: calendar
                    )
                    intervalSources.append(googleIntervals)

                    // Persist fresh last-known-good busy snapshot keyed by destination
                    let minutesMap = CalendarFreeTimeService.mergeBusyIntervalsByDay([googleIntervals])
                    var keyedMinutes: [String: Int] = [:]
                    for (day, mins) in minutesMap {
                        keyedMinutes[DateHelpers.dayKeyString(for: day, calendar: calendar)] = mins
                    }
                    preferences.cachedGoogleBusySnapshot = CozyPreferences.CachedGoogleBusySnapshot(
                        destinationKey: destinationKey,
                        fetchedAt: Date(),
                        busyMinutesByDayKey: keyedMinutes
                    )

                    let busyDayCount = googleIntervals.values.filter { !$0.isEmpty }.count
                    statusParts.append("Read \(busyDayCount) Google busy day\(busyDayCount == 1 ? "" : "s")")
                } catch {
                    if let cached = preferences.cachedGoogleBusySnapshot,
                       cached.destinationKey == destinationKey {
                        for (dayKey, mins) in cached.busyMinutesByDayKey where mins > 0 {
                            if let dayDate = DateHelpers.date(fromDayKey: dayKey, calendar: calendar),
                               dayDate >= today && dayDate <= horizonEnd {
                                fallbackMinuteOverlay[dayDate, default: 0] = max(fallbackMinuteOverlay[dayDate, default: 0], mins)
                            }
                        }
                        usedCachedSnapshot = true
                        statusParts.append("Google read failed (\(error.localizedDescription)); using cached busy snapshot")
                    } else {
                        deferRebalanceDueToReadFailure = true
                        statusParts.append("Google read failed: \(error.localizedDescription)")
                    }
                }

            case .iosGoogleAccount:
                CalendarFreeTimeService.shared.refreshAuthorizationStatus()
                if !CalendarFreeTimeService.shared.hasReadAccess {
                    deferRebalanceDueToReadFailure = true
                    statusParts.append("Grant Calendar Full Access in Settings to read Google Bridge")
                } else {
                    let cals = CalendarFreeTimeService.shared.googleAccountCalendars()
                    if cals.isEmpty {
                        statusParts.append("No Google calendar found in iPhone Accounts yet")
                    } else {
                        let googleBridgeIntervals = CalendarFreeTimeService.shared.googleBridgeBusyIntervalsByDay(
                            from: today,
                            to: horizonEnd,
                            wakingStartHour: preferences.wakingStartHour,
                            wakingEndHour: preferences.wakingEndHour,
                            calendar: calendar
                        )
                        intervalSources.append(googleBridgeIntervals)
                        statusParts.append("Merged \(cals.count) Google calendar\(cals.count == 1 ? "" : "s")")
                    }
                }
            }
        }

        let combinedIntervalsByDay = CalendarFreeTimeService.combineRawIntervalsByDay(intervalSources)
        var mergedBusyMinutesByDay = CalendarFreeTimeService.mergeBusyIntervalsByDay(intervalSources)
        for (day, cachedMins) in fallbackMinuteOverlay {
            mergedBusyMinutesByDay[day] = max(mergedBusyMinutesByDay[day] ?? 0, cachedMins)
        }

        return (
            combinedIntervalsByDay,
            mergedBusyMinutesByDay,
            usedCachedSnapshot,
            deferRebalanceDueToReadFailure,
            statusParts
        )
    }

    private func pushOccurrencesToEnabledCalendars(
        context: ModelContext,
        combinedIntervalsByDay: [Date: [(Date, Date)]],
        preferences: CozyPreferences,
        today: Date,
        calendar: Calendar
    ) async -> (upsertedCount: Int, removedCount: Int, failedCount: Int, statusParts: [String]) {
        var totalUpserted = 0
        var totalRemoved = 0
        var totalFailed = 0
        var statusParts: [String] = []

        let latestOccurrences = (try? context.fetch(FetchDescriptor<TaskOccurrence>())) ?? []
        var googleBridgeCalendarID: String? = nil

        // 1. Push & sync scheduled Cozy Tasks to Google Calendar if enabled
        if preferences.pushTasksToGoogleCalendar {
            switch preferences.googleSyncMode {
            case .oauthREST:
                do {
                    let pushed = try await pushAndMergeOccurrencesToGoogleAPI(
                        occurrences: latestOccurrences,
                        busyIntervalsByDay: combinedIntervalsByDay,
                        preferences: preferences,
                        today: today,
                        calendar: calendar
                    )
                    totalUpserted += pushed.upserted
                    totalRemoved += pushed.removed
                    totalFailed += pushed.failed
                    try? context.save()
                    if pushed.failed > 0 {
                        statusParts.append("Google Calendar synced \(pushed.upserted) task\(pushed.upserted == 1 ? "" : "s") (\(pushed.failed) failed; will retry)")
                    } else {
                        statusParts.append("Synced \(pushed.upserted) task\(pushed.upserted == 1 ? "" : "s") to Google Calendar")
                    }
                } catch {
                    totalFailed += 1
                    statusParts.append(error.localizedDescription)
                }

            case .iosGoogleAccount:
                googleBridgeCalendarID = CalendarFreeTimeService.shared.writableGoogleBridgeCalendar()?.calendarIdentifier
                let pushed = CalendarFreeTimeService.shared.pushAndMergeViaGoogleBridge(
                    occurrences: latestOccurrences,
                    busyIntervalsByDay: combinedIntervalsByDay,
                    preferences: preferences,
                    today: today,
                    calendar: calendar
                )
                totalUpserted += pushed.upserted
                totalRemoved += pushed.removed
                totalFailed += pushed.failed
                try? context.save()
                if let err = pushed.errorMessage {
                    statusParts.append(err)
                } else if let calTitle = pushed.calendarTitle {
                    statusParts.append("Synced \(pushed.upserted) task\(pushed.upserted == 1 ? "" : "s") to \(calTitle)")
                }
            }
        }

        // 2. Push & sync scheduled Cozy Tasks to Apple Calendar if enabled
        if preferences.pushTasksToAppleCalendar {
            let pushedApple = CalendarFreeTimeService.shared.syncOccurrencesToAppleCalendar(
                occurrences: latestOccurrences,
                busyIntervalsByDay: combinedIntervalsByDay,
                preferences: preferences,
                today: today,
                avoidCalendarIdentifier: googleBridgeCalendarID,
                calendar: calendar
            )
            totalUpserted += pushedApple.upserted
            totalRemoved += pushedApple.removed
            totalFailed += pushedApple.failed
            try? context.save()
            if let err = pushedApple.errorMessage {
                statusParts.append(err)
            } else if let appleCalTitle = pushedApple.calendarTitle {
                statusParts.append("Synced \(pushedApple.upserted) task\(pushedApple.upserted == 1 ? "" : "s") to Apple Calendar (\(appleCalTitle))")
            }
        }

        return (totalUpserted, totalRemoved, totalFailed, statusParts)
    }

    // MARK: - Google Calendar REST API v3 Paginated Read & Validated Push

    func fetchGoogleBusyIntervalsByDay(
        from startDate: Date,
        to endDate: Date,
        preferences: CozyPreferences,
        calendar: Calendar = DateHelpers.calendar
    ) async throws -> [Date: [(Date, Date)]] {
        let accessToken = try await validAccessToken(clientID: preferences.googleClientID)
        let firstDay = DateHelpers.startOfDay(for: startDate, calendar: calendar)
        let lastDay = DateHelpers.startOfDay(for: endDate, calendar: calendar)
        let queryEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay.addingTimeInterval(86400)

        let rawCalID = preferences.googleCalendarID.trimmingCharacters(in: .whitespacesAndNewlines)
        let calID = rawCalID.isEmpty ? "primary" : rawCalID
        let encodedCalID = calID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "primary"

        let allEvents = try await fetchAllGoogleEventPages(
            calendarEncodedID: encodedCalID,
            baseQueryItems: [
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "timeMin", value: Self.formatRFC3339(firstDay)),
                URLQueryItem(name: "timeMax", value: Self.formatRFC3339(queryEnd)),
                URLQueryItem(name: "maxResults", value: "2500")
            ],
            accessToken: accessToken
        )

        let rawBusyIntervals = Self.extractBusyIntervals(fromItems: allEvents)
        return CalendarFreeTimeService.clipIntervalsToDays(
            rawIntervals: rawBusyIntervals,
            from: firstDay,
            to: lastDay,
            wakingStartHour: preferences.wakingStartHour,
            wakingEndHour: preferences.wakingEndHour,
            calendar: calendar
        )
    }

    func pushAndMergeOccurrencesToGoogleAPI(
        occurrences: [TaskOccurrence],
        busyIntervalsByDay: [Date: [(Date, Date)]],
        preferences: CozyPreferences,
        today referenceDate: Date = Date(),
        calendar: Calendar = DateHelpers.calendar
    ) async throws -> (upserted: Int, removed: Int, failed: Int) {
        let accessToken = try await validAccessToken(clientID: preferences.googleClientID)
        let today = DateHelpers.startOfDay(for: referenceDate, calendar: calendar)
        let minSyncDay = DateHelpers.addDays(-1, to: today, calendar: calendar)
        let maxSyncDay = DateHelpers.addDays(14, to: today, calendar: calendar)
        let queryEnd = calendar.date(byAdding: .day, value: 1, to: maxSyncDay) ?? maxSyncDay.addingTimeInterval(86400)

        let rawCalID = preferences.googleCalendarID.trimmingCharacters(in: .whitespacesAndNewlines)
        let calID = rawCalID.isEmpty ? "primary" : rawCalID
        let encodedCalID = calID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "primary"
        let accountIdentity = activeOAuthAccountIdentity
        let destinationKey = Self.makeGoogleDestinationKey(accountKey: accountIdentity, calendarID: calID)

        var placedByDay = busyIntervalsByDay
        var upserted = 0
        var removed = 0
        var failed = 0
        var removedRemoteIDs: Set<String> = []

        func effectiveOccurrenceDay(_ occ: TaskOccurrence) -> Date {
            if occ.isCompleted, let bonus = occ.bonusDay(calendar: calendar) {
                return bonus
            }
            return occ.scheduledDay(calendar: calendar)
        }

        // 0. Detect account or destination calendar changes: migrate/invalidate stale mappings!
        for occ in occurrences {
            if let oldDest = occ.googleSyncedDestination, oldDest != destinationKey {
                if let oldID = occ.googleCalendarEventId,
                   let parsedOld = CozyPreferences.parseGoogleDestination(oldDest),
                   parsedOld.accountKey == accountIdentity,
                   parsedOld.calendarID != calID {
                    var pending = preferences.pendingGoogleDeletions
                    pending.append(.init(accountKey: accountIdentity, calendarID: parsedOld.calendarID, eventID: oldID))
                    preferences.pendingGoogleDeletions = pending
                }
                occ.googleCalendarEventId = nil
                occ.googleSyncedDestination = nil
                occ.lastCalendarSyncSignature = nil
            } else if occ.googleSyncedDestination == nil && occ.googleCalendarEventId != nil {
                // Upgrade legacy occurrences without a recorded destination so signature checks include destinationKey
                occ.lastCalendarSyncSignature = nil
            }
        }

        // 1. Drain persisted pending Google deletions (confirming each DELETE before removing from queue!)
        let existingQueue = preferences.pendingGoogleDeletions
        var confirmedPendingDeletions: Set<CozyPreferences.PendingGoogleEventDeletion> = []
        for item in existingQueue where item.accountKey.isEmpty || item.accountKey == accountIdentity {
            let itemEncodedCal = item.calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "primary"
            do {
                try await deleteGoogleEvent(
                    calendarEncodedID: itemEncodedCal,
                    eventID: item.eventID,
                    accessToken: accessToken
                )
                confirmedPendingDeletions.insert(item)
                if item.calendarID == calID {
                    removedRemoteIDs.insert(item.eventID)
                }
                removed += 1
            } catch {
                failed += 1
            }
        }
        if !confirmedPendingDeletions.isEmpty {
            preferences.pendingGoogleDeletions = existingQueue.filter { !confirmedPendingDeletions.contains($0) }
        }

        let activeWindowOccurrences = occurrences
            .filter { occ in
                guard occ.status != .skipped else { return false }
                let day = effectiveOccurrenceDay(occ)
                return day >= minSyncDay && day <= maxSyncDay
            }
            .sorted {
                let d0 = effectiveOccurrenceDay($0)
                let d1 = effectiveOccurrenceDay($1)
                if d0 != d1 { return d0 < d1 }
                if $0.displayTitle != $1.displayTitle { return $0.displayTitle < $1.displayTitle }
                return $0.id.uuidString < $1.id.uuidString
            }

        let activeIDs = Set(activeWindowOccurrences.map(\.id))
        var preferredByOccID: [UUID: String] = [:]
        for occ in activeWindowOccurrences {
            if let existingID = occ.googleCalendarEventId {
                preferredByOccID[occ.id] = existingID
            } else {
                preferredByOccID[occ.id] = Self.deterministicGoogleEventID(occurrenceID: occ.id, destinationKey: destinationKey)
            }
        }

        // 2. Paginated scan of Cozy-managed remote events: deduplicate same-occurrence events & delete orphans!
        //    Note: throws if list request fails so transient network errors never corrupt state.
        let managedEvents = try await fetchCozyManagedGoogleEvents(
            calendarEncodedID: encodedCalID,
            from: minSyncDay,
            to: queryEnd,
            accessToken: accessToken
        )

        let reconciliation = Self.reconcileRemoteManagedEvents(
            managedEvents: managedEvents,
            activeOccurrenceIDs: activeIDs,
            preferredEventIDByOccurrence: preferredByOccID
        )
        let remoteEventIDByOccID = reconciliation.canonicalEventIDByOccurrence

        for duplicateOrOrphanID in reconciliation.eventIDsToDelete where !removedRemoteIDs.contains(duplicateOrOrphanID) {
            do {
                try await deleteGoogleEvent(
                    calendarEncodedID: encodedCalID,
                    eventID: duplicateOrOrphanID,
                    accessToken: accessToken
                )
                removedRemoteIDs.insert(duplicateOrOrphanID)
                removed += 1
            } catch {
                var pending = preferences.pendingGoogleDeletions
                pending.append(.init(accountKey: accountIdentity, calendarID: calID, eventID: duplicateOrOrphanID))
                preferences.pendingGoogleDeletions = pending
                failed += 1
            }
        }

        // 3. Clean up skipped or out-of-window occurrences that still hold a googleCalendarEventId
        //    (NEVER discard `occ.googleCalendarEventId` if `deleteGoogleEvent` fails!)
        for occ in occurrences where !activeIDs.contains(occ.id) {
            guard let existingEventID = occ.googleCalendarEventId, !existingEventID.isEmpty else { continue }
            if removedRemoteIDs.contains(existingEventID) {
                occ.googleCalendarEventId = nil
                occ.googleSyncedDestination = nil
                occ.lastCalendarSyncSignature = nil
                continue
            }
            let targetCal = CozyPreferences.parseGoogleDestination(occ.googleSyncedDestination)?.calendarID ?? calID
            let targetEncodedCal = targetCal.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? encodedCalID
            do {
                try await deleteGoogleEvent(
                    calendarEncodedID: targetEncodedCal,
                    eventID: existingEventID,
                    accessToken: accessToken
                )
                removedRemoteIDs.insert(existingEventID)
                occ.googleCalendarEventId = nil
                occ.googleSyncedDestination = nil
                occ.lastCalendarSyncSignature = nil
                removed += 1
            } catch {
                failed += 1
            }
        }

        // 4. Upsert active occurrences idempotently with full HTTP status verification
        for occ in activeWindowOccurrences {
            let effectiveDay = effectiveOccurrenceDay(occ)
            let slot = CalendarFreeTimeService.assignSlotForTask(
                on: effectiveDay,
                durationMinutes: occ.displayDurationMinutes,
                preferredStartHour: preferences.googleTaskPushStartHour,
                wakingStartHour: preferences.wakingStartHour,
                wakingEndHour: preferences.wakingEndHour,
                existingBusyIntervals: placedByDay[effectiveDay] ?? [],
                calendar: calendar
            )
            placedByDay[effectiveDay, default: []].append(slot)

            let deadlineSuffix = occ.effectiveHardDeadline(calendar: calendar).map {
                " · Hard Deadline \(DateHelpers.shortMonthDayString(for: $0, calendar: calendar))"
            } ?? ""

            var payload = Self.buildEventPayload(
                occurrenceID: occ.id,
                title: occ.displayTitle,
                emoji: occ.displayEmoji,
                notes: occ.displayNotes,
                recurrenceLabel: "\(occ.recurrenceLabel) · \(occ.displayWeight.badgeLabel)\(deadlineSuffix)",
                isCompleted: occ.isCompleted,
                isBonus: occ.bonusForDate != nil,
                start: slot.0,
                end: slot.1,
                timeZoneIdentifier: calendar.timeZone.identifier
            )

            if occ.googleCalendarEventId == nil, let matchedRemoteID = remoteEventIDByOccID[occ.id] {
                occ.googleCalendarEventId = matchedRemoteID
            }

            let signature = Self.buildGoogleSyncSignature(destinationKey: destinationKey, payload: payload)
            if occ.googleCalendarEventId != nil,
               occ.googleSyncedDestination == destinationKey,
               occ.lastCalendarSyncSignature == signature {
                continue
            }

            if let existingEventID = occ.googleCalendarEventId {
                let encodedEventID = existingEventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? existingEventID
                let patchURL = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalID)/events/\(encodedEventID)")!
                var patchPayload = payload
                patchPayload.status = "confirmed"
                let patchBody = try JSONEncoder().encode(patchPayload)

                var patchReq = URLRequest(url: patchURL)
                patchReq.httpMethod = "PATCH"
                patchReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                patchReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                patchReq.httpBody = patchBody

                do {
                    let (_, patchResp) = try await URLSession.shared.data(for: patchReq)
                    if let http = patchResp as? HTTPURLResponse {
                        if (200...299).contains(http.statusCode) {
                            occ.googleSyncedDestination = destinationKey
                            occ.lastCalendarSyncSignature = signature
                            upserted += 1
                            continue
                        } else if http.statusCode == 404 || http.statusCode == 410 {
                            // Deleted remotely; fall through to idempotent POST/PUT creation
                            occ.googleCalendarEventId = nil
                        } else {
                            failed += 1
                            continue
                        }
                    } else {
                        failed += 1
                        continue
                    }
                } catch {
                    failed += 1
                    continue
                }
            }

            if occ.googleCalendarEventId == nil {
                let deterministicID = Self.deterministicGoogleEventID(
                    occurrenceID: occ.id,
                    destinationKey: destinationKey
                )
                payload.id = deterministicID
                payload.status = "confirmed"
                let createBody = try JSONEncoder().encode(payload)

                let postURL = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalID)/events")!
                var postReq = URLRequest(url: postURL)
                postReq.httpMethod = "POST"
                postReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                postReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                postReq.httpBody = createBody

                do {
                    let (postData, postResp) = try await URLSession.shared.data(for: postReq)
                    guard let http = postResp as? HTTPURLResponse else {
                        failed += 1
                        continue
                    }

                    if (200...299).contains(http.statusCode),
                       let created = try? JSONDecoder().decode(GoogleEventDTO.self, from: postData),
                       let createdID = created.id, !createdID.isEmpty {
                        occ.googleCalendarEventId = createdID
                        occ.googleSyncedDestination = destinationKey
                        occ.lastCalendarSyncSignature = signature
                        upserted += 1
                    } else if http.statusCode == 409 {
                        // Deterministic ID already exists (or was cancelled previously): PUT resurrects/updates idempotently!
                        let putURL = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalID)/events/\(deterministicID)")!
                        var putReq = URLRequest(url: putURL)
                        putReq.httpMethod = "PUT"
                        putReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                        putReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        putReq.httpBody = createBody

                        let (_, putResp) = try await URLSession.shared.data(for: putReq)
                        if let putHTTP = putResp as? HTTPURLResponse, (200...299).contains(putHTTP.statusCode) {
                            occ.googleCalendarEventId = deterministicID
                            occ.googleSyncedDestination = destinationKey
                            occ.lastCalendarSyncSignature = signature
                            upserted += 1
                        } else {
                            failed += 1
                        }
                    } else {
                        failed += 1
                    }
                } catch {
                    failed += 1
                }
            }
        }

        return (upserted, removed, failed)
    }

    private func fetchCozyManagedGoogleEvents(
        calendarEncodedID: String,
        from startDate: Date,
        to endDate: Date,
        accessToken: String
    ) async throws -> [(eventID: String, occurrenceID: UUID?)] {
        let items = try await fetchAllGoogleEventPages(
            calendarEncodedID: calendarEncodedID,
            baseQueryItems: [
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "timeMin", value: Self.formatRFC3339(startDate)),
                URLQueryItem(name: "timeMax", value: Self.formatRFC3339(endDate)),
                URLQueryItem(name: "privateExtendedProperty", value: "cozyApp=CozyProductivity"),
                URLQueryItem(name: "maxResults", value: "2500")
            ],
            accessToken: accessToken
        )
        return Self.extractCozyManagedEvents(fromItems: items)
    }

    private func fetchAllGoogleEventPages(
        calendarEncodedID: String,
        baseQueryItems: [URLQueryItem],
        accessToken: String
    ) async throws -> [GoogleEventDTO] {
        var accumulated: [GoogleEventDTO] = []
        var nextPageToken: String? = nil
        var seenTokens: Set<String> = []
        var pageCount = 0

        repeat {
            pageCount += 1
            var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(calendarEncodedID)/events")
            var query = baseQueryItems
            if let token = nextPageToken, !token.isEmpty {
                query.append(URLQueryItem(name: "pageToken", value: token))
            }
            components?.queryItems = query

            guard let url = components?.url else {
                throw GoogleCalendarError.invalidAuthURL
            }

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw GoogleCalendarError.apiError(-1, "Invalid HTTP response")
            }
            guard (200...299).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                throw GoogleCalendarError.apiError(http.statusCode, msg)
            }

            let decoded = try JSONDecoder().decode(GoogleEventListResponse.self, from: data)
            if let pageItems = decoded.items {
                accumulated.append(contentsOf: pageItems)
            }

            if let next = decoded.nextPageToken, !next.isEmpty, !seenTokens.contains(next) {
                seenTokens.insert(next)
                nextPageToken = next
            } else {
                nextPageToken = nil
            }
        } while nextPageToken != nil && pageCount < Self.maxPaginationPages

        return accumulated
    }

    // MARK: - Token Management Helpers

    private func validAccessToken(clientID rawClientID: String) async throws -> String {
        guard var current = token else {
            throw GoogleCalendarError.notSignedIn
        }
        if !current.isExpiredOrNearExpiry {
            return current.accessToken
        }
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw GoogleCalendarError.notSignedIn
        }
        let clientID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            throw GoogleCalendarError.missingClientID
        }

        let refreshed = try await refreshAccessToken(
            refreshToken: refreshToken,
            clientID: clientID,
            existingSummary: current.accountSummary,
            existingAccountKey: current.accountKey
        )
        current = refreshed
        self.token = refreshed
        _ = KeychainHelper.saveCodable(refreshed, account: Self.tokenKeychainAccount)
        return refreshed.accessToken
    }

    private func exchangeCodeForToken(
        code: String,
        clientID: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> GoogleOAuthToken {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [(String, String)] = [
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", codeVerifier),
            ("grant_type", "authorization_code"),
            ("redirect_uri", redirectURI)
        ]
        req.httpBody = Self.formURLEncodedData(params)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown OAuth error"
            throw GoogleCalendarError.tokenExchangeFailed(msg)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        let ttl = TimeInterval(decoded.expires_in ?? 3600)
        return GoogleOAuthToken(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            expiresAt: Date().addingTimeInterval(ttl),
            accountSummary: nil,
            accountKey: UUID().uuidString.lowercased()
        )
    }

    private func refreshAccessToken(
        refreshToken: String,
        clientID: String,
        existingSummary: String?,
        existingAccountKey: String?
    ) async throws -> GoogleOAuthToken {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [(String, String)] = [
            ("client_id", clientID),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token")
        ]
        req.httpBody = Self.formURLEncodedData(params)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Refresh failed"
            throw GoogleCalendarError.tokenExchangeFailed(msg)
        }

        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
        }

        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        let ttl = TimeInterval(decoded.expires_in ?? 3600)
        return GoogleOAuthToken(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token ?? refreshToken,
            expiresAt: Date().addingTimeInterval(ttl),
            accountSummary: existingSummary,
            accountKey: existingAccountKey
        )
    }

    private func fetchPrimaryCalendarIdentity(accessToken: String) async throws -> (id: String?, summary: String?)? {
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        struct CalMeta: Decodable {
            let id: String?
            let summary: String?
        }
        guard let meta = try? JSONDecoder().decode(CalMeta.self, from: data) else {
            return nil
        }
        return (meta.id, meta.summary)
    }

    private func deleteGoogleEvent(
        calendarEncodedID: String,
        eventID: String,
        accessToken: String
    ) async throws {
        let encodedEventID = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventID
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(calendarEncodedID)/events/\(encodedEventID)")!
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleCalendarError.apiError(-1, "Invalid DELETE response")
        }
        guard Self.isConfirmedDeleteStatus(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw GoogleCalendarError.apiError(http.statusCode, detail)
        }
    }

    // MARK: - Pure Testable Helpers (PKCE, Pagination, Deduplication, Signatures & Payload Generation)

    nonisolated static func isConfirmedDeleteStatus(_ statusCode: Int) -> Bool {
        statusCode == 200 || statusCode == 204 || statusCode == 404 || statusCode == 410
    }

    nonisolated static func makeGoogleDestinationKey(accountKey: String, calendarID: String) -> String {
        let cleanAcc = accountKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanCal = calendarID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "google-oauth|\(cleanAcc.isEmpty ? "default" : cleanAcc)|\(cleanCal.isEmpty ? "primary" : cleanCal)"
    }

    nonisolated static func buildGoogleSyncSignature(
        destinationKey: String,
        payload: GoogleUpsertEventPayload
    ) -> String {
        "\(destinationKey)|\(payload.start.dateTime ?? "")|\(payload.end.dateTime ?? "")|\(payload.summary)|\(payload.description)"
    }

    /// Generates a deterministic Google Calendar v3 base32hex-valid ID (`[0-9a-f]` is a strict subset of `[0-9a-v]`)
    /// scoped to `(occurrenceID, destinationKey)` so repeated creates are idempotent.
    nonisolated static func deterministicGoogleEventID(occurrenceID: UUID, destinationKey: String) -> String {
        let input = "\(occurrenceID.uuidString.lowercased())|\(destinationKey)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "c021\(hex)"
    }

    /// Merges multiple raw JSON page responses (validating `nextPageToken` progression) for testable pagination verification.
    nonisolated static func decodePaginatedEventPages(_ rawPages: [Data]) throws -> [GoogleEventDTO] {
        var all: [GoogleEventDTO] = []
        for pageData in rawPages {
            let decoded = try JSONDecoder().decode(GoogleEventListResponse.self, from: pageData)
            if let items = decoded.items {
                all.append(contentsOf: items)
            }
        }
        return all
    }

    /// Reconciles remote Cozy-managed Google events, keeping at most ONE canonical event per active `occurrenceID`
    /// and returning all duplicate and orphan `eventID`s to delete.
    nonisolated static func reconcileRemoteManagedEvents(
        managedEvents: [(eventID: String, occurrenceID: UUID?)],
        activeOccurrenceIDs: Set<UUID>,
        preferredEventIDByOccurrence: [UUID: String]
    ) -> (canonicalEventIDByOccurrence: [UUID: String], eventIDsToDelete: [String]) {
        var groupedByOcc: [UUID: [String]] = [:]
        var toDelete: [String] = []

        for item in managedEvents {
            guard let occID = item.occurrenceID, activeOccurrenceIDs.contains(occID) else {
                toDelete.append(item.eventID)
                continue
            }
            if !groupedByOcc[occID, default: []].contains(item.eventID) {
                groupedByOcc[occID, default: []].append(item.eventID)
            }
        }

        var canonical: [UUID: String] = [:]
        for (occID, eventIDs) in groupedByOcc {
            guard !eventIDs.isEmpty else { continue }
            let chosen: String
            if let pref = preferredEventIDByOccurrence[occID], eventIDs.contains(pref) {
                chosen = pref
            } else {
                chosen = eventIDs[0]
            }
            canonical[occID] = chosen
            for id in eventIDs where id != chosen {
                toDelete.append(id)
            }
        }

        return (canonical, toDelete)
    }

    nonisolated static func redirectScheme(for clientID: String) -> String {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".apps.googleusercontent.com") {
            let parts = trimmed.split(separator: ".").reversed()
            return parts.joined(separator: ".")
        }
        let cleaned = trimmed.replacingOccurrences(of: "://", with: "")
        return cleaned.isEmpty ? "com.cozyproductivity.app" : cleaned
    }

    nonisolated static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for idx in bytes.indices {
            bytes[idx] = UInt8.random(in: 0...255)
        }
        return base64URLEncode(Data(bytes))
    }

    nonisolated static func makeCodeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    nonisolated static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func formatRFC3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    nonisolated static func parseRFC3339(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) {
            return parsed
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    /// Parses a Google Calendar v3 Events list JSON payload into busy `(start, end)` intervals,
    /// filtering out cancelled events, transparent ("Free") events, all-day banners, and CozyProductivity's own pushed tasks.
    nonisolated static func extractBusyIntervals(from responseData: Data) -> [(Date, Date)] {
        guard let decoded = try? JSONDecoder().decode(GoogleEventListResponse.self, from: responseData),
              let items = decoded.items else {
            return []
        }
        return extractBusyIntervals(fromItems: items)
    }

    nonisolated static func extractBusyIntervals(fromItems items: [GoogleEventDTO]) -> [(Date, Date)] {
        var intervals: [(Date, Date)] = []
        for event in items {
            if event.status?.lowercased() == "cancelled" {
                continue
            }
            if event.transparency?.lowercased() == "transparent" {
                continue
            }
            if let priv = event.extendedProperties?.privateProperties {
                if priv["cozyTaskOccurrenceId"] != nil || priv["cozyApp"] == "CozyProductivity" {
                    continue
                }
            }
            if let desc = event.description, desc.contains(CalendarFreeTimeService.cozyEventMarker) {
                continue
            }
            guard
                let startText = event.start?.dateTime,
                let endText = event.end?.dateTime,
                let startDate = parseRFC3339(startText),
                let endDate = parseRFC3339(endText),
                endDate > startDate
            else {
                continue
            }
            intervals.append((startDate, endDate))
        }
        return intervals
    }

    /// Extracts CozyProductivity-managed events `(eventID, occurrenceID)` from a Google Calendar v3 Events list JSON payload.
    nonisolated static func extractCozyManagedEvents(from responseData: Data) -> [(eventID: String, occurrenceID: UUID?)] {
        guard let decoded = try? JSONDecoder().decode(GoogleEventListResponse.self, from: responseData),
              let items = decoded.items else {
            return []
        }
        return extractCozyManagedEvents(fromItems: items)
    }

    nonisolated static func extractCozyManagedEvents(fromItems items: [GoogleEventDTO]) -> [(eventID: String, occurrenceID: UUID?)] {
        var managed: [(eventID: String, occurrenceID: UUID?)] = []
        for event in items {
            if event.status?.lowercased() == "cancelled" {
                continue
            }
            guard let eventID = event.id, !eventID.isEmpty else {
                continue
            }
            let priv = event.extendedProperties?.privateProperties
            // Only manage Google-OAuth channel events (or legacy Cozy Google events)
            if let explicitChannel = priv?["cozyChannel"],
               explicitChannel != CozySyncChannel.googleOAuth.rawValue {
                continue
            }
            if let descChannel = CalendarFreeTimeService.extractCozyChannel(fromURL: nil, notes: event.description),
               descChannel != .googleOAuth {
                continue
            }
            let isCozy = (priv?["cozyApp"] == "CozyProductivity")
                || (priv?["cozyTaskOccurrenceId"] != nil)
                || (event.description?.contains(CalendarFreeTimeService.cozyEventMarker) == true)
            guard isCozy else { continue }

            let occUUID = priv?["cozyTaskOccurrenceId"].flatMap { UUID(uuidString: $0) }
                ?? CalendarFreeTimeService.extractCozyOccurrenceID(fromURL: nil, notes: event.description)
            managed.append((eventID: eventID, occurrenceID: occUUID))
        }
        return managed
    }

    nonisolated static func buildEventPayload(
        occurrenceID: UUID,
        title: String,
        emoji: String,
        notes: String,
        recurrenceLabel: String,
        isCompleted: Bool,
        isBonus: Bool,
        start: Date,
        end: Date,
        timeZoneIdentifier: String
    ) -> GoogleUpsertEventPayload {
        let prefix = isCompleted ? "✅ " : ""
        let bonusTag = isBonus ? " · Bonus" : ""
        let summary = "\(prefix)\(emoji) \(title)"
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesSection = cleanNotes.isEmpty ? "" : "\(cleanNotes)\n\n"
        let metadataTag = CalendarFreeTimeService.formatCozyMetadataTag(
            channel: .googleOAuth,
            occurrenceID: occurrenceID
        )
        let description = "\(notesSection)Scheduled by Cozy (\(recurrenceLabel)\(bonusTag)) \(metadataTag)"

        return GoogleUpsertEventPayload(
            summary: summary,
            description: description,
            start: GoogleEventDateTimeDTO(
                dateTime: formatRFC3339(start),
                date: nil,
                timeZone: timeZoneIdentifier
            ),
            end: GoogleEventDateTimeDTO(
                dateTime: formatRFC3339(end),
                date: nil,
                timeZone: timeZoneIdentifier
            ),
            extendedProperties: GoogleExtendedPropertiesDTO(
                privateProperties: [
                    "cozyTaskOccurrenceId": occurrenceID.uuidString,
                    "cozyChannel": CozySyncChannel.googleOAuth.rawValue,
                    "cozyApp": "CozyProductivity"
                ]
            )
        )
    }

    private nonisolated static func formURLEncodedData(_ pairs: [(String, String)]) -> Data? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        let joined = pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return joined.data(using: .utf8)
    }
}
