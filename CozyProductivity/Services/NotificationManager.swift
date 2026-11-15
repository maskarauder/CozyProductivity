import Foundation
import Observation
import SwiftData
import UserNotifications

private final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

@MainActor
protocol CozyNotificationCenter {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor
private final class SystemCozyNotificationCenter: CozyNotificationCenter {
    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await center.pendingNotificationRequests()
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }
}

@MainActor
@Observable
final class NotificationManager {
    static let shared = NotificationManager()

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let identifierPrefix = "cozy.summary."
    private let foregroundDelegate = ForegroundNotificationDelegate()
    private let notificationCenter: any CozyNotificationCenter

    private struct SummarySyncRequest {
        let preferences: CozyPreferences
        let occurrences: [TaskOccurrence]
        let now: Date
        let calendar: Calendar
    }

    @ObservationIgnored private var isRebuildingSummaries = false
    @ObservationIgnored private var pendingSummarySync: SummarySyncRequest?
    @ObservationIgnored private var summarySyncWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        notificationCenter = SystemCozyNotificationCenter()
        UNUserNotificationCenter.current().delegate = foregroundDelegate
    }

    init(notificationCenter: any CozyNotificationCenter) {
        self.notificationCenter = notificationCenter
    }

    /// Fetches only the bounded occurrence window needed to build daily, weekly, and monthly notification digests.
    static func fetchOccurrencesForSummarySync(
        context: ModelContext,
        now: Date = Date(),
        calendar: Calendar = DateHelpers.calendar
    ) -> [TaskOccurrence] {
        let logicalNow = DateHelpers.logicalDay(for: now, calendar: calendar)
        let monthStart = DateHelpers.monthWindow(containing: logicalNow, calendar: calendar).start
        let weekStart = DateHelpers.weekWindow(containing: logicalNow, calendar: calendar).start
        let earliest = min(monthStart, weekStart)
        let lowerBound = DateHelpers.addDays(-35, to: earliest, calendar: calendar)
        let upperBound = DateHelpers.addDays(60, to: logicalNow, calendar: calendar)

        let windowDescriptor = FetchDescriptor<TaskOccurrence>(
            predicate: #Predicate<TaskOccurrence> { occ in
                occ.scheduledDate >= lowerBound && occ.scheduledDate <= upperBound
            }
        )
        let missingBonusDate = Date.distantPast
        let bonusDescriptor = FetchDescriptor<TaskOccurrence>(
            predicate: #Predicate<TaskOccurrence> { occ in
                (occ.bonusForDate ?? missingBonusDate) >= lowerBound
                    && (occ.bonusForDate ?? missingBonusDate) <= upperBound
            }
        )
        var mergedByID: [UUID: TaskOccurrence] = [:]
        for desc in [windowDescriptor, bonusDescriptor] {
            if let rows = try? context.fetch(desc) {
                for row in rows {
                    mergedByID[row.id] = row
                }
            }
        }
        return Array(mergedByID.values)
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await notificationCenter.authorizationStatus()
    }

    func requestPermissionIfNeeded() async -> Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return false
        }
        await refreshAuthorizationStatus()
        if authorizationStatus == .notDetermined {
            let granted = (try? await notificationCenter.requestAuthorization()) ?? false
            await refreshAuthorizationStatus()
            return granted
        }
        return isAuthorized
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional || authorizationStatus == .ephemeral
    }

    /// Rebuilds all scheduled daily, weekly, and monthly summary notifications so today's / this week's /
    /// this month's notifications always reflect the real tasks completed so far.
    func syncSummaryNotifications(
        preferences: CozyPreferences,
        occurrences: [TaskOccurrence],
        now: Date = Date(),
        calendar: Calendar = DateHelpers.calendar
    ) async {
        // Only one rebuild may write to the center. A newer request replaces the queued
        // snapshot, then runs after the in-flight add has finished, removing its stale result.
        pendingSummarySync = SummarySyncRequest(
            preferences: preferences,
            occurrences: occurrences,
            now: now,
            calendar: calendar
        )
        if isRebuildingSummaries {
            await withCheckedContinuation { continuation in
                summarySyncWaiters.append(continuation)
            }
            return
        }

        isRebuildingSummaries = true
        while let request = pendingSummarySync {
            pendingSummarySync = nil
            await rebuildSummaryNotifications(
                preferences: request.preferences,
                occurrences: request.occurrences,
                now: request.now,
                calendar: request.calendar
            )
        }
        isRebuildingSummaries = false
        let waiters = summarySyncWaiters
        summarySyncWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func rebuildSummaryNotifications(
        preferences: CozyPreferences,
        occurrences: [TaskOccurrence],
        now: Date,
        calendar: Calendar
    ) async {
        await refreshAuthorizationStatus()
        guard pendingSummarySync == nil else { return }

        let anyEnabled = preferences.dailySummaryEnabled
            || preferences.weeklySummaryEnabled
            || preferences.monthlySummaryEnabled

        if anyEnabled && authorizationStatus == .notDetermined {
            _ = await requestPermissionIfNeeded()
            guard pendingSummarySync == nil else { return }
        }

        let pendingRequests = await notificationCenter.pendingNotificationRequests()
        guard pendingSummarySync == nil else { return }
        let cozyIDs = pendingRequests
            .map(\.identifier)
            .filter { $0.hasPrefix(identifierPrefix) }

        if !cozyIDs.isEmpty {
            notificationCenter.removePendingNotificationRequests(withIdentifiers: cozyIDs)
        }

        guard isAuthorized else { return }

        let logicalNow = DateHelpers.logicalDay(for: now, calendar: calendar)

        // 1. End-of-Day Summary Notifications (today with live accomplishments + next 7 days fallback)
        if preferences.dailySummaryEnabled {
            let todayStart = DateHelpers.startOfDay(for: now, calendar: calendar)
            for dayOffset in 0...7 {
                let targetDay = DateHelpers.addDays(dayOffset, to: todayStart, calendar: calendar)
                guard let fireDate = dateAtTime(
                    on: targetDay,
                    hour: preferences.dailySummaryHour,
                    minute: preferences.dailySummaryMinute,
                    calendar: calendar
                ), fireDate > now else {
                    continue
                }

                let targetLogicalDay = DateHelpers.logicalDay(for: fireDate, calendar: calendar)
                let content = UNMutableNotificationContent()
                content.sound = .default

                if targetLogicalDay == logicalNow {
                    let digest = SummaryBuilder.dailyDigest(for: logicalNow, occurrences: occurrences, calendar: calendar)
                    content.title = digest.notificationTitle
                    content.body = digest.notificationBody
                } else {
                    let digest = SummaryBuilder.dailyDigest(for: targetLogicalDay, occurrences: occurrences, calendar: calendar)
                    if digest.completedCount > 0 {
                        content.title = digest.notificationTitle
                        content.body = digest.notificationBody
                    } else {
                        content.title = "Evening Cozy Check-In 🌸"
                        content.body = "Tap to celebrate what you accomplished today and gently rebalance tomorrow's checklist ✨"
                    }
                }

                let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let req = UNNotificationRequest(
                    identifier: "\(identifierPrefix)daily.\(DateHelpers.dayKeyString(for: targetDay, calendar: calendar))",
                    content: content,
                    trigger: trigger
                )
                try? await notificationCenter.add(req)
                guard pendingSummarySync == nil else { return }
            }
        }

        // 2. Optional Weekly Summary Notifications (next 4 occurrences of chosen weekday)
        if preferences.weeklySummaryEnabled {
            let upcomingWeeklyDates = nextMatchingWeekdayDates(
                weekday: preferences.weeklySummaryWeekday,
                hour: preferences.weeklySummaryHour,
                minute: preferences.weeklySummaryMinute,
                after: now,
                count: 4,
                calendar: calendar
            )

            let currentWeekKey = DateHelpers.weekWindow(containing: logicalNow, calendar: calendar).key

            for (index, fireDate) in upcomingWeeklyDates.enumerated() {
                let content = UNMutableNotificationContent()
                content.sound = .default

                let fireLogicalDay = DateHelpers.logicalDay(for: fireDate, calendar: calendar)
                let targetWeekKey = DateHelpers.weekWindow(containing: fireLogicalDay, calendar: calendar).key
                if index == 0 && targetWeekKey == currentWeekKey {
                    let digest = SummaryBuilder.weeklyDigest(containing: logicalNow, occurrences: occurrences, calendar: calendar)
                    content.title = digest.notificationTitle
                    content.body = digest.notificationBody
                } else {
                    content.title = "Weekly Cozy Reflection 🌷"
                    content.body = "Open Cozy to see everything you accomplished this week 💖"
                }

                let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let req = UNNotificationRequest(
                    identifier: "\(identifierPrefix)weekly.\(index)",
                    content: content,
                    trigger: trigger
                )
                try? await notificationCenter.add(req)
                guard pendingSummarySync == nil else { return }
            }
        }

        // 3. Optional Monthly Summary Notifications (next 3 months)
        if preferences.monthlySummaryEnabled {
            let upcomingMonthlyDates = nextMatchingMonthDates(
                dayOfMonth: preferences.monthlySummaryDayOfMonth,
                hour: preferences.monthlySummaryHour,
                minute: preferences.monthlySummaryMinute,
                after: now,
                count: 3,
                calendar: calendar
            )

            let currentMonthKey = DateHelpers.monthWindow(containing: logicalNow, calendar: calendar).key

            for (index, fireDate) in upcomingMonthlyDates.enumerated() {
                let content = UNMutableNotificationContent()
                content.sound = .default

                let fireLogicalDay = DateHelpers.logicalDay(for: fireDate, calendar: calendar)
                let targetMonthKey = DateHelpers.monthWindow(containing: fireLogicalDay, calendar: calendar).key
                if index == 0 && targetMonthKey == currentMonthKey {
                    let digest = SummaryBuilder.monthlyDigest(containing: logicalNow, occurrences: occurrences, calendar: calendar)
                    content.title = digest.notificationTitle
                    content.body = digest.notificationBody
                } else {
                    content.title = "Monthly Cozy Celebration ✨🌸"
                    content.body = "Take a warm moment to look back on every task you completed this month 💕"
                }

                let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let req = UNNotificationRequest(
                    identifier: "\(identifierPrefix)monthly.\(index)",
                    content: content,
                    trigger: trigger
                )
                try? await notificationCenter.add(req)
                guard pendingSummarySync == nil else { return }
            }
        }
    }

    /// Fires a preview notification in `delaySeconds` so users can test Today's Summary immediately on device.
    func sendTestSummaryNotification(occurrences: [TaskOccurrence]) async -> Bool {
        let granted = await requestPermissionIfNeeded()
        guard granted else { return false }

        let digest = SummaryBuilder.dailyDigest(for: DateHelpers.logicalToday(), occurrences: occurrences)
        let content = UNMutableNotificationContent()
        content.title = digest.notificationTitle
        content.body = digest.notificationBody
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        let req = UNNotificationRequest(
            identifier: "\(identifierPrefix)test.\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        do {
            try await notificationCenter.add(req)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Date Computation Helpers

    private func dateAtTime(
        on day: Date,
        hour: Int,
        minute: Int,
        calendar: Calendar
    ) -> Date? {
        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return calendar.date(from: comps)
    }

    private func nextMatchingWeekdayDates(
        weekday: Int,
        hour: Int,
        minute: Int,
        after now: Date,
        count: Int,
        calendar: Calendar
    ) -> [Date] {
        var results: [Date] = []
        let startDay = DateHelpers.startOfDay(for: now, calendar: calendar)
        for dayOffset in 0..<35 where results.count < count {
            let candidateDay = DateHelpers.addDays(dayOffset, to: startDay, calendar: calendar)
            if calendar.component(.weekday, from: candidateDay) == weekday,
               let fireDate = dateAtTime(on: candidateDay, hour: hour, minute: minute, calendar: calendar),
               fireDate > now {
                results.append(fireDate)
            }
        }
        return results
    }

    private func nextMatchingMonthDates(
        dayOfMonth: Int,
        hour: Int,
        minute: Int,
        after now: Date,
        count: Int,
        calendar: Calendar
    ) -> [Date] {
        var results: [Date] = []
        let baseComps = calendar.dateComponents([.year, .month], from: now)
        guard let firstOfThisMonth = calendar.date(from: baseComps) else { return [] }

        for monthOffset in 0..<(count + 2) where results.count < count {
            guard let monthStart = calendar.date(byAdding: .month, value: monthOffset, to: firstOfThisMonth) else {
                continue
            }
            let maxDays = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 28
            let clampedDay = max(1, min(maxDays, dayOfMonth))
            var comps = calendar.dateComponents([.year, .month], from: monthStart)
            comps.day = clampedDay
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            if let candidate = calendar.date(from: comps), candidate > now {
                results.append(candidate)
            }
        }
        return results
    }
}
