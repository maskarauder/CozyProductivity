import EventKit
import Foundation
import Observation

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
            // Exclude CozyProductivity's own pushed task blocks so rebalances never treat our own tasks as external meetings
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

    /// Returns writable non-Google Apple / iCloud / local calendars on the iPhone (falling back to all writable calendars if needed).
    func writableAppleCalendars() -> [EKCalendar] {
        refreshAuthorizationStatus()
        guard hasReadAccess else { return [] }
        let googleIDs = Set(googleAccountCalendars().map(\.calendarIdentifier))
        let allWritable = eventStore.calendars(for: .event).filter { $0.allowsContentModifications }
        let nonGoogleWritable = allWritable.filter { !googleIDs.contains($0.calendarIdentifier) }
        return nonGoogleWritable.isEmpty ? allWritable : nonGoogleWritable
    }

    func targetAppleCalendar(
        preferredIdentifier: String,
        avoidCalendarIdentifier: String? = nil
    ) -> EKCalendar? {
        refreshAuthorizationStatus()
        guard hasReadAccess else { return nil }

        let allWritable = eventStore.calendars(for: .event).filter {
            $0.allowsContentModifications && $0.calendarIdentifier != avoidCalendarIdentifier
        }
        let trimmedPref = preferredIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPref.isEmpty,
           let chosen = allWritable.first(where: { $0.calendarIdentifier == trimmedPref }) {
            return chosen
        }

        let googleIDs = Set(googleAccountCalendars().map(\.calendarIdentifier))
        if let defaultCal = eventStore.defaultCalendarForNewEvents,
           defaultCal.allowsContentModifications,
           defaultCal.calendarIdentifier != avoidCalendarIdentifier,
           !googleIDs.contains(defaultCal.calendarIdentifier) {
            return defaultCal
        }

        if let firstNonGoogle = allWritable.first(where: { !googleIDs.contains($0.calendarIdentifier) }) {
            return firstNonGoogle
        }

        return allWritable.first
    }

    func syncOccurrencesToAppleCalendar(
        occurrences: [TaskOccurrence],
        busyIntervalsByDay: [Date: [(Date, Date)]],
        preferences: CozyPreferences,
        today referenceDate: Date = Date(),
        avoidCalendarIdentifier: String? = nil,
        calendar: Calendar = DateHelpers.calendar
    ) -> (upserted: Int, removed: Int, calendarTitle: String?) {
        guard let targetCalendar = targetAppleCalendar(
            preferredIdentifier: preferences.appleTargetCalendarIdentifier,
            avoidCalendarIdentifier: avoidCalendarIdentifier
        ) else {
            return (0, 0, nil)
        }

        let synced = syncOccurrencesToEKCalendar(
            targetCalendar: targetCalendar,
            occurrences: occurrences,
            busyIntervalsByDay: busyIntervalsByDay,
            preferences: preferences,
            today: referenceDate,
            calendar: calendar,
            getEventID: { $0.appleCalendarEventIdentifier },
            setEventID: { $0.appleCalendarEventIdentifier = $1 },
            getSignature: { $0.lastAppleCalendarSyncSignature },
            setSignature: { $0.lastAppleCalendarSyncSignature = $1 }
        )
        return (synced.upserted, synced.removed, targetCalendar.title)
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
        if let firstGoogle = googleCals.first {
            return firstGoogle
        }
        return eventStore.defaultCalendarForNewEvents
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
    ) -> (upserted: Int, removed: Int, calendarTitle: String?) {
        refreshAuthorizationStatus()
        guard hasReadAccess, let targetCalendar = writableGoogleBridgeCalendar() else {
            return (0, 0, nil)
        }

        let synced = syncOccurrencesToEKCalendar(
            targetCalendar: targetCalendar,
            occurrences: occurrences,
            busyIntervalsByDay: busyIntervalsByDay,
            preferences: preferences,
            today: referenceDate,
            calendar: calendar,
            getEventID: { $0.syncedEKEventIdentifier },
            setEventID: { $0.syncedEKEventIdentifier = $1 },
            getSignature: { $0.lastCalendarSyncSignature },
            setSignature: { $0.lastCalendarSyncSignature = $1 }
        )
        return (synced.upserted, synced.removed, targetCalendar.title)
    }

    private func syncOccurrencesToEKCalendar(
        targetCalendar: EKCalendar,
        occurrences: [TaskOccurrence],
        busyIntervalsByDay: [Date: [(Date, Date)]],
        preferences: CozyPreferences,
        today referenceDate: Date,
        calendar: Calendar,
        getEventID: (TaskOccurrence) -> String?,
        setEventID: (TaskOccurrence, String?) -> Void,
        getSignature: (TaskOccurrence) -> String?,
        setSignature: (TaskOccurrence, String?) -> Void
    ) -> (upserted: Int, removed: Int) {
        let today = DateHelpers.startOfDay(for: referenceDate, calendar: calendar)
        let minSyncDay = DateHelpers.addDays(-1, to: today, calendar: calendar)
        let maxSyncDay = DateHelpers.addDays(14, to: today, calendar: calendar)
        let queryEnd = calendar.date(byAdding: .day, value: 1, to: maxSyncDay) ?? maxSyncDay.addingTimeInterval(86400)

        var upserted = 0
        var removed = 0
        var removedEventIDs: Set<String> = []
        var placedByDay: [Date: [(Date, Date)]] = busyIntervalsByDay

        func effectiveOccurrenceDay(_ occ: TaskOccurrence) -> Date {
            DateHelpers.startOfDay(
                for: occ.isCompleted ? (occ.bonusForDate ?? occ.scheduledDate) : occ.scheduledDate,
                calendar: calendar
            )
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

        // 1. Scan existing Cozy-managed events on targetCalendar so deleted/deactivated/moved tasks are removed cleanly
        var existingByOccID: [UUID: EKEvent] = [:]
        let predicate = eventStore.predicateForEvents(withStart: minSyncDay, end: queryEnd, calendars: [targetCalendar])
        for event in eventStore.events(matching: predicate) where Self.isCozyManagedEvent(event) {
            if let occID = Self.extractCozyOccurrenceID(fromURL: event.url), activeIDs.contains(occID) {
                existingByOccID[occID] = event
            } else {
                if let eid = event.eventIdentifier {
                    removedEventIDs.insert(eid)
                }
                if (try? eventStore.remove(event, span: .thisEvent, commit: false)) != nil {
                    removed += 1
                }
            }
        }

        // 2. Clean up tracked identifiers on skipped or out-of-window occurrences
        for occ in occurrences where !activeIDs.contains(occ.id) {
            if let savedID = getEventID(occ) {
                if !removedEventIDs.contains(savedID),
                   let staleEvent = eventStore.event(withIdentifier: savedID) {
                    removedEventIDs.insert(savedID)
                    if (try? eventStore.remove(staleEvent, span: .thisEvent, commit: false)) != nil {
                        removed += 1
                    }
                }
                setEventID(occ, nil)
                setSignature(occ, nil)
            }
        }

        // 3. Upsert active occurrences in open slots on targetCalendar
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
            let desiredNotes = "\(notesHeader)Scheduled by Cozy (\(occ.recurrenceLabel) · \(occ.displayWeight.badgeLabel)\(deadlineNote)) \(Self.cozyEventMarker)"
            let signature = Self.buildCalendarSyncSignature(
                calendarID: targetCalendar.calendarIdentifier,
                start: slot.0,
                end: slot.1,
                title: desiredTitle,
                notes: desiredNotes
            )

            let matchedExisting: EKEvent? = {
                if let savedID = getEventID(occ), let fetched = eventStore.event(withIdentifier: savedID) {
                    return fetched
                }
                return existingByOccID[occ.id]
            }()

            if let existing = matchedExisting,
               existing.calendar.calendarIdentifier == targetCalendar.calendarIdentifier,
               getSignature(occ) == signature {
                setEventID(occ, existing.eventIdentifier)
                continue
            }

            let event = matchedExisting ?? EKEvent(eventStore: eventStore)
            event.calendar = targetCalendar
            event.title = desiredTitle
            event.startDate = slot.0
            event.endDate = slot.1
            event.url = URL(string: "\(Self.cozyURLScheme)://occurrence/\(occ.id.uuidString)")
            event.notes = desiredNotes

            do {
                try eventStore.save(event, span: .thisEvent, commit: false)
                setEventID(occ, event.eventIdentifier)
                setSignature(occ, signature)
                upserted += 1
            } catch {
                continue
            }
        }

        if upserted > 0 || removed > 0 {
            try? eventStore.commit()
        }

        return (upserted, removed)
    }

    // MARK: - Pure Testable Interval Merging & Slot Placement Helpers

    nonisolated static func isCozyManagedEvent(_ event: EKEvent) -> Bool {
        if event.url?.scheme?.lowercased() == cozyURLScheme {
            return true
        }
        if let notes = event.notes, notes.contains(cozyEventMarker) {
            return true
        }
        return false
    }

    nonisolated static func extractCozyOccurrenceID(fromURL url: URL?) -> UUID? {
        guard let url, url.scheme?.lowercased() == cozyURLScheme else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    nonisolated static func buildCalendarSyncSignature(
        calendarID: String,
        start: Date,
        end: Date,
        title: String,
        notes: String
    ) -> String {
        "\(calendarID)|\(Int(start.timeIntervalSince1970))|\(Int(end.timeIntervalSince1970))|\(title)|\(notes)"
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
