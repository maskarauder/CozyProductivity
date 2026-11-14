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
}

struct GoogleUpsertEventPayload: Codable, Equatable {
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
    let statusMessage: String
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
    private let presentationProvider = WebAuthPresentationAnchorProvider()
    private var activeAuthSession: ASWebAuthenticationSession?

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

        if let summary = try? await fetchPrimaryCalendarSummary(accessToken: exchangedToken.accessToken) {
            exchangedToken.accountSummary = summary
        }

        self.token = exchangedToken
        _ = KeychainHelper.saveCodable(exchangedToken, account: Self.tokenKeychainAccount)
        lastSyncStatusMessage = "Signed in as \(exchangedToken.accountSummary ?? "Google Calendar") 🌸"
    }

    // MARK: - Unified Two-Way Calendar Read + SmartScheduler Rebalance + Push/Merge

    /// Reads & union-merges busy intervals from Apple Calendar + Google Calendar, rebalances tasks to freer days,
    /// pushes/merges scheduled Cozy Tasks onto Google Calendar, and refreshes summary notifications.
    func syncCalendarsAndRebalance(
        context: ModelContext,
        preferences: CozyPreferences,
        referenceDate: Date = Date(),
        calendar: Calendar = DateHelpers.calendar
    ) async -> CalendarSyncReport {
        isSyncing = true
        defer { isSyncing = false }

        let today = DateHelpers.startOfDay(for: referenceDate, calendar: calendar)
        let horizonEnd = DateHelpers.addDays(SmartScheduler.defaultHorizonDays - 1, to: today, calendar: calendar)

        var intervalSources: [[Date: [(Date, Date)]]] = []
        var statusParts: [String] = []

        // 1. Read Apple Calendar busy intervals if enabled
        if preferences.useCalendarSync {
            let appleIntervals = CalendarFreeTimeService.shared.busyIntervalsByDay(
                from: today,
                to: horizonEnd,
                wakingStartHour: preferences.wakingStartHour,
                wakingEndHour: preferences.wakingEndHour,
                calendar: calendar
            )
            intervalSources.append(appleIntervals)
        }

        // 2. Read Google Calendar busy intervals if enabled
        if preferences.useGoogleCalendarSync {
            switch preferences.googleSyncMode {
            case .oauthREST:
                do {
                    let googleIntervals = try await fetchGoogleBusyIntervalsByDay(
                        from: today,
                        to: horizonEnd,
                        preferences: preferences,
                        calendar: calendar
                    )
                    intervalSources.append(googleIntervals)
                    let busyDayCount = googleIntervals.values.filter { !$0.isEmpty }.count
                    statusParts.append("Read \(busyDayCount) Google Calendar busy day\(busyDayCount == 1 ? "" : "s")")
                } catch {
                    statusParts.append(error.localizedDescription)
                }

            case .iosGoogleAccount:
                let googleBridgeIntervals = CalendarFreeTimeService.shared.googleBridgeBusyIntervalsByDay(
                    from: today,
                    to: horizonEnd,
                    wakingStartHour: preferences.wakingStartHour,
                    wakingEndHour: preferences.wakingEndHour,
                    calendar: calendar
                )
                intervalSources.append(googleBridgeIntervals)
                let cals = CalendarFreeTimeService.shared.googleAccountCalendars()
                if cals.isEmpty {
                    statusParts.append("No Google calendar found in iPhone Accounts yet")
                } else {
                    statusParts.append("Merged \(cals.count) Google calendar\(cals.count == 1 ? "" : "s")")
                }
            }
        }

        // 3. Union-merge Apple + Google intervals per day so overlapping events are never double-counted
        let combinedIntervalsByDay = CalendarFreeTimeService.combineRawIntervalsByDay(intervalSources)
        let mergedBusyMinutesByDay = CalendarFreeTimeService.mergeBusyIntervalsByDay(intervalSources)

        // 4. Rebalance flexible tasks across freer days using the merged free-time map
        SmartScheduler.rebalance(
            context: context,
            preferences: preferences,
            calendarBusyByDay: mergedBusyMinutesByDay,
            referenceDate: today,
            calendar: calendar
        )

        // 5. Push & merge scheduled CozyProductivity tasks back onto Google Calendar if enabled
        var upsertedCount = 0
        var removedCount = 0

        if preferences.pushTasksToGoogleCalendar {
            let latestOccurrences = (try? context.fetch(FetchDescriptor<TaskOccurrence>())) ?? []
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
                    upsertedCount = pushed.upserted
                    removedCount = pushed.removed
                    try? context.save()
                    statusParts.append("Pushed/merged \(upsertedCount) Cozy task\(upsertedCount == 1 ? "" : "s") to Google Calendar")
                } catch {
                    statusParts.append(error.localizedDescription)
                }

            case .iosGoogleAccount:
                let pushed = CalendarFreeTimeService.shared.pushAndMergeViaGoogleBridge(
                    occurrences: latestOccurrences,
                    busyIntervalsByDay: combinedIntervalsByDay,
                    preferences: preferences,
                    today: today,
                    calendar: calendar
                )
                upsertedCount = pushed.upserted
                removedCount = pushed.removed
                try? context.save()
                if let calTitle = pushed.calendarTitle {
                    statusParts.append("Synced \(upsertedCount) task\(upsertedCount == 1 ? "" : "s") to \(calTitle)")
                } else {
                    statusParts.append("Grant Calendar Full Access in Settings to push tasks")
                }
            }
        }

        // 6. Refresh summary notifications
        let finalOccurrences = (try? context.fetch(FetchDescriptor<TaskOccurrence>())) ?? []
        await NotificationManager.shared.syncSummaryNotifications(
            preferences: preferences,
            occurrences: finalOccurrences
        )

        let summaryText = statusParts.isEmpty
            ? "Schedule balanced across your free-time budgets 🌸"
            : statusParts.joined(separator: " · ")

        if preferences.useGoogleCalendarSync || preferences.pushTasksToGoogleCalendar {
            lastSyncedAt = Date()
            lastSyncStatusMessage = summaryText
        }

        return CalendarSyncReport(
            mergedBusyByDay: mergedBusyMinutesByDay,
            upsertedCount: upsertedCount,
            removedCount: removedCount,
            statusMessage: summaryText
        )
    }

    // MARK: - Google Calendar REST API v3 Read & Push

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

        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalID)/events")
        components?.queryItems = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "timeMin", value: Self.formatRFC3339(firstDay)),
            URLQueryItem(name: "timeMax", value: Self.formatRFC3339(queryEnd)),
            URLQueryItem(name: "maxResults", value: "2500")
        ]

        guard let url = components?.url else {
            throw GoogleCalendarError.invalidAuthURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleCalendarError.apiError(-1, "Invalid HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw GoogleCalendarError.apiError(http.statusCode, msg)
        }

        let rawBusyIntervals = Self.extractBusyIntervals(from: data)
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
    ) async throws -> (upserted: Int, removed: Int) {
        let accessToken = try await validAccessToken(clientID: preferences.googleClientID)
        let today = DateHelpers.startOfDay(for: referenceDate, calendar: calendar)
        let minSyncDay = DateHelpers.addDays(-1, to: today, calendar: calendar)
        let maxSyncDay = DateHelpers.addDays(14, to: today, calendar: calendar)

        let rawCalID = preferences.googleCalendarID.trimmingCharacters(in: .whitespacesAndNewlines)
        let calID = rawCalID.isEmpty ? "primary" : rawCalID
        let encodedCalID = calID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "primary"

        var placedByDay = busyIntervalsByDay
        var upserted = 0
        var removed = 0

        let sorted = occurrences.sorted {
            if $0.scheduledDate != $1.scheduledDate {
                return $0.scheduledDate < $1.scheduledDate
            }
            return $0.displayTitle < $1.displayTitle
        }

        for occ in sorted {
            if occ.status == .skipped {
                if let existingEventID = occ.googleCalendarEventId {
                    try? await deleteGoogleEvent(
                        calendarEncodedID: encodedCalID,
                        eventID: existingEventID,
                        accessToken: accessToken
                    )
                    occ.googleCalendarEventId = nil
                    occ.lastCalendarSyncSignature = nil
                    removed += 1
                }
                continue
            }

            let effectiveDay = DateHelpers.startOfDay(
                for: occ.isCompleted ? (occ.bonusForDate ?? occ.scheduledDate) : occ.scheduledDate,
                calendar: calendar
            )
            guard effectiveDay >= minSyncDay && effectiveDay <= maxSyncDay else {
                continue
            }

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

            let payload = Self.buildEventPayload(
                occurrenceID: occ.id,
                title: occ.displayTitle,
                emoji: occ.displayEmoji,
                notes: occ.displayNotes,
                recurrenceLabel: occ.recurrenceLabel,
                isCompleted: occ.isCompleted,
                isBonus: occ.bonusForDate != nil,
                start: slot.0,
                end: slot.1,
                timeZoneIdentifier: calendar.timeZone.identifier
            )

            let signature = "\(payload.start.dateTime ?? "")|\(payload.end.dateTime ?? "")|\(payload.summary)"
            if occ.googleCalendarEventId != nil && occ.lastCalendarSyncSignature == signature {
                continue
            }

            let bodyData = try JSONEncoder().encode(payload)

            if let existingEventID = occ.googleCalendarEventId {
                let encodedEventID = existingEventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? existingEventID
                let patchURL = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalID)/events/\(encodedEventID)")!
                var patchReq = URLRequest(url: patchURL)
                patchReq.httpMethod = "PATCH"
                patchReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                patchReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                patchReq.httpBody = bodyData

                let (_, patchResp) = try await URLSession.shared.data(for: patchReq)
                if let http = patchResp as? HTTPURLResponse {
                    if (200...299).contains(http.statusCode) {
                        occ.lastCalendarSyncSignature = signature
                        upserted += 1
                        continue
                    } else if http.statusCode == 404 || http.statusCode == 410 {
                        // Event was deleted on Google Calendar; recreate cleanly below
                        occ.googleCalendarEventId = nil
                    }
                }
            }

            if occ.googleCalendarEventId == nil {
                let postURL = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalID)/events")!
                var postReq = URLRequest(url: postURL)
                postReq.httpMethod = "POST"
                postReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                postReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                postReq.httpBody = bodyData

                let (postData, postResp) = try await URLSession.shared.data(for: postReq)
                if let http = postResp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let created = try? JSONDecoder().decode(GoogleEventDTO.self, from: postData),
                   let createdID = created.id {
                    occ.googleCalendarEventId = createdID
                    occ.lastCalendarSyncSignature = signature
                    upserted += 1
                }
            }
        }

        return (upserted, removed)
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
            existingSummary: current.accountSummary
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
            accountSummary: nil
        )
    }

    private func refreshAccessToken(
        refreshToken: String,
        clientID: String,
        existingSummary: String?
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
            accountSummary: existingSummary
        )
    }

    private func fetchPrimaryCalendarSummary(accessToken: String) async throws -> String? {
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        struct CalMeta: Decodable {
            let summary: String?
        }
        return try? JSONDecoder().decode(CalMeta.self, from: data).summary
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
        _ = try await URLSession.shared.data(for: req)
    }

    // MARK: - Pure Testable Helpers (PKCE, RFC3339, Event Filtering & Payload Generation)

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
        let description = "\(notesSection)Scheduled by Cozy Tasks (\(recurrenceLabel)\(bonusTag)) \(CalendarFreeTimeService.cozyEventMarker)"

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
