import Foundation
import SwiftData

@Model
final class CozyPreferences {
    var id: UUID

    // MARK: - Default Free-Time Budgets per Weekday (in minutes)
    var sundayBudgetMinutes: Int
    var mondayBudgetMinutes: Int
    var tuesdayBudgetMinutes: Int
    var wednesdayBudgetMinutes: Int
    var thursdayBudgetMinutes: Int
    var fridayBudgetMinutes: Int
    var saturdayBudgetMinutes: Int

    // MARK: - Optional Apple Calendar Integration
    var useCalendarSync: Bool
    var calendarDeductionModeRaw: String
    var wakingStartHour: Int
    var wakingEndHour: Int

    // MARK: - Summary Notifications
    var dailySummaryEnabled: Bool
    var dailySummaryHour: Int
    var dailySummaryMinute: Int

    var weeklySummaryEnabled: Bool
    /// 1 = Sunday ... 7 = Saturday (matches Calendar.Component.weekday)
    var weeklySummaryWeekday: Int
    var weeklySummaryHour: Int
    var weeklySummaryMinute: Int

    var monthlySummaryEnabled: Bool
    /// 1 ... 28 so it fires reliably every month including February
    var monthlySummaryDayOfMonth: Int
    var monthlySummaryHour: Int
    var monthlySummaryMinute: Int

    var hasSeededStarterTasks: Bool

    // MARK: - Streaks & Calendar Highlight Style
    var longestRecordedStreak: Int = 0
    var baseHighlightStyleRaw: String = BaseHighlightColorStyle.roseBronze.rawValue

    // MARK: - Two-Way Google & Apple Calendar Sync
    var useGoogleCalendarSync: Bool = false
    var pushTasksToGoogleCalendar: Bool = false
    var pushTasksToAppleCalendar: Bool = false
    var appleTargetCalendarIdentifier: String = ""
    var autoSyncCalendarChanges: Bool = true
    var googleSyncModeRaw: String = GoogleCalendarSyncMode.oauthREST.rawValue
    var googleClientID: String = ""
    var googleCalendarID: String = "primary"
    var googleTaskPushStartHour: Int = 18

    // MARK: - Daily Cup Check-In (0...5 Hours, Resetting at 4:00 AM)
    var dailyCupPromptEnabled: Bool = true
    var lastCupCheckInDayKey: String = ""
    var todayCupHours: Int = 3

    // MARK: - Optional Gamification & ADD Friendly Mode
    var streaksEnabled: Bool = true
    var optionalBonusTasksEnabled: Bool = true
    var dayRanksEnabled: Bool = true
    var confettiEnabled: Bool = true
    var addFriendlyMode: Bool = false

    // MARK: - Durable Sync Queue, Busy Cache, Mode Migration & Historical Streak Archive
    var pendingGoogleDeletionsJSON: String = "[]"
    var pendingEKDeletionsJSON: String = "[]"
    var cachedGoogleBusySnapshotJSON: String = ""
    var historicalStreakArchiveJSON: String = ""
    var appliedDataMigrationVersion: Int = 0
    var needsGoogleOAuthChannelSweep: Bool = false
    var needsGoogleBridgeChannelSweep: Bool = false
    var needsAppleChannelSweep: Bool = false

    init(
        id: UUID = UUID(),
        sundayBudgetMinutes: Int = 180,
        mondayBudgetMinutes: Int = 90,
        tuesdayBudgetMinutes: Int = 90,
        wednesdayBudgetMinutes: Int = 90,
        thursdayBudgetMinutes: Int = 90,
        fridayBudgetMinutes: Int = 105,
        saturdayBudgetMinutes: Int = 180,
        useCalendarSync: Bool = false,
        calendarDeductionMode: CalendarDeductionMode = .subtractFromBudget,
        wakingStartHour: Int = 8,
        wakingEndHour: Int = 21,
        dailySummaryEnabled: Bool = true,
        dailySummaryHour: Int = 20,
        dailySummaryMinute: Int = 30,
        weeklySummaryEnabled: Bool = true,
        weeklySummaryWeekday: Int = 1, // Sunday evening
        weeklySummaryHour: Int = 20,
        weeklySummaryMinute: Int = 0,
        monthlySummaryEnabled: Bool = false,
        monthlySummaryDayOfMonth: Int = 28,
        monthlySummaryHour: Int = 20,
        monthlySummaryMinute: Int = 0,
        hasSeededStarterTasks: Bool = false,
        longestRecordedStreak: Int = 0,
        baseHighlightStyle: BaseHighlightColorStyle = .roseBronze,
        useGoogleCalendarSync: Bool = false,
        pushTasksToGoogleCalendar: Bool = false,
        pushTasksToAppleCalendar: Bool = false,
        appleTargetCalendarIdentifier: String = "",
        autoSyncCalendarChanges: Bool = true,
        googleSyncMode: GoogleCalendarSyncMode = .oauthREST,
        googleClientID: String = "",
        googleCalendarID: String = "primary",
        googleTaskPushStartHour: Int = 18,
        dailyCupPromptEnabled: Bool = true,
        lastCupCheckInDayKey: String = "",
        todayCupHours: Int = 3,
        streaksEnabled: Bool = true,
        optionalBonusTasksEnabled: Bool = true,
        dayRanksEnabled: Bool = true,
        confettiEnabled: Bool = true,
        addFriendlyMode: Bool = false
    ) {
        self.id = id
        self.sundayBudgetMinutes = sundayBudgetMinutes
        self.mondayBudgetMinutes = mondayBudgetMinutes
        self.tuesdayBudgetMinutes = tuesdayBudgetMinutes
        self.wednesdayBudgetMinutes = wednesdayBudgetMinutes
        self.thursdayBudgetMinutes = thursdayBudgetMinutes
        self.fridayBudgetMinutes = fridayBudgetMinutes
        self.saturdayBudgetMinutes = saturdayBudgetMinutes
        self.useCalendarSync = useCalendarSync
        self.calendarDeductionModeRaw = calendarDeductionMode.rawValue
        self.wakingStartHour = wakingStartHour
        self.wakingEndHour = wakingEndHour
        self.dailySummaryEnabled = dailySummaryEnabled
        self.dailySummaryHour = dailySummaryHour
        self.dailySummaryMinute = dailySummaryMinute
        self.weeklySummaryEnabled = weeklySummaryEnabled
        self.weeklySummaryWeekday = weeklySummaryWeekday
        self.weeklySummaryHour = weeklySummaryHour
        self.weeklySummaryMinute = weeklySummaryMinute
        self.monthlySummaryEnabled = monthlySummaryEnabled
        self.monthlySummaryDayOfMonth = monthlySummaryDayOfMonth
        self.monthlySummaryHour = monthlySummaryHour
        self.monthlySummaryMinute = monthlySummaryMinute
        self.hasSeededStarterTasks = hasSeededStarterTasks
        self.longestRecordedStreak = longestRecordedStreak
        self.baseHighlightStyleRaw = baseHighlightStyle.rawValue
        self.useGoogleCalendarSync = useGoogleCalendarSync
        self.pushTasksToGoogleCalendar = pushTasksToGoogleCalendar
        self.pushTasksToAppleCalendar = pushTasksToAppleCalendar
        self.appleTargetCalendarIdentifier = appleTargetCalendarIdentifier
        self.autoSyncCalendarChanges = autoSyncCalendarChanges
        self.googleSyncModeRaw = googleSyncMode.rawValue
        self.googleClientID = googleClientID
        self.googleCalendarID = googleCalendarID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "primary" : googleCalendarID
        self.googleTaskPushStartHour = max(6, min(22, googleTaskPushStartHour))
        self.dailyCupPromptEnabled = dailyCupPromptEnabled
        self.lastCupCheckInDayKey = lastCupCheckInDayKey
        self.todayCupHours = max(0, min(5, todayCupHours))
        self.streaksEnabled = streaksEnabled
        self.optionalBonusTasksEnabled = optionalBonusTasksEnabled
        self.dayRanksEnabled = dayRanksEnabled
        self.confettiEnabled = confettiEnabled
        self.addFriendlyMode = addFriendlyMode
    }

    var calendarDeductionMode: CalendarDeductionMode {
        get { CalendarDeductionMode(rawValue: calendarDeductionModeRaw) ?? .subtractFromBudget }
        set { calendarDeductionModeRaw = newValue.rawValue }
    }

    var baseHighlightStyle: BaseHighlightColorStyle {
        get { BaseHighlightColorStyle(rawValue: baseHighlightStyleRaw) ?? .roseBronze }
        set { baseHighlightStyleRaw = newValue.rawValue }
    }

    var googleSyncMode: GoogleCalendarSyncMode {
        get { GoogleCalendarSyncMode(rawValue: googleSyncModeRaw) ?? .oauthREST }
        set {
            let previous = GoogleCalendarSyncMode(rawValue: googleSyncModeRaw) ?? .oauthREST
            if previous != newValue {
                switch previous {
                case .oauthREST:
                    needsGoogleOAuthChannelSweep = true
                case .iosGoogleAccount:
                    needsGoogleBridgeChannelSweep = true
                }
            }
            googleSyncModeRaw = newValue.rawValue
        }
    }

    /// True when any queued remote calendar deletion or inactive-channel sweep still needs to execute.
    var hasPendingCalendarCleanup: Bool {
        needsGoogleOAuthChannelSweep
            || needsGoogleBridgeChannelSweep
            || needsAppleChannelSweep
            || !pendingGoogleDeletions.isEmpty
            || !pendingEKDeletions.isEmpty
    }

    /// Every Settings entry point uses these setters so disabling push always retires its events.
    func setAppleTaskPushEnabled(_ enabled: Bool) {
        if !enabled && pushTasksToAppleCalendar {
            needsAppleChannelSweep = true
        }
        pushTasksToAppleCalendar = enabled
    }

    func setGoogleTaskPushEnabled(_ enabled: Bool) {
        if !enabled && pushTasksToGoogleCalendar {
            switch googleSyncMode {
            case .oauthREST: needsGoogleOAuthChannelSweep = true
            case .iosGoogleAccount: needsGoogleBridgeChannelSweep = true
            }
        }
        pushTasksToGoogleCalendar = enabled
    }

    /// True whenever Apple Calendar busy sync or Google Calendar busy sync is active.
    var hasAnyCalendarBusySyncEnabled: Bool {
        useCalendarSync || useGoogleCalendarSync
    }

    /// True whenever Cozy is configured to push/sync scheduled tasks onto Google and/or Apple Calendar.
    var hasAnyCalendarPushEnabled: Bool {
        pushTasksToGoogleCalendar || pushTasksToAppleCalendar
    }

    /// True whenever any Google or Apple Calendar read, push, or pending cleanup integration is enabled.
    var hasAnyCalendarIntegrationEnabled: Bool {
        useCalendarSync || pushTasksToAppleCalendar || useGoogleCalendarSync || pushTasksToGoogleCalendar || hasPendingCalendarCleanup
    }

    /// True when task/schedule changes should automatically sync to enabled Google and/or Apple Calendars.
    var shouldAutoSyncCalendarsOnChange: Bool {
        autoSyncCalendarChanges && hasAnyCalendarIntegrationEnabled
    }

    func setDailyCupPromptEnabled(_ enabled: Bool) {
        dailyCupPromptEnabled = enabled
        if !enabled {
            lastCupCheckInDayKey = ""
        }
    }

    func hasCupCheckIn(for day: Date, calendar: Calendar = DateHelpers.calendar) -> Bool {
        lastCupCheckInDayKey == DateHelpers.dayKeyString(for: day, calendar: calendar)
    }

    func needsCupCheckIn(for day: Date, calendar: Calendar = DateHelpers.calendar) -> Bool {
        guard dailyCupPromptEnabled else { return false }
        return !hasCupCheckIn(for: day, calendar: calendar)
    }

    func cupHours(for day: Date, calendar: Calendar = DateHelpers.calendar) -> Int? {
        guard hasCupCheckIn(for: day, calendar: calendar) else { return nil }
        return max(0, min(5, todayCupHours))
    }

    func recordCupCheckIn(hours: Int, for day: Date, calendar: Calendar = DateHelpers.calendar) {
        todayCupHours = max(0, min(5, hours))
        lastCupCheckInDayKey = DateHelpers.dayKeyString(for: day, calendar: calendar)
    }

    /// Weekday is 1 (Sunday) ... 7 (Saturday) in Gregorian Calendar.
    func baseBudgetMinutes(forWeekday weekday: Int) -> Int {
        switch weekday {
        case 1: return sundayBudgetMinutes
        case 2: return mondayBudgetMinutes
        case 3: return tuesdayBudgetMinutes
        case 4: return wednesdayBudgetMinutes
        case 5: return thursdayBudgetMinutes
        case 6: return fridayBudgetMinutes
        case 7: return saturdayBudgetMinutes
        default: return 90
        }
    }

    func setBaseBudgetMinutes(_ minutes: Int, forWeekday weekday: Int) {
        let clamped = max(0, min(720, minutes))
        switch weekday {
        case 1: sundayBudgetMinutes = clamped
        case 2: mondayBudgetMinutes = clamped
        case 3: tuesdayBudgetMinutes = clamped
        case 4: wednesdayBudgetMinutes = clamped
        case 5: thursdayBudgetMinutes = clamped
        case 6: fridayBudgetMinutes = clamped
        case 7: saturdayBudgetMinutes = clamped
        default: break
        }
    }

    // MARK: - Pending Calendar Deletions, Busy Snapshot & Streak Archive Helpers

    struct PendingGoogleEventDeletion: Codable, Equatable, Hashable {
        let accountKey: String
        let calendarID: String
        let eventID: String
    }

    struct PendingEKEventDeletion: Codable, Equatable, Hashable {
        let channelRaw: String
        let eventIdentifier: String
    }

    struct CachedBusyInterval: Codable, Equatable, Hashable {
        let start: Date
        let end: Date
    }

    struct CachedGoogleBusySnapshot: Codable, Equatable {
        let destinationKey: String
        let fetchedAt: Date
        let busyMinutesByDayKey: [String: Int]
        let busyIntervalsByDayKey: [String: [CachedBusyInterval]]
        let hasCompleteIntervals: Bool

        init(
            destinationKey: String,
            fetchedAt: Date,
            busyMinutesByDayKey: [String: Int],
            busyIntervalsByDayKey: [String: [CachedBusyInterval]] = [:],
            hasCompleteIntervals: Bool = true
        ) {
            self.destinationKey = destinationKey
            self.fetchedAt = fetchedAt
            self.busyMinutesByDayKey = busyMinutesByDayKey
            self.busyIntervalsByDayKey = busyIntervalsByDayKey
            self.hasCompleteIntervals = hasCompleteIntervals
        }

        enum CodingKeys: String, CodingKey {
            case destinationKey
            case fetchedAt
            case busyMinutesByDayKey
            case busyIntervalsByDayKey
            case hasCompleteIntervals
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.destinationKey = try container.decode(String.self, forKey: .destinationKey)
            self.fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
            self.busyMinutesByDayKey = (try? container.decode([String: Int].self, forKey: .busyMinutesByDayKey)) ?? [:]
            self.busyIntervalsByDayKey = (try? container.decodeIfPresent([String: [CachedBusyInterval]].self, forKey: .busyIntervalsByDayKey)) ?? [:]
            self.hasCompleteIntervals = (try? container.decodeIfPresent(Bool.self, forKey: .hasCompleteIntervals)) ?? false
        }

        static func make(
            destinationKey: String,
            fetchedAt: Date = Date(),
            intervalsByDay: [Date: [(Date, Date)]],
            calendar: Calendar
        ) -> CachedGoogleBusySnapshot {
            let minutesMap = CalendarFreeTimeService.mergeBusyIntervalsByDay([intervalsByDay])
            var keyedMinutes: [String: Int] = [:]
            for (day, mins) in minutesMap {
                keyedMinutes[DateHelpers.dayKeyString(for: day, calendar: calendar)] = mins
            }

            var keyedIntervals: [String: [CachedBusyInterval]] = [:]
            for (day, pairs) in intervalsByDay where !pairs.isEmpty {
                let dayKey = DateHelpers.dayKeyString(for: day, calendar: calendar)
                keyedIntervals[dayKey] = pairs
                    .filter { $0.1 > $0.0 }
                    .map { CachedBusyInterval(start: $0.0, end: $0.1) }
            }

            return CachedGoogleBusySnapshot(
                destinationKey: destinationKey,
                fetchedAt: fetchedAt,
                busyMinutesByDayKey: keyedMinutes,
                busyIntervalsByDayKey: keyedIntervals,
                hasCompleteIntervals: true
            )
        }

        func isFresh(
            forDestination expectedDestinationKey: String,
            maxAgeSeconds: TimeInterval,
            now: Date = Date()
        ) -> Bool {
            guard destinationKey == expectedDestinationKey, hasCompleteIntervals else {
                return false
            }
            let age = now.timeIntervalSince(fetchedAt)
            return age >= -300 && age <= maxAgeSeconds
        }

        func freshIntervalsByDay(
            forDestination expectedDestinationKey: String,
            maxAgeSeconds: TimeInterval,
            now: Date = Date(),
            calendar: Calendar = DateHelpers.calendar
        ) -> [Date: [(Date, Date)]]? {
            guard isFresh(forDestination: expectedDestinationKey, maxAgeSeconds: maxAgeSeconds, now: now) else {
                return nil
            }
            var reconstructed: [Date: [(Date, Date)]] = [:]
            for (dayKey, items) in busyIntervalsByDayKey {
                guard let day = DateHelpers.date(fromDayKey: dayKey, calendar: calendar) else { continue }
                let valid = items.compactMap { item -> (Date, Date)? in
                    guard item.end > item.start else { return nil }
                    return (item.start, item.end)
                }
                if !valid.isEmpty {
                    reconstructed[day] = valid
                }
            }
            return reconstructed
        }
    }

    struct HistoricalStreakArchive: Codable, Equatable {
        let archivedThroughDayKey: String
        let streakEnteringNextDay: Int
        let longestStreakThroughArchive: Int
        let archivedGoldDays: Int
        let archivedSilverDays: Int
        let archivedBaseDays: Int
        let optionalBonusTasksEnabled: Bool
    }

    var pendingGoogleDeletions: [PendingGoogleEventDeletion] {
        get {
            guard let data = pendingGoogleDeletionsJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([PendingGoogleEventDeletion].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            var seen: Set<PendingGoogleEventDeletion> = []
            let unique = newValue.filter { seen.insert($0).inserted }
            if let data = try? JSONEncoder().encode(unique),
               let json = String(data: data, encoding: .utf8) {
                pendingGoogleDeletionsJSON = json
            }
        }
    }

    var pendingEKDeletions: [PendingEKEventDeletion] {
        get {
            guard let data = pendingEKDeletionsJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([PendingEKEventDeletion].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            var seen: Set<PendingEKEventDeletion> = []
            let unique = newValue.filter { seen.insert($0).inserted }
            if let data = try? JSONEncoder().encode(unique),
               let json = String(data: data, encoding: .utf8) {
                pendingEKDeletionsJSON = json
            }
        }
    }

    /// Enqueues a Google deletion without clobbering concurrent queue items.
    func enqueueGoogleDeletion(_ item: PendingGoogleEventDeletion) {
        guard !item.eventID.isEmpty else { return }
        var current = pendingGoogleDeletions
        if !current.contains(item) {
            current.append(item)
            pendingGoogleDeletions = current
        }
    }

    /// Removes only confirmed deletions from the live `pendingGoogleDeletions` queue, preserving any requests enqueued during async `await`s.
    func removeConfirmedGoogleDeletions(_ confirmed: Set<PendingGoogleEventDeletion>) {
        guard !confirmed.isEmpty else { return }
        let liveQueue = pendingGoogleDeletions
        pendingGoogleDeletions = liveQueue.filter { !confirmed.contains($0) }
    }

    /// Enqueues an EventKit deletion without clobbering concurrent queue items.
    func enqueueEKDeletion(_ item: PendingEKEventDeletion) {
        guard !item.eventIdentifier.isEmpty else { return }
        var current = pendingEKDeletions
        if !current.contains(item) {
            current.append(item)
            pendingEKDeletions = current
        }
    }

    /// Removes only confirmed deletions from the live `pendingEKDeletions` queue, preserving any retries appended mid-sync.
    func removeConfirmedEKDeletions(_ confirmed: Set<PendingEKEventDeletion>) {
        guard !confirmed.isEmpty else { return }
        let liveQueue = pendingEKDeletions
        pendingEKDeletions = liveQueue.filter { !confirmed.contains($0) }
    }

    var cachedGoogleBusySnapshot: CachedGoogleBusySnapshot? {
        get {
            guard !cachedGoogleBusySnapshotJSON.isEmpty,
                  let data = cachedGoogleBusySnapshotJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(CachedGoogleBusySnapshot.self, from: data) else {
                return nil
            }
            return decoded
        }
        set {
            guard let newValue,
                  let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8) else {
                cachedGoogleBusySnapshotJSON = ""
                return
            }
            cachedGoogleBusySnapshotJSON = json
        }
    }

    var historicalStreakArchive: HistoricalStreakArchive? {
        get {
            guard !historicalStreakArchiveJSON.isEmpty,
                  let data = historicalStreakArchiveJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(HistoricalStreakArchive.self, from: data) else {
                return nil
            }
            return decoded
        }
        set {
            guard let newValue,
                  let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8) else {
                historicalStreakArchiveJSON = ""
                return
            }
            historicalStreakArchiveJSON = json
        }
    }

    /// Retains remote Google / EventKit identifiers when a `TaskOccurrence` is about to be deleted from SwiftData
    /// or migrated to a different destination calendar, ensuring failed remote deletions can be retried.
    func enqueuePendingDeletions(for occurrence: TaskOccurrence, fallbackGoogleCalendarID: String? = nil) {
        if let gEventID = occurrence.googleCalendarEventId, !gEventID.isEmpty {
            let parsed = Self.parseGoogleDestination(occurrence.googleSyncedDestination)
            let calID = parsed?.calendarID ?? fallbackGoogleCalendarID ?? googleCalendarID
            let accKey = parsed?.accountKey ?? ""
            enqueueGoogleDeletion(PendingGoogleEventDeletion(accountKey: accKey, calendarID: calID, eventID: gEventID))
        }
        if let ekGoogleID = occurrence.syncedEKEventIdentifier, !ekGoogleID.isEmpty {
            enqueueEKDeletion(PendingEKEventDeletion(channelRaw: "google-bridge", eventIdentifier: ekGoogleID))
        }
        if let ekAppleID = occurrence.appleCalendarEventIdentifier, !ekAppleID.isEmpty {
            enqueueEKDeletion(PendingEKEventDeletion(channelRaw: "apple", eventIdentifier: ekAppleID))
        }
    }

    static func parseGoogleDestination(_ destination: String?) -> (accountKey: String, calendarID: String)? {
        guard let destination, destination.hasPrefix("google-oauth|") else { return nil }
        let parts = destination.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return (String(parts[1]), String(parts[2]))
    }
}

@Model
final class DayCapacityOverride {
    var id: UUID
    var date: Date
    var dayKey: String = ""
    var dayTimezoneID: String = ""
    var availableMinutes: Int
    var note: String

    init(
        id: UUID = UUID(),
        date: Date,
        availableMinutes: Int,
        note: String = "",
        calendar: Calendar? = nil
    ) {
        self.id = id
        self.availableMinutes = max(0, min(720, availableMinutes))
        self.note = note
        if let calendar {
            let norm = DateHelpers.startOfDay(for: date, calendar: calendar)
            self.date = norm
            self.dayKey = DateHelpers.dayKeyString(for: norm, calendar: calendar)
            self.dayTimezoneID = calendar.timeZone.identifier
        } else {
            self.date = date
            self.dayKey = ""
            self.dayTimezoneID = ""
        }
    }

    func normalizedDay(calendar: Calendar = DateHelpers.calendar) -> Date {
        DateHelpers.resolveCivilDay(
            dayKey: dayKey,
            fallbackDate: date,
            storedTimezoneID: dayTimezoneID,
            calendar: calendar
        ).date
    }

    @discardableResult
    func normalizeCivilDates(in calendar: Calendar = DateHelpers.calendar) -> Date {
        let resolved = DateHelpers.resolveCivilDay(
            dayKey: dayKey,
            fallbackDate: date,
            storedTimezoneID: dayTimezoneID,
            calendar: calendar
        )
        date = resolved.date
        dayKey = resolved.dayKey
        dayTimezoneID = resolved.timezoneID
        return resolved.date
    }
}
