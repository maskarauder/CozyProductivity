import EventKit
import Foundation
import Observation

@MainActor
@Observable
final class CalendarFreeTimeService {
    static let shared = CalendarFreeTimeService()

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

    /// Computes busy minutes per start-of-day Date within `[startDate ... endDate]`,
    /// merging overlapping events inside the configured `[wakingStartHour ... wakingEndHour]` window.
    func busyMinutesByDay(
        from startDate: Date,
        to endDate: Date,
        wakingStartHour: Int,
        wakingEndHour: Int,
        calendar: Calendar = DateHelpers.calendar
    ) -> [Date: Int] {
        refreshAuthorizationStatus()
        guard hasReadAccess else { return [:] }

        let firstDay = DateHelpers.startOfDay(for: startDate, calendar: calendar)
        let lastDay = DateHelpers.startOfDay(for: endDate, calendar: calendar)
        guard let queryEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) else {
            return [:]
        }

        let predicate = eventStore.predicateForEvents(withStart: firstDay, end: queryEnd, calendars: nil)
        let events = eventStore.events(matching: predicate)

        let totalDays = max(0, DateHelpers.daysBetween(firstDay, and: lastDay, calendar: calendar))
        var result: [Date: Int] = [:]

        let clampedStartHour = max(0, min(22, wakingStartHour))
        let clampedEndHour = max(clampedStartHour + 1, min(24, wakingEndHour))

        for offset in 0...totalDays {
            let day = DateHelpers.addDays(offset, to: firstDay, calendar: calendar)
            guard
                let windowStart = calendar.date(byAdding: .hour, value: clampedStartHour, to: day),
                let windowEnd = calendar.date(byAdding: .hour, value: clampedEndHour, to: day)
            else {
                continue
            }

            var intervals: [(Date, Date)] = []
            for event in events {
                // Skip all-day banners or events explicitly marked "Free"
                if event.isAllDay || event.availability == .free {
                    continue
                }
                let clippedStart = max(windowStart, event.startDate)
                let clippedEnd = min(windowEnd, event.endDate)
                if clippedEnd > clippedStart {
                    intervals.append((clippedStart, clippedEnd))
                }
            }

            let mergedMinutes = Self.mergedDurationMinutes(for: intervals)
            if mergedMinutes > 0 {
                result[day] = mergedMinutes
            }
        }

        return result
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
}
