import EventKit
import Foundation
import Observation

enum CozySyncChannel: String, Codable, Sendable {
    case googleOAuth = "google-oauth"
    case googleBridge = "google-bridge"
    case apple = "apple"
}

/// A committed removal in EventKit's identifier namespace. Neither the EventKit identifiers nor
/// the occurrence UUID prove that a separately tracked REST event on another calendar was removed.
struct EKConfirmedOAuthRemoval: Hashable {
    let occurrenceID: UUID?
    let eventIdentifier: String?
    let calendarIdentifier: String
}

struct EKSyncOutcome {
    let upserted: Int
    let removed: Int
    let failed: Int
    let deferred: Int
    let confirmedOAuthRemovals: Set<EKConfirmedOAuthRemoval>
    let calendarTitle: String?
    let errorMessage: String?

    init(
        upserted: Int,
        removed: Int,
        failed: Int,
        deferred: Int = 0,
        confirmedOAuthRemovals: Set<EKConfirmedOAuthRemoval> = [],
        calendarTitle: String?,
        errorMessage: String?
    ) {
        self.upserted = upserted
        self.removed = removed
        self.failed = failed
        self.deferred = deferred
        self.confirmedOAuthRemovals = confirmedOAuthRemovals
        self.calendarTitle = calendarTitle
        self.errorMessage = errorMessage
    }
}

struct BackingCalendarInfo: Equatable {
    let calendarIdentifier: String
    let title: String
    let sourceTitle: String
    let allowsContentModifications: Bool
    let isDefaultForNewEvents: Bool
}

final class BackingEventRecord {
    var eventIdentifier: String?
    var calendarIdentifier: String
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var isFreeAvailability: Bool
    var url: URL?
    var notes: String?
    fileprivate var underlyingEKEvent: EKEvent?

    init(
        eventIdentifier: String? = nil,
        calendarIdentifier: String,
        title: String = "",
        startDate: Date = Date(),
        endDate: Date = Date(),
        isAllDay: Bool = false,
        isFreeAvailability: Bool = false,
        url: URL? = nil,
        notes: String? = nil,
        underlyingEKEvent: EKEvent? = nil
    ) {
        self.eventIdentifier = eventIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.isFreeAvailability = isFreeAvailability
        self.url = url
        self.notes = notes
        self.underlyingEKEvent = underlyingEKEvent
    }

    var resolvedEventIdentifier: String? {
        if let liveID = underlyingEKEvent?.eventIdentifier, !liveID.isEmpty {
            return liveID
        }
        return eventIdentifier
    }
}

@MainActor
protocol EventStoreBacking: AnyObject {
    func authorizationStatus() -> EKAuthorizationStatus
    func requestFullAccess() async throws -> Bool
    func calendars() -> [BackingCalendarInfo]
    func events(from startDate: Date, to endDate: Date, calendarIdentifiers: [String]?) -> [BackingEventRecord]
    func event(withIdentifier identifier: String) -> BackingEventRecord?
    func makeNewEvent(in calendarIdentifier: String) -> BackingEventRecord
    func save(_ event: BackingEventRecord) throws
    func remove(_ event: BackingEventRecord) throws
    func commit() throws
    func reset()
}

@MainActor
final class LiveEventStoreBacking: EventStoreBacking {
    private let eventStore = EKEventStore()

    func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func requestFullAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToEvents()
    }

    func calendars() -> [BackingCalendarInfo] {
        let defaultID = eventStore.defaultCalendarForNewEvents?.calendarIdentifier
        return eventStore.calendars(for: .event).map { cal in
            BackingCalendarInfo(
                calendarIdentifier: cal.calendarIdentifier,
                title: cal.title,
                sourceTitle: cal.source.title,
                allowsContentModifications: cal.allowsContentModifications,
                isDefaultForNewEvents: cal.calendarIdentifier == defaultID
            )
        }
    }

    func events(from startDate: Date, to endDate: Date, calendarIdentifiers: [String]?) -> [BackingEventRecord] {
        let ekCalendars: [EKCalendar]?
        if let calendarIdentifiers {
            let idSet = Set(calendarIdentifiers)
            let matched = eventStore.calendars(for: .event).filter { idSet.contains($0.calendarIdentifier) }
            if matched.isEmpty {
                return []
            }
            ekCalendars = matched
        } else {
            ekCalendars = nil
        }

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: ekCalendars)
        return eventStore.events(matching: predicate).compactMap { Self.wrap($0) }
    }

    func event(withIdentifier identifier: String) -> BackingEventRecord? {
        guard !identifier.isEmpty, let ekEvent = eventStore.event(withIdentifier: identifier) else {
            return nil
        }
        return Self.wrap(ekEvent)
    }

    func makeNewEvent(in calendarIdentifier: String) -> BackingEventRecord {
        let ekEvent = EKEvent(eventStore: eventStore)
        if let cal = eventStore.calendars(for: .event).first(where: { $0.calendarIdentifier == calendarIdentifier }) {
            ekEvent.calendar = cal
        }
        return BackingEventRecord(
            eventIdentifier: ekEvent.eventIdentifier,
            calendarIdentifier: calendarIdentifier,
            underlyingEKEvent: ekEvent
        )
    }

    func save(_ event: BackingEventRecord) throws {
        let ekEvent = event.underlyingEKEvent ?? EKEvent(eventStore: eventStore)
        if let targetCal = eventStore.calendars(for: .event).first(where: { $0.calendarIdentifier == event.calendarIdentifier }) {
            ekEvent.calendar = targetCal
        }
        ekEvent.title = event.title
        ekEvent.startDate = event.startDate
        ekEvent.endDate = event.endDate
        ekEvent.url = event.url
        ekEvent.notes = event.notes
        event.underlyingEKEvent = ekEvent
        try eventStore.save(ekEvent, span: .thisEvent, commit: false)
        if let assignedID = ekEvent.eventIdentifier, !assignedID.isEmpty {
            event.eventIdentifier = assignedID
        }
    }

    func remove(_ event: BackingEventRecord) throws {
        let ekEvent: EKEvent? = {
            if let direct = event.underlyingEKEvent {
                return direct
            }
            if let eid = event.eventIdentifier, !eid.isEmpty {
                return eventStore.event(withIdentifier: eid)
            }
            return nil
        }()
        guard let ekEvent else { return }
        try eventStore.remove(ekEvent, span: .thisEvent, commit: false)
    }

    func commit() throws {
        try eventStore.commit()
    }

    func reset() {
        eventStore.reset()
    }

    private static func wrap(_ ekEvent: EKEvent) -> BackingEventRecord? {
        guard let s = ekEvent.startDate, let e = ekEvent.endDate else { return nil }
        return BackingEventRecord(
            eventIdentifier: ekEvent.eventIdentifier,
            calendarIdentifier: ekEvent.calendar?.calendarIdentifier ?? "",
            title: ekEvent.title ?? "",
            startDate: s,
            endDate: e,
            isAllDay: ekEvent.isAllDay,
            isFreeAvailability: ekEvent.availability == .free,
            url: ekEvent.url,
            notes: ekEvent.notes,
            underlyingEKEvent: ekEvent
        )
    }
}

@MainActor
@Observable
final class CalendarFreeTimeService {
    static let shared = CalendarFreeTimeService()
    nonisolated static let cozyEventMarker = "[CozyProductivity]"
    nonisolated static let cozyURLScheme = "cozyproductivity"

    private let backing: EventStoreBacking
    private(set) var authorizationStatus: EKAuthorizationStatus

    init(backing: EventStoreBacking? = nil) {
        let resolvedBacking = backing ?? LiveEventStoreBacking()
        self.backing = resolvedBacking
        self.authorizationStatus = resolvedBacking.authorizationStatus()
    }

    var hasReadAccess: Bool {
        authorizationStatus == .fullAccess
    }

    func refreshAuthorizationStatus() {
        authorizationStatus = backing.authorizationStatus()
    }

    func requestAccess() async -> Bool {
        do {
            let granted = try await backing.requestFullAccess()
            refreshAuthorizationStatus()
            return granted
        } catch {
            refreshAuthorizationStatus()
            return false
        }
    }

    // MARK: - Apple Calendar Busy Intervals & Minutes

    func busyIntervalsByDay(
        from startDate: Date,
        to endDate: Date,
        wakingStartHour: Int,
        wakingEndHour: Int,
        calendarIdentifiers: [String]? = nil,
        calendar: Calendar = DateHelpers.calendar
    ) -> [Date: [(Date, Date)]] {
        refreshAuthorizationStatus()
        guard hasReadAccess else { return [:] }

        let firstDay = DateHelpers.startOfDay(for: startDate, calendar: calendar)
        let lastDay = DateHelpers.startOfDay(for: endDate, calendar: calendar)
        guard let queryEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) else {
            return [:]
        }

        if let calendarIdentifiers, calendarIdentifiers.isEmpty {
            return [:]
        }

        let events = backing.events(from: firstDay, to: queryEnd, calendarIdentifiers: calendarIdentifiers)

        var rawIntervals: [(Date, Date)] = []
        for event in events {
            if event.isAllDay || event.isFreeAvailability {
                continue
            }
            // Exclude CozyProductivity's own pushed task blocks (across all channels, including OAuth-created Google events)
            if Self.isCozyManagedRecord(event) {
                continue
            }
            if event.endDate > event.startDate {
                rawIntervals.append((event.startDate, event.endDate))
            }
        }

        return Self.clipIntervalsToDays(
            rawIntervals: rawIntervals,
            from: firstDay,
            to: lastDay,
            wakingStartHour: wakingStartHour,
            wakingEndHour: wakingEndHour,
            calendar: calendar
        )
    }

    /// Computes busy minutes per start-of-day Date within `[startDate ... endDate]`,
    /// merging overlapping events inside the configured `[wakingStartHour ... wakingEndHour]` window.
    func busyMinutesByDay(
        from startDate: Date,
        to endDate: Date,
        wakingStartHour: Int,
        wakingEndHour: Int,
        calendar: Calendar = DateHelpers.calendar
    ) -> [Date: Int] {
        let intervalsByDay = busyIntervalsByDay(
            from: startDate,
            to: endDate,
            wakingStartHour: wakingStartHour,
            wakingEndHour: wakingEndHour,
            calendarIdentifiers: nil,
            calendar: calendar
        )
        return Self.mergeBusyIntervalsByDay([intervalsByDay])
    }

    // MARK: - Apple Calendar Target Selection & Two-Way Task Sync

    /// Returns writable non-Google Apple / iCloud / local calendars on the iPhone.
    /// When `excludeGoogleCalendars` is true, Google-backed calendars are strictly excluded to prevent cross-channel interference.
    func writableAppleCalendars(excludeGoogleCalendars: Bool = true) -> [BackingCalendarInfo] {
        refreshAuthorizationStatus()
        guard hasReadAccess else { return [] }
        let googleIDs = Set(googleAccountCalendars().map(\.calendarIdentifier))
        let allWritable = backing.calendars().filter { $0.allowsContentModifications }
        let nonGoogleWritable = allWritable.filter { !googleIDs.contains($0.calendarIdentifier) }
        if excludeGoogleCalendars {
            return nonGoogleWritable
        }
        return nonGoogleWritable.isEmpty ? allWritable : nonGoogleWritable
    }

    func targetAppleCalendar(
        preferredIdentifier: String,
        avoidCalendarIdentifier: String? = nil,
        excludeGoogleCalendars: Bool = false
    ) -> BackingCalendarInfo? {
        refreshAuthorizationStatus()
        guard hasReadAccess else { return nil }

        let googleIDs = Set(googleAccountCalendars().map(\.calendarIdentifier))
        let candidates = backing.calendars().filter { cal in
            guard cal.allowsContentModifications else { return false }
            if cal.calendarIdentifier == avoidCalendarIdentifier { return false }
            if excludeGoogleCalendars && googleIDs.contains(cal.calendarIdentifier) { return false }
            return true
        }

        let trimmedPref = preferredIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPref.isEmpty,
           let chosen = candidates.first(where: { $0.calendarIdentifier == trimmedPref }) {
            return chosen
        }

        if let defaultCal = candidates.first(where: { $0.isDefaultForNewEvents && !googleIDs.contains($0.calendarIdentifier) }) {
            return defaultCal
        }

        if let firstNonGoogle = candidates.first(where: { !googleIDs.contains($0.calendarIdentifier) }) {
            return firstNonGoogle
        }

        return excludeGoogleCalendars ? nil : candidates.first
    }

    func syncOccurrencesToAppleCalendar(
        occurrences: [TaskOccurrence],
        busyIntervalsByDay: [Date: [(Date, Date)]],
        preferences: CozyPreferences,
        today referenceDate: Date = Date(),
        avoidCalendarIdentifier: String? = nil,
        allowSlotChangingWrites: Bool = true,
        calendar: Calendar = DateHelpers.calendar
    ) -> EKSyncOutcome {
        refreshAuthorizationStatus()
        guard hasReadAccess else {
            return EKSyncOutcome(
                upserted: 0,
                removed: 0,
                failed: 0,
                calendarTitle: nil,
                errorMessage: "Grant Calendar Full Access in Settings to sync Apple Calendar"
            )
        }

        let googleIntegrationActive = preferences.useGoogleCalendarSync || preferences.pushTasksToGoogleCalendar
        guard let targetCalendar = targetAppleCalendar(
            preferredIdentifier: preferences.appleTargetCalendarIdentifier,
            avoidCalendarIdentifier: avoidCalendarIdentifier,
            excludeGoogleCalendars: googleIntegrationActive
        ) else {
            let reason = googleIntegrationActive
                ? "Select a non-Google Apple/iCloud calendar for Apple Calendar sync so Google & Apple channels stay separate"
                : "No writable Apple Calendar found"
            return EKSyncOutcome(
                upserted: 0,
                removed: 0,
                failed: 0,
                calendarTitle: nil,
                errorMessage: reason
            )
        }

        return syncOccurrencesToEKCalendar(
            channel: .apple,
            targetCalendar: targetCalendar,
            occurrences: occurrences,
            busyIntervalsByDay: busyIntervalsByDay,
            preferences: preferences,
            today: referenceDate,
            allowSlotChangingWrites: allowSlotChangingWrites,
            cleanupOnly: false,
            sweepStrandedOAuthEvents: false,
            calendar: calendar,
            getEventID: { $0.appleCalendarEventIdentifier },
            setEventID: { $0.appleCalendarEventIdentifier = $1 },
            getDestination: { $0.appleSyncedDestination },
            setDestination: { $0.appleSyncedDestination = $1 },
            getSignature: { $0.lastAppleCalendarSyncSignature },
            setSignature: { $0.lastAppleCalendarSyncSignature = $1 }
        )
    }

    // MARK: - Zero-Config iPhone Google Account Bridge (EventKit Google Source)

    /// Returns Google / Gmail calendars connected in iPhone Settings -> Calendar -> Accounts.
    func googleAccountCalendars() -> [BackingCalendarInfo] {
        refreshAuthorizationStatus()
        guard hasReadAccess else { return [] }
        return backing.calendars().filter { cal in
            let sourceTitle = cal.sourceTitle.lowercased()
            let calTitle = cal.title.lowercased()
            return sourceTitle.contains("google")
                || sourceTitle.contains("gmail")
                || calTitle.contains("@gmail.com")
                || calTitle.contains("google")
        }
    }

    func writableGoogleBridgeCalendar() -> BackingCalendarInfo? {
        let googleCals = googleAccountCalendars().filter { $0.allowsContentModifications }
        if let primaryMatch = googleCals.first(where: { $0.title.contains("@") }) {
            return primaryMatch
        }
        return googleCals.first
    }

    func googleBridgeBusyIntervalsByDay(
        from startDate: Date,
        to endDate: Date,
        wakingStartHour: Int,
        wakingEndHour: Int,
        calendar: Calendar = DateHelpers.calendar
    ) -> [Date: [(Date, Date)]] {
        let googleCals = googleAccountCalendars()
        guard !googleCals.isEmpty else { return [:] }
        return busyIntervalsByDay(
            from: startDate,
            to: endDate,
            wakingStartHour: wakingStartHour,
            wakingEndHour: wakingEndHour,
            calendarIdentifiers: googleCals.map(\.calendarIdentifier),
            calendar: calendar
        )
    }

    func pushAndMergeViaGoogleBridge(
        occurrences: [TaskOccurrence],
        busyIntervalsByDay: [Date: [(Date, Date)]],
        preferences: CozyPreferences,
        today referenceDate: Date = Date(),
        allowSlotChangingWrites: Bool = true,
        sweepStrandedOAuthEvents: Bool = false,
        calendar: Calendar = DateHelpers.calendar
    ) -> EKSyncOutcome {
        refreshAuthorizationStatus()
        guard hasReadAccess else {
            return EKSyncOutcome(
                upserted: 0,
                removed: 0,
                failed: 0,
                calendarTitle: nil,
                errorMessage: "Grant Calendar Full Access in Settings to sync Google Bridge"
            )
        }
        guard let targetCalendar = writableGoogleBridgeCalendar() else {
            return EKSyncOutcome(
                upserted: 0,
                removed: 0,
                failed: 0,
                calendarTitle: nil,
                errorMessage: "No writable Google calendar found in iPhone Calendar Accounts"
            )
        }

        let outcome = syncOccurrencesToEKCalendar(
            channel: .googleBridge,
            targetCalendar: targetCalendar,
            occurrences: occurrences,
            busyIntervalsByDay: busyIntervalsByDay,
            preferences: preferences,
            today: referenceDate,
            allowSlotChangingWrites: allowSlotChangingWrites,
            cleanupOnly: false,
            sweepStrandedOAuthEvents: sweepStrandedOAuthEvents,
            calendar: calendar,
            getEventID: { $0.syncedEKEventIdentifier },
            setEventID: { $0.syncedEKEventIdentifier = $1 },
            getDestination: { $0.googleBridgeSyncedDestination },
            setDestination: { $0.googleBridgeSyncedDestination = $1 },
            getSignature: { $0.lastCalendarSyncSignature },
            setSignature: { occ, newSig in
                if let newSig {
                    occ.lastCalendarSyncSignature = newSig
                } else if occ.lastCalendarSyncSignature?.hasPrefix("google-bridge|") == true {
                    occ.lastCalendarSyncSignature = nil
                }
            }
        )
        // This fallback only visits the selected EventKit calendar within the sync window.
        // Keep the OAuth sweep pending until REST can confirm cleanup of all tracked destinations.
        return outcome
    }

    /// Removes all EventKit events & queued deletions belonging to an inactive channel (e.g. after switching `googleSyncMode`
    /// from `.iosGoogleAccount` to `.oauthREST`, or turning push off), clearing local metadata ONLY after confirmed commit.
    func cleanupChannelEvents(
        channel: CozySyncChannel,
        occurrences: [TaskOccurrence],
        preferences: CozyPreferences,
        today referenceDate: Date = Date(),
        calendar: Calendar = DateHelpers.calendar
    ) -> EKSyncOutcome {
        refreshAuthorizationStatus()
        guard hasReadAccess else {
            return EKSyncOutcome(
                upserted: 0,
                removed: 0,
                failed: 0,
                calendarTitle: nil,
                errorMessage: nil
            )
        }

        let targetCal: BackingCalendarInfo? = {
            switch channel {
            case .googleBridge:
                if let writable = writableGoogleBridgeCalendar() {
                    return writable
                }
                let savedCalIDs = occurrences.compactMap { occ -> String? in
                    guard let dest = occ.googleBridgeSyncedDestination, dest.hasPrefix("google-bridge|") else { return nil }
                    return String(dest.dropFirst("google-bridge|".count))
                }
                return backing.calendars().first { savedCalIDs.contains($0.calendarIdentifier) }
            case .apple:
                if let target = targetAppleCalendar(preferredIdentifier: preferences.appleTargetCalendarIdentifier) {
                    return target
                }
                let savedCalIDs = occurrences.compactMap { occ -> String? in
                    guard let dest = occ.appleSyncedDestination, dest.hasPrefix("apple|") else { return nil }
                    return String(dest.dropFirst("apple|".count))
                }
                return backing.calendars().first { savedCalIDs.contains($0.calendarIdentifier) }
            case .googleOAuth:
                return nil
            }
        }()

        guard let targetCalendar = targetCal else {
            return drainDirectIdentifierRemovalsOnly(
                channel: channel,
                occurrences: occurrences,
                preferences: preferences
            )
        }

        let outcome: EKSyncOutcome
        switch channel {
        case .googleBridge:
            outcome = syncOccurrencesToEKCalendar(
                channel: .googleBridge,
                targetCalendar: targetCalendar,
                occurrences: occurrences,
                busyIntervalsByDay: [:],
                preferences: preferences,
                today: referenceDate,
                allowSlotChangingWrites: false,
                cleanupOnly: true,
                sweepStrandedOAuthEvents: false,
                calendar: calendar,
                getEventID: { $0.syncedEKEventIdentifier },
                setEventID: { $0.syncedEKEventIdentifier = $1 },
                getDestination: { $0.googleBridgeSyncedDestination },
                setDestination: { $0.googleBridgeSyncedDestination = $1 },
                getSignature: { $0.lastCalendarSyncSignature },
                setSignature: { occ, newSig in
                    if let newSig {
                        occ.lastCalendarSyncSignature = newSig
                    } else if occ.lastCalendarSyncSignature?.hasPrefix("google-bridge|") == true {
                        occ.lastCalendarSyncSignature = nil
                    }
                }
            )
            if outcome.failed == 0 {
                preferences.needsGoogleBridgeChannelSweep = false
            }
        case .apple:
            outcome = syncOccurrencesToEKCalendar(
                channel: .apple,
                targetCalendar: targetCalendar,
                occurrences: occurrences,
                busyIntervalsByDay: [:],
                preferences: preferences,
                today: referenceDate,
                allowSlotChangingWrites: false,
                cleanupOnly: true,
                sweepStrandedOAuthEvents: false,
                calendar: calendar,
                getEventID: { $0.appleCalendarEventIdentifier },
                setEventID: { $0.appleCalendarEventIdentifier = $1 },
                getDestination: { $0.appleSyncedDestination },
                setDestination: { $0.appleSyncedDestination = $1 },
                getSignature: { $0.lastAppleCalendarSyncSignature },
                setSignature: { $0.lastAppleCalendarSyncSignature = $1 }
            )
            if outcome.failed == 0 {
                preferences.needsAppleChannelSweep = false
            }
        case .googleOAuth:
            outcome = EKSyncOutcome(upserted: 0, removed: 0, failed: 0, calendarTitle: nil, errorMessage: nil)
        }
        return outcome
    }

    private func drainDirectIdentifierRemovalsOnly(
        channel: CozySyncChannel,
        occurrences: [TaskOccurrence],
        preferences: CozyPreferences
    ) -> EKSyncOutcome {
        var stagedRemovals = 0
        var failures = 0
        var failureReason: String?
        var drained: Set<CozyPreferences.PendingEKEventDeletion> = []
        var removedIDs: Set<String> = []

        for pending in preferences.pendingEKDeletions where pending.channelRaw == channel.rawValue {
            if let existing = backing.event(withIdentifier: pending.eventIdentifier) {
                do {
                    try backing.remove(existing)
                    removedIDs.insert(pending.eventIdentifier)
                    drained.insert(pending)
                    stagedRemovals += 1
                } catch {
                    failures += 1
                    failureReason = error.localizedDescription
                }
            } else {
                drained.insert(pending)
            }
        }

        var clearOccurrences: [TaskOccurrence] = []
        for occ in occurrences {
            let savedID = (channel == .googleBridge) ? occ.syncedEKEventIdentifier : occ.appleCalendarEventIdentifier
            guard let eid = savedID, !eid.isEmpty else { continue }
            if removedIDs.contains(eid) {
                clearOccurrences.append(occ)
                continue
            }
            if let existing = backing.event(withIdentifier: eid) {
                do {
                    try backing.remove(existing)
                    removedIDs.insert(eid)
                    stagedRemovals += 1
                    clearOccurrences.append(occ)
                } catch {
                    preferences.enqueueEKDeletion(.init(channelRaw: channel.rawValue, eventIdentifier: eid))
                    failures += 1
                    failureReason = error.localizedDescription
                }
            } else {
                clearOccurrences.append(occ)
            }
        }

        if stagedRemovals > 0 {
            do {
                try backing.commit()
            } catch {
                backing.reset()
                return EKSyncOutcome(
                    upserted: 0,
                    removed: 0,
                    failed: failures + stagedRemovals,
                    calendarTitle: nil,
                    errorMessage: "Calendar commit failed: \(error.localizedDescription)"
                )
            }
        }

        for occ in clearOccurrences {
            if channel == .googleBridge {
                occ.syncedEKEventIdentifier = nil
                occ.googleBridgeSyncedDestination = nil
                if occ.lastCalendarSyncSignature?.hasPrefix("google-bridge|") == true {
                    occ.lastCalendarSyncSignature = nil
                }
            } else if channel == .apple {
                occ.appleCalendarEventIdentifier = nil
                occ.appleSyncedDestination = nil
                occ.lastAppleCalendarSyncSignature = nil
            }
        }
        preferences.removeConfirmedEKDeletions(drained)
        if failures == 0 {
            if channel == .googleBridge { preferences.needsGoogleBridgeChannelSweep = false }
            if channel == .apple { preferences.needsAppleChannelSweep = false }
        }
        return EKSyncOutcome(upserted: 0, removed: stagedRemovals, failed: failures, calendarTitle: nil, errorMessage: failureReason)
    }

    private struct StagedOccurrenceMetadata {
        let occurrence: TaskOccurrence
        let eventRef: BackingEventRecord?
        let clearMetadata: Bool
        let destinationKey: String?
        let signature: String?
    }

    private func syncOccurrencesToEKCalendar(
        channel: CozySyncChannel,
        targetCalendar: BackingCalendarInfo,
        occurrences: [TaskOccurrence],
        busyIntervalsByDay: [Date: [(Date, Date)]],
        preferences: CozyPreferences,
        today referenceDate: Date,
        allowSlotChangingWrites: Bool,
        cleanupOnly: Bool,
        sweepStrandedOAuthEvents: Bool,
        calendar: Calendar,
        getEventID: (TaskOccurrence) -> String?,
        setEventID: (TaskOccurrence, String?) -> Void,
        getDestination: (TaskOccurrence) -> String?,
        setDestination: (TaskOccurrence, String?) -> Void,
        getSignature: (TaskOccurrence) -> String?,
        setSignature: (TaskOccurrence, String?) -> Void
    ) -> EKSyncOutcome {
        let today = DateHelpers.startOfDay(for: referenceDate, calendar: calendar)
        let minSyncDay = DateHelpers.addDays(-1, to: today, calendar: calendar)
        let maxSyncDay = DateHelpers.addDays(14, to: today, calendar: calendar)
        let queryEnd = calendar.date(byAdding: .day, value: 1, to: maxSyncDay) ?? maxSyncDay.addingTimeInterval(86400)
        let destinationKey = "\(channel.rawValue)|\(targetCalendar.calendarIdentifier)"

        var stagedUpserts = 0
        var stagedRemovals = 0
        var deferredWrites = 0
        var operationFailures = 0
        var failureReason: String?
        var removedEventIDs: Set<String> = []
        var placedByDay: [Date: [(Date, Date)]] = busyIntervalsByDay
        var stagedMetadataUpdates: [StagedOccurrenceMetadata] = []
        var stagedOAuthRemovals: Set<EKConfirmedOAuthRemoval> = []

        func recordStagedOAuthRemoval(_ event: BackingEventRecord) {
            guard Self.recordBelongsToChannel(event, channel: .googleOAuth) else { return }
            stagedOAuthRemovals.insert(
                EKConfirmedOAuthRemoval(
                    occurrenceID: Self.extractCozyOccurrenceID(fromURL: event.url, notes: event.notes),
                    eventIdentifier: event.resolvedEventIdentifier,
                    calendarIdentifier: event.calendarIdentifier
                )
            )
        }

        func effectiveOccurrenceDay(_ occ: TaskOccurrence) -> Date {
            if occ.isCompleted, let bonus = occ.bonusDay(calendar: calendar) {
                return bonus
            }
            return occ.scheduledDay(calendar: calendar)
        }

        // 0. Detect destination calendar switches so old-calendar events are queued for removal
        //    and tasks are never silently skipped on the newly selected calendar.
        var migratedOldEventIDsToRemove: Set<String> = []
        if !cleanupOnly {
            for occ in occurrences {
                if let oldDest = getDestination(occ), oldDest != destinationKey,
                   let oldID = getEventID(occ), !oldID.isEmpty {
                    migratedOldEventIDsToRemove.insert(oldID)
                }
            }
        }

        let activeWindowOccurrences: [TaskOccurrence] = cleanupOnly
            ? []
            : occurrences
                .filter { occ in
                    guard occ.status != .skipped && occ.status != .missed else { return false }
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

        // 1. Drain any persisted pending deletions for this channel first
        let pendingSnapshotToAttempt = preferences.pendingEKDeletions
        var drainedPendingItems: Set<CozyPreferences.PendingEKEventDeletion> = []
        for pending in pendingSnapshotToAttempt where pending.channelRaw == channel.rawValue {
            if removedEventIDs.contains(pending.eventIdentifier) {
                drainedPendingItems.insert(pending)
                continue
            }
            if let staleEvent = backing.event(withIdentifier: pending.eventIdentifier) {
                do {
                    try backing.remove(staleEvent)
                    recordStagedOAuthRemoval(staleEvent)
                    // Mark removed ONLY after `backing.remove` succeeds!
                    removedEventIDs.insert(pending.eventIdentifier)
                    drainedPendingItems.insert(pending)
                    stagedRemovals += 1
                } catch {
                    operationFailures += 1
                    failureReason = error.localizedDescription
                }
            } else {
                // Already absent from EventKit
                drainedPendingItems.insert(pending)
            }
        }

        // Remove any old-destination events caused by switching Apple/Bridge calendars
        for oldID in migratedOldEventIDsToRemove where !removedEventIDs.contains(oldID) {
            if let oldEvent = backing.event(withIdentifier: oldID) {
                do {
                    try backing.remove(oldEvent)
                    recordStagedOAuthRemoval(oldEvent)
                    removedEventIDs.insert(oldID)
                    stagedRemovals += 1
                } catch {
                    preferences.enqueueEKDeletion(.init(channelRaw: channel.rawValue, eventIdentifier: oldID))
                    operationFailures += 1
                    failureReason = error.localizedDescription
                }
            }
        }

        // 2. Scan existing Cozy-managed events on targetCalendar OWNED BY THIS CHANNEL ONLY
        //    (plus stranded `.googleOAuth` events ONLY when explicitly sweeping after an offline/signed-out mode switch),
        //    and deduplicate!
        var existingByOccID: [UUID: BackingEventRecord] = [:]
        for event in backing.events(from: minSyncDay, to: queryEnd, calendarIdentifiers: [targetCalendar.calendarIdentifier]) {
            let belongsToActiveChannel = Self.recordBelongsToChannel(event, channel: channel)
            let isSweptOAuthEvent = sweepStrandedOAuthEvents
                && channel == .googleBridge
                && Self.recordBelongsToChannel(event, channel: .googleOAuth)

            guard belongsToActiveChannel || isSweptOAuthEvent else {
                continue
            }

            if belongsToActiveChannel,
               let occID = Self.extractCozyOccurrenceID(fromURL: event.url, notes: event.notes),
               activeIDs.contains(occID) {
                if existingByOccID[occID] == nil {
                    existingByOccID[occID] = event
                } else {
                    // Duplicate event for the same occurrence on this channel -> remove duplicate
                    do {
                        try backing.remove(event)
                        recordStagedOAuthRemoval(event)
                        if let eid = event.resolvedEventIdentifier, !eid.isEmpty {
                            removedEventIDs.insert(eid)
                        }
                        stagedRemovals += 1
                    } catch {
                        if let eid = event.resolvedEventIdentifier, !eid.isEmpty {
                            preferences.enqueueEKDeletion(.init(channelRaw: channel.rawValue, eventIdentifier: eid))
                        }
                        operationFailures += 1
                        failureReason = error.localizedDescription
                    }
                }
            } else {
                do {
                    try backing.remove(event)
                    recordStagedOAuthRemoval(event)
                    if let eid = event.resolvedEventIdentifier, !eid.isEmpty {
                        removedEventIDs.insert(eid)
                    }
                    stagedRemovals += 1
                } catch {
                    if let eid = event.resolvedEventIdentifier, !eid.isEmpty {
                        preferences.enqueueEKDeletion(.init(channelRaw: channel.rawValue, eventIdentifier: eid))
                    }
                    operationFailures += 1
                    failureReason = error.localizedDescription
                }
            }
        }

        // 3. Stage cleanup of tracked identifiers on skipped, out-of-window, or cleanup-only occurrences
        //    (NEVER clearing saved tracking metadata if removal threw!)
        for occ in occurrences where !activeIDs.contains(occ.id) {
            guard let savedID = getEventID(occ), !savedID.isEmpty else { continue }
            if removedEventIDs.contains(savedID) {
                stagedMetadataUpdates.append(
                    StagedOccurrenceMetadata(
                        occurrence: occ,
                        eventRef: nil,
                        clearMetadata: true,
                        destinationKey: nil,
                        signature: nil
                    )
                )
                continue
            }
            if let staleEvent = backing.event(withIdentifier: savedID) {
                do {
                    try backing.remove(staleEvent)
                    recordStagedOAuthRemoval(staleEvent)
                    removedEventIDs.insert(savedID)
                    stagedRemovals += 1
                    stagedMetadataUpdates.append(
                        StagedOccurrenceMetadata(
                            occurrence: occ,
                            eventRef: nil,
                            clearMetadata: true,
                            destinationKey: nil,
                            signature: nil
                        )
                    )
                } catch {
                    preferences.enqueueEKDeletion(.init(channelRaw: channel.rawValue, eventIdentifier: savedID))
                    operationFailures += 1
                    failureReason = error.localizedDescription
                }
            } else {
                // Event no longer exists in EventKit; safe to clear after commit
                stagedMetadataUpdates.append(
                    StagedOccurrenceMetadata(
                        occurrence: occ,
                        eventRef: nil,
                        clearMetadata: true,
                        destinationKey: nil,
                        signature: nil
                    )
                )
            }
        }

        // 4. Stage upserts for active occurrences on targetCalendar
        for occ in activeWindowOccurrences {
            let effectiveDay = effectiveOccurrenceDay(occ)

            let matchedExisting: BackingEventRecord? = {
                if getDestination(occ) == destinationKey,
                   let savedID = getEventID(occ),
                   let fetched = backing.event(withIdentifier: savedID),
                   fetched.calendarIdentifier == targetCalendar.calendarIdentifier {
                    return fetched
                }
                return existingByOccID[occ.id]
            }()

            let slot: (Date, Date)
            if allowSlotChangingWrites {
                let assigned = Self.assignSlotForTask(
                    on: effectiveDay,
                    durationMinutes: occ.displayDurationMinutes,
                    preferredStartHour: preferences.googleTaskPushStartHour,
                    wakingStartHour: preferences.wakingStartHour,
                    wakingEndHour: preferences.wakingEndHour,
                    existingBusyIntervals: placedByDay[effectiveDay] ?? [],
                    calendar: calendar
                )
                placedByDay[effectiveDay, default: []].append(assigned)
                slot = assigned
            } else {
                // Busy-time source was unavailable: NEVER assign or move slots into potentially unknown meetings!
                // Only allow in-place completion/title/notes updates when an event already exists on `effectiveDay`.
                guard let existing = matchedExisting,
                      existing.calendarIdentifier == targetCalendar.calendarIdentifier,
                      DateHelpers.isSameDay(existing.startDate, effectiveDay, calendar: calendar),
                      existing.endDate > existing.startDate else {
                    deferredWrites += 1
                    continue
                }
                slot = (existing.startDate, existing.endDate)
            }

            let desiredTitle = occ.isCompleted
                ? "✅ \(occ.displayEmoji) \(occ.displayTitle)"
                : "\(occ.displayEmoji) \(occ.displayTitle)"
            let notesHeader = occ.displayNotes.isEmpty ? "" : "\(occ.displayNotes)\n\n"
            let deadlineNote = occ.effectiveHardDeadline(calendar: calendar).map {
                " · Hard Deadline \(DateHelpers.shortMonthDayString(for: $0, calendar: calendar))"
            } ?? ""
            let metadataFooter = Self.formatCozyMetadataTag(channel: channel, occurrenceID: occ.id)
            let desiredNotes = "\(notesHeader)Scheduled by Cozy (\(occ.recurrenceLabel) · \(occ.displayWeight.badgeLabel)\(deadlineNote)) \(metadataFooter)"
            let signature = Self.buildCalendarSyncSignature(
                destinationKey: destinationKey,
                start: slot.0,
                end: slot.1,
                title: desiredTitle,
                notes: desiredNotes
            )

            if let existing = matchedExisting,
               existing.calendarIdentifier == targetCalendar.calendarIdentifier,
               getDestination(occ) == destinationKey,
               getSignature(occ) == signature {
                stagedMetadataUpdates.append(
                    StagedOccurrenceMetadata(
                        occurrence: occ,
                        eventRef: existing,
                        clearMetadata: false,
                        destinationKey: destinationKey,
                        signature: signature
                    )
                )
                continue
            }

            let event = matchedExisting ?? backing.makeNewEvent(in: targetCalendar.calendarIdentifier)
            event.calendarIdentifier = targetCalendar.calendarIdentifier
            event.title = desiredTitle
            event.startDate = slot.0
            event.endDate = slot.1
            event.url = Self.makeCozyEventURL(channel: channel, occurrenceID: occ.id)
            event.notes = desiredNotes

            do {
                try backing.save(event)
                stagedUpserts += 1
                stagedMetadataUpdates.append(
                    StagedOccurrenceMetadata(
                        occurrence: occ,
                        eventRef: event,
                        clearMetadata: false,
                        destinationKey: destinationKey,
                        signature: signature
                    )
                )
            } catch {
                operationFailures += 1
                failureReason = error.localizedDescription
            }
        }

        // 5. Commit EventKit changes BEFORE mutating local sync metadata!
        if stagedUpserts > 0 || stagedRemovals > 0 {
            do {
                try backing.commit()
            } catch {
                backing.reset()
                return EKSyncOutcome(
                    upserted: 0,
                    removed: 0,
                    failed: operationFailures + stagedUpserts + stagedRemovals,
                    deferred: deferredWrites,
                    calendarTitle: targetCalendar.title,
                    errorMessage: "Calendar commit failed: \(error.localizedDescription)"
                )
            }
        }

        // 6. Commit succeeded: apply staged metadata & remove ONLY confirmed pending deletions from the live queue
        for update in stagedMetadataUpdates {
            if update.clearMetadata {
                setEventID(update.occurrence, nil)
                setDestination(update.occurrence, nil)
                setSignature(update.occurrence, nil)
            } else if let eventID = update.eventRef?.resolvedEventIdentifier, !eventID.isEmpty {
                setEventID(update.occurrence, eventID)
                setDestination(update.occurrence, update.destinationKey)
                setSignature(update.occurrence, update.signature)
            }
        }

        if !drainedPendingItems.isEmpty {
            preferences.removeConfirmedEKDeletions(drainedPendingItems)
        }

        return EKSyncOutcome(
            upserted: stagedUpserts,
            removed: stagedRemovals,
            failed: operationFailures,
            deferred: deferredWrites,
            confirmedOAuthRemovals: stagedOAuthRemovals,
            calendarTitle: targetCalendar.title,
            errorMessage: failureReason
        )
    }

    // MARK: - Pure Testable Metadata, Channel Isolation, Interval Merging & Slot Placement Helpers

    nonisolated static func formatCozyMetadataTag(channel: CozySyncChannel, occurrenceID: UUID) -> String {
        "\(cozyEventMarker) [CozyChannel:\(channel.rawValue)] [CozyOccurrence:\(occurrenceID.uuidString.lowercased())]"
    }

    nonisolated static func makeCozyEventURL(channel: CozySyncChannel, occurrenceID: UUID) -> URL? {
        URL(string: "\(cozyURLScheme)://occurrence/\(occurrenceID.uuidString.lowercased())?channel=\(channel.rawValue)")
    }

    nonisolated static func isCozyManagedEvent(_ event: EKEvent) -> Bool {
        isCozyManagedMetadata(url: event.url, notes: event.notes)
    }

    nonisolated static func isCozyManagedRecord(_ record: BackingEventRecord) -> Bool {
        isCozyManagedMetadata(url: record.url, notes: record.notes)
    }

    nonisolated static func isCozyManagedMetadata(url: URL?, notes: String?) -> Bool {
        if url?.scheme?.lowercased() == cozyURLScheme {
            return true
        }
        if let notes, notes.contains(cozyEventMarker) {
            return true
        }
        return false
    }

    nonisolated static func extractCozyChannel(fromURL url: URL?, notes: String?) -> CozySyncChannel? {
        if let url,
           url.scheme?.lowercased() == cozyURLScheme,
           let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let raw = items.first(where: { $0.name == "channel" })?.value,
           let channel = CozySyncChannel(rawValue: raw) {
            return channel
        }
        if let notes,
           let range = notes.range(of: #"\[CozyChannel:([a-z\-]+)\]"#, options: .regularExpression) {
            let token = String(notes[range])
            let inner = token
                .replacingOccurrences(of: "[CozyChannel:", with: "")
                .replacingOccurrences(of: "]", with: "")
            if let channel = CozySyncChannel(rawValue: inner) {
                return channel
            }
        }
        // Legacy Google OAuth events wrote `[CozyProductivity]` in description without a `cozyproductivity://` URL
        if url == nil, let notes, notes.contains(cozyEventMarker) {
            return .googleOAuth
        }
        return nil
    }

    nonisolated static func extractCozyOccurrenceID(fromURL url: URL?, notes: String? = nil) -> UUID? {
        if let url, url.scheme?.lowercased() == cozyURLScheme {
            let lastComponent = url.lastPathComponent
            if let parsed = UUID(uuidString: lastComponent) {
                return parsed
            }
        }
        if let notes,
           let range = notes.range(
               of: #"\[CozyOccurrence:([0-9a-fA-F\-]{36})\]"#,
               options: .regularExpression
           ) {
            let token = String(notes[range])
            let rawUUID = token
                .replacingOccurrences(of: "[CozyOccurrence:", with: "")
                .replacingOccurrences(of: "]", with: "")
            if let parsed = UUID(uuidString: rawUUID) {
                return parsed
            }
        }
        return nil
    }

    nonisolated static func eventBelongsToChannel(_ event: EKEvent, channel: CozySyncChannel) -> Bool {
        guard isCozyManagedEvent(event) else { return false }
        return metadataBelongsToChannel(url: event.url, notes: event.notes, targetChannel: channel)
    }

    nonisolated static func recordBelongsToChannel(_ record: BackingEventRecord, channel: CozySyncChannel) -> Bool {
        guard isCozyManagedRecord(record) else { return false }
        return metadataBelongsToChannel(url: record.url, notes: record.notes, targetChannel: channel)
    }

    nonisolated static func metadataBelongsToChannel(
        url: URL?,
        notes: String?,
        targetChannel: CozySyncChannel
    ) -> Bool {
        if let explicit = extractCozyChannel(fromURL: url, notes: notes) {
            return explicit == targetChannel
        }
        // Legacy EventKit events had a `cozyproductivity://occurrence/<uuid>` URL without channel query parameter
        if let url, url.scheme?.lowercased() == cozyURLScheme {
            return targetChannel != .googleOAuth
        }
        return false
    }

    nonisolated static func buildCalendarSyncSignature(
        destinationKey: String,
        start: Date,
        end: Date,
        title: String,
        notes: String
    ) -> String {
        "\(destinationKey)|\(Int(start.timeIntervalSince1970))|\(Int(end.timeIntervalSince1970))|\(title)|\(notes)"
    }

    nonisolated static func clipIntervalsToDays(
        rawIntervals: [(Date, Date)],
        from startDate: Date,
        to endDate: Date,
        wakingStartHour: Int,
        wakingEndHour: Int,
        calendar: Calendar = DateHelpers.calendar
    ) -> [Date: [(Date, Date)]] {
        guard !rawIntervals.isEmpty else { return [:] }
        let firstDay = DateHelpers.startOfDay(for: startDate, calendar: calendar)
        let lastDay = DateHelpers.startOfDay(for: endDate, calendar: calendar)
        let totalDays = max(0, DateHelpers.daysBetween(firstDay, and: lastDay, calendar: calendar))

        let clampedStartHour = max(0, min(22, wakingStartHour))
        let clampedEndHour = max(clampedStartHour + 1, min(24, wakingEndHour))

        var byDay: [Date: [(Date, Date)]] = [:]
        for offset in 0...totalDays {
            let day = DateHelpers.addDays(offset, to: firstDay, calendar: calendar)
            guard
                let windowStart = calendar.date(byAdding: .hour, value: clampedStartHour, to: day),
                let windowEnd = calendar.date(byAdding: .hour, value: clampedEndHour, to: day)
            else {
                continue
            }

            var dayClips: [(Date, Date)] = []
            for (start, end) in rawIntervals {
                let clippedStart = max(windowStart, start)
                let clippedEnd = min(windowEnd, end)
                if clippedEnd > clippedStart {
                    dayClips.append((clippedStart, clippedEnd))
                }
            }
            if !dayClips.isEmpty {
                byDay[day] = dayClips
            }
        }
        return byDay
    }

    /// Merges interval dictionaries from multiple calendar sources (e.g., Apple Calendar + Google Calendar)
    /// per day so overlapping events across both calendars are unioned and never double-counted.
    nonisolated static func mergeBusyIntervalsByDay(
        _ sources: [[Date: [(Date, Date)]]]
    ) -> [Date: Int] {
        var combined: [Date: [(Date, Date)]] = [:]
        for source in sources {
            for (day, intervals) in source {
                combined[day, default: []].append(contentsOf: intervals)
            }
        }

        var minutesByDay: [Date: Int] = [:]
        for (day, intervals) in combined {
            let mins = mergedDurationMinutes(for: intervals)
            if mins > 0 {
                minutesByDay[day] = mins
            }
        }
        return minutesByDay
    }

    nonisolated static func combineRawIntervalsByDay(
        _ sources: [[Date: [(Date, Date)]]]
    ) -> [Date: [(Date, Date)]] {
        var combined: [Date: [(Date, Date)]] = [:]
        for source in sources {
            for (day, intervals) in source {
                combined[day, default: []].append(contentsOf: intervals)
            }
        }
        return combined
    }

    /// Pure helper (also testable without EventKit) that merges overlapping `[start, end]` intervals.
    nonisolated static func mergedDurationMinutes(for intervals: [(Date, Date)]) -> Int {
        guard !intervals.isEmpty else { return 0 }
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var merged: [(Date, Date)] = [sorted[0]]

        for current in sorted.dropFirst() {
            let lastIndex = merged.count - 1
            if current.0 <= merged[lastIndex].1 {
                if current.1 > merged[lastIndex].1 {
                    merged[lastIndex].1 = current.1
                }
            } else {
                merged.append(current)
            }
        }

        let totalSeconds = merged.reduce(0.0) { partial, pair in
            partial + pair.1.timeIntervalSince(pair.0)
        }
        return Int((totalSeconds / 60.0).rounded())
    }

    /// Finds a clean, non-overlapping `[start, end]` block on `day` for pushing a Cozy task to Google Calendar,
    /// trying `preferredStartHour` -> `wakingEndHour` first, then `wakingStartHour` -> `preferredStartHour`,
    /// and falling back to `preferredStartHour` if the entire day is solid back-to-back meetings.
    nonisolated static func assignSlotForTask(
        on day: Date,
        durationMinutes: Int,
        preferredStartHour: Int,
        wakingStartHour: Int,
        wakingEndHour: Int,
        existingBusyIntervals: [(Date, Date)],
        calendar: Calendar = DateHelpers.calendar
    ) -> (Date, Date) {
        let startOfDay = DateHelpers.startOfDay(for: day, calendar: calendar)
        let safeDuration = TimeInterval(max(5, durationMinutes) * 60)
        let clampedWakeStart = max(5, min(21, wakingStartHour))
        let clampedWakeEnd = max(clampedWakeStart + 2, min(24, wakingEndHour))
        let clampedPref = max(clampedWakeStart, min(clampedWakeEnd - 1, preferredStartHour))

        let prefStart = calendar.date(byAdding: .hour, value: clampedPref, to: startOfDay) ?? startOfDay
        let wakeStart = calendar.date(byAdding: .hour, value: clampedWakeStart, to: startOfDay) ?? startOfDay
        let wakeEnd = calendar.date(byAdding: .hour, value: clampedWakeEnd, to: startOfDay) ?? startOfDay.addingTimeInterval(21 * 3600)

        let sortedBusy = existingBusyIntervals.sorted { $0.0 < $1.0 }

        func findGap(windowStart: Date, windowEnd: Date) -> (Date, Date)? {
            var candidate = windowStart
            while candidate.addingTimeInterval(safeDuration) <= windowEnd {
                let candidateEnd = candidate.addingTimeInterval(safeDuration)
                if let blocker = sortedBusy.first(where: { $0.0 < candidateEnd && $0.1 > candidate }) {
                    // Jump cleanly to the end of the overlapping busy block (rounded up to 5-min boundary)
                    let rawNext = blocker.1
                    let remainder = rawNext.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 300)
                    candidate = remainder == 0 ? rawNext : rawNext.addingTimeInterval(300 - remainder)
                } else {
                    return (candidate, candidateEnd)
                }
            }
            return nil
        }

        if let eveningSlot = findGap(windowStart: prefStart, windowEnd: wakeEnd) {
            return eveningSlot
        }
        if let earlierSlot = findGap(windowStart: wakeStart, windowEnd: prefStart) {
            return earlierSlot
        }
        return (prefStart, prefStart.addingTimeInterval(safeDuration))
    }
}
