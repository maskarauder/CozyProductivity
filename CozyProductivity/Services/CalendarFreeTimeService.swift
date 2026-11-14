import EventKit
import Foundation
import Observation

enum CozySyncChannel: String, Codable, Sendable {
    case googleOAuth = "google-oauth"
    case googleBridge = "google-bridge"
    case apple = "apple"
}

struct EKSyncOutcome {
    let upserted: Int
    let removed: Int
    let failed: Int
    let calendarTitle: String?
    let errorMessage: String?
}

@MainActor
@Observable
final class CalendarFreeTimeService {
    static let shared = CalendarFreeTimeService()
    nonisolated static let cozyEventMarker = "[CozyProductivity]"
    nonisolated static let cozyURLScheme = "cozyproductivity"

    private let eventStore = EKEventStore()
    private(set) var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    init() {}

    var hasReadAccess: Bool {
        authorizationStatus == .fullAccess
    }

    func refreshAuthorizationStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    func requestAccess() async -> Bool {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
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
        calendars: [EKCalendar]? = nil,
        calendar: Calendar = DateHelpers.calendar
    ) -> [Date: [(Date, Date)]] {
        refreshAuthorizationStatus()
        guard hasReadAccess else { return [:] }

        let firstDay = DateHelpers.startOfDay(for: startDate, calendar: calendar)
        let lastDay = DateHelpers.startOfDay(for: endDate, calendar: calendar)
        guard let queryEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) else {
            return [:]
        }

        if let calendars, calendars.isEmpty {
            return [:]
        }

        let predicate = eventStore.predicateForEvents(withStart: firstDay, end: queryEnd, calendars: calendars)
        let events = eventStore.events(matching: predicate)

        var rawIntervals: [(Date, Date)] = []
        for event in events {
            if event.isAllDay || event.availability == .free {
                continue
            }
            // Exclude CozyProductivity's own pushed task blocks (across all channels, including OAuth-created Google events)
            if Self.isCozyManagedEvent(event) {
                continue
            }
            if let s = event.startDate, let e = event.endDate, e > s {
                rawIntervals.append((s, e))
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
            calendars: nil,
            calendar: calendar
        )
        return Self.mergeBusyIntervalsByDay([intervalsByDay])
    }

    // MARK: - Apple Calendar Target Selection & Two-Way Task Sync

    /// Returns writable non-Google Apple / iCloud / local calendars on the iPhone.
    /// When `excludeGoogleCalendars` is true, Google-backed calendars are strictly excluded to prevent cross-channel interference.
    func writableAppleCalendars(excludeGoogleCalendars: Bool = true) -> [EKCalendar] {
        refreshAuthorizationStatus()
        guard hasReadAccess else { return [] }
        let googleIDs = Set(googleAccountCalendars().map(\.calendarIdentifier))
        let allWritable = eventStore.calendars(for: .event).filter { $0.allowsContentModifications }
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
    ) -> EKCalendar? {
        refreshAuthorizationStatus()
        guard hasReadAccess else { return nil }

        let googleIDs = Set(googleAccountCalendars().map(\.calendarIdentifier))
        let candidates = eventStore.calendars(for: .event).filter { cal in
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

        if let defaultCal = eventStore.defaultCalendarForNewEvents,
           candidates.contains(where: { $0.calendarIdentifier == defaultCal.calendarIdentifier }),
           !googleIDs.contains(defaultCal.calendarIdentifier) {
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
    func googleAccountCalendars() -> [EKCalendar] {
        refreshAuthorizationStatus()
        guard hasReadAccess else { return [] }
        return eventStore.calendars(for: .event).filter { cal in
            let sourceTitle = cal.source.title.lowercased()
            let calTitle = cal.title.lowercased()
            return sourceTitle.contains("google")
                || sourceTitle.contains("gmail")
                || calTitle.contains("@gmail.com")
                || calTitle.contains("google")
        }
    }

    func writableGoogleBridgeCalendar() -> EKCalendar? {
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
            calendars: googleCals,
            calendar: calendar
        )
    }

    func pushAndMergeViaGoogleBridge(
        occurrences: [TaskOccurrence],
        busyIntervalsByDay: [Date: [(Date, Date)]],
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

        return syncOccurrencesToEKCalendar(
            channel: .googleBridge,
            targetCalendar: targetCalendar,
            occurrences: occurrences,
            busyIntervalsByDay: busyIntervalsByDay,
            preferences: preferences,
            today: referenceDate,
            calendar: calendar,
            getEventID: { $0.syncedEKEventIdentifier },
            setEventID: { $0.syncedEKEventIdentifier = $1 },
            getDestination: { $0.googleBridgeSyncedDestination },
            setDestination: { $0.googleBridgeSyncedDestination = $1 },
            getSignature: { $0.lastCalendarSyncSignature },
            setSignature: { $0.lastCalendarSyncSignature = $1 }
        )
    }

    private struct StagedOccurrenceMetadata {
        let occurrence: TaskOccurrence
        let eventRef: EKEvent?
        let clearMetadata: Bool
        let destinationKey: String?
        let signature: String?
    }

    private func syncOccurrencesToEKCalendar(
        channel: CozySyncChannel,
        targetCalendar: EKCalendar,
        occurrences: [TaskOccurrence],
        busyIntervalsByDay: [Date: [(Date, Date)]],
        preferences: CozyPreferences,
        today referenceDate: Date,
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
        var operationFailures = 0
        var failureReason: String?
        var removedEventIDs: Set<String> = []
        var placedByDay: [Date: [(Date, Date)]] = busyIntervalsByDay
        var stagedMetadataUpdates: [StagedOccurrenceMetadata] = []

        func effectiveOccurrenceDay(_ occ: TaskOccurrence) -> Date {
            if occ.isCompleted, let bonus = occ.bonusDay(calendar: calendar) {
                return bonus
            }
            return occ.scheduledDay(calendar: calendar)
        }

        // 0. Detect destination calendar switches so old-calendar events are queued for removal
        //    and tasks are never silently skipped on the newly selected calendar.
        var migratedOldEventIDsToRemove: Set<String> = []
        for occ in occurrences {
            if let oldDest = getDestination(occ), oldDest != destinationKey,
               let oldID = getEventID(occ), !oldID.isEmpty {
                migratedOldEventIDsToRemove.insert(oldID)
            }
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

        // 1. Drain any persisted pending deletions for this channel first
        let existingPendingQueue = preferences.pendingEKDeletions
        var drainedPendingItems: Set<CozyPreferences.PendingEKEventDeletion> = []
        for pending in existingPendingQueue where pending.channelRaw == channel.rawValue {
            if removedEventIDs.contains(pending.eventIdentifier) {
                drainedPendingItems.insert(pending)
                continue
            }
            if let staleEvent = eventStore.event(withIdentifier: pending.eventIdentifier) {
                do {
                    try eventStore.remove(staleEvent, span: .thisEvent, commit: false)
                    removedEventIDs.insert(pending.eventIdentifier)
                    drainedPendingItems.insert(pending)
                    stagedRemovals += 1
                } catch {
                    operationFailures += 1
                    failureReason = error.localizedDescription
                }
            } else {
                // Already deleted from EventKit
                drainedPendingItems.insert(pending)
            }
        }

        // Remove any old-destination events caused by switching Apple/Bridge calendars
        for oldID in migratedOldEventIDsToRemove where !removedEventIDs.contains(oldID) {
            if let oldEvent = eventStore.event(withIdentifier: oldID) {
                do {
                    try eventStore.remove(oldEvent, span: .thisEvent, commit: false)
                    removedEventIDs.insert(oldID)
                    stagedRemovals += 1
                } catch {
                    var queue = preferences.pendingEKDeletions
                    queue.append(.init(channelRaw: channel.rawValue, eventIdentifier: oldID))
                    preferences.pendingEKDeletions = queue
                    operationFailures += 1
                    failureReason = error.localizedDescription
                }
            }
        }

        // 2. Scan existing Cozy-managed events on targetCalendar OWNED BY THIS CHANNEL ONLY
        //    (never touching OAuth-created Google events or another channel's events), and deduplicate!
        var existingByOccID: [UUID: EKEvent] = [:]
        let predicate = eventStore.predicateForEvents(withStart: minSyncDay, end: queryEnd, calendars: [targetCalendar])
        for event in eventStore.events(matching: predicate) {
            guard Self.eventBelongsToChannel(event, channel: channel) else {
                continue
            }
            if let occID = Self.extractCozyOccurrenceID(fromURL: event.url, notes: event.notes),
               activeIDs.contains(occID) {
                if existingByOccID[occID] == nil {
                    existingByOccID[occID] = event
                } else {
                    // Duplicate event for the same occurrence on this channel -> remove duplicate
                    do {
                        if let eid = event.eventIdentifier {
                            removedEventIDs.insert(eid)
                        }
                        try eventStore.remove(event, span: .thisEvent, commit: false)
                        stagedRemovals += 1
                    } catch {
                        operationFailures += 1
                        failureReason = error.localizedDescription
                    }
                }
            } else {
                do {
                    if let eid = event.eventIdentifier {
                        removedEventIDs.insert(eid)
                    }
                    try eventStore.remove(event, span: .thisEvent, commit: false)
                    stagedRemovals += 1
                } catch {
                    operationFailures += 1
                    failureReason = error.localizedDescription
                }
            }
        }

        // 3. Stage cleanup of tracked identifiers on skipped or out-of-window occurrences
        //    (retaining the saved event ID if removal fails!)
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
            if let staleEvent = eventStore.event(withIdentifier: savedID) {
                do {
                    try eventStore.remove(staleEvent, span: .thisEvent, commit: false)
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

        // 4. Stage upserts for active occurrences in open slots on targetCalendar
        for occ in activeWindowOccurrences {
            let effectiveDay = effectiveOccurrenceDay(occ)
            let slot = Self.assignSlotForTask(
                on: effectiveDay,
                durationMinutes: occ.displayDurationMinutes,
                preferredStartHour: preferences.googleTaskPushStartHour,
                wakingStartHour: preferences.wakingStartHour,
                wakingEndHour: preferences.wakingEndHour,
                existingBusyIntervals: placedByDay[effectiveDay] ?? [],
                calendar: calendar
            )
            placedByDay[effectiveDay, default: []].append(slot)

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

            let matchedExisting: EKEvent? = {
                if getDestination(occ) == destinationKey,
                   let savedID = getEventID(occ),
                   let fetched = eventStore.event(withIdentifier: savedID),
                   fetched.calendar.calendarIdentifier == targetCalendar.calendarIdentifier {
                    return fetched
                }
                return existingByOccID[occ.id]
            }()

            if let existing = matchedExisting,
               existing.calendar.calendarIdentifier == targetCalendar.calendarIdentifier,
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

            let event = matchedExisting ?? EKEvent(eventStore: eventStore)
            event.calendar = targetCalendar
            event.title = desiredTitle
            event.startDate = slot.0
            event.endDate = slot.1
            event.url = Self.makeCozyEventURL(channel: channel, occurrenceID: occ.id)
            event.notes = desiredNotes

            do {
                try eventStore.save(event, span: .thisEvent, commit: false)
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
                try eventStore.commit()
            } catch {
                eventStore.reset()
                return EKSyncOutcome(
                    upserted: 0,
                    removed: 0,
                    failed: operationFailures + stagedUpserts + stagedRemovals,
                    calendarTitle: targetCalendar.title,
                    errorMessage: "Calendar commit failed: \(error.localizedDescription)"
                )
            }
        }

        // 6. Commit succeeded: apply staged metadata & drain completed pending deletions
        for update in stagedMetadataUpdates {
            if update.clearMetadata {
                setEventID(update.occurrence, nil)
                setDestination(update.occurrence, nil)
                setSignature(update.occurrence, nil)
            } else if let eventID = update.eventRef?.eventIdentifier, !eventID.isEmpty {
                setEventID(update.occurrence, eventID)
                setDestination(update.occurrence, update.destinationKey)
                setSignature(update.occurrence, update.signature)
            }
        }

        if !drainedPendingItems.isEmpty {
            preferences.pendingEKDeletions = existingPendingQueue.filter { !drainedPendingItems.contains($0) }
        }

        return EKSyncOutcome(
            upserted: stagedUpserts,
            removed: stagedRemovals,
            failed: operationFailures,
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
        if event.url?.scheme?.lowercased() == cozyURLScheme {
            return true
        }
        if let notes = event.notes, notes.contains(cozyEventMarker) {
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
