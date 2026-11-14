import AppIntents
import Foundation
import SwiftData

// MARK: - Siri Recurrence Enum

enum SiriRecurrenceOption: String, AppEnum {
    case once
    case daily
    case weekly
    case biweekly
    case monthly

    static var typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "Task Frequency")

    static var caseDisplayRepresentations: [SiriRecurrenceOption: DisplayRepresentation] = [
        .once: DisplayRepresentation(title: "Once"),
        .daily: DisplayRepresentation(title: "Daily"),
        .weekly: DisplayRepresentation(title: "Weekly"),
        .biweekly: DisplayRepresentation(title: "Every 2 Weeks"),
        .monthly: DisplayRepresentation(title: "Monthly")
    ]

    var recurrenceKind: RecurrenceKind {
        switch self {
        case .once: return .once
        case .daily: return .daily
        case .weekly: return .weekly
        case .biweekly: return .biweekly
        case .monthly: return .monthly
        }
    }
}

// MARK: - Today's Task AppEntity for Siri Disambiguation & Voice Matching

struct TodayTaskEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "Cozy Task")
    static var defaultQuery = TodayTaskEntityQuery()

    var id: String
    var title: String
    var subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)"
        )
    }
}

struct TodayTaskEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TodayTaskEntity] {
        let idSet = Set(identifiers)
        return await MainActor.run {
            let context = CozyModelContainer.shared.mainContext
            let occurrences = (try? context.fetch(FetchDescriptor<TaskOccurrence>())) ?? []
            return occurrences
                .filter { idSet.contains($0.id.uuidString) }
                .map { Self.makeEntity(from: $0) }
        }
    }

    func suggestedEntities() async throws -> [TodayTaskEntity] {
        await MainActor.run {
            Self.pendingTodayEntities()
        }
    }

    func entities(matching string: String) async throws -> [TodayTaskEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return await MainActor.run {
            let candidates = Self.pendingTodayEntities()
            guard !needle.isEmpty else { return candidates }
            return candidates.filter { entity in
                entity.title.lowercased().contains(needle)
            }
        }
    }

    @MainActor
    private static func pendingTodayEntities() -> [TodayTaskEntity] {
        let context = CozyModelContainer.shared.mainContext
        let prefs = CozyModelContainer.fetchOrCreatePreferences(in: context)
        let today = DateHelpers.startOfDay(for: Date())
        let occurrences = (try? context.fetch(FetchDescriptor<TaskOccurrence>())) ?? []

        StreakAndBonusService.syncBonusSlots(
            context: context,
            occurrences: occurrences,
            preferences: prefs,
            today: today
        )

        let basePending = occurrences.filter {
            $0.status == .pending
                && $0.bonusForDate == nil
                && DateHelpers.isSameDay($0.scheduledDate, today)
        }
        let bonusPending = occurrences
            .filter {
                $0.status == .pending
                    && ($0.bonusForDate.map { DateHelpers.isSameDay($0, today) } ?? false)
            }
            .sorted { $0.bonusSlot < $1.bonusSlot }

        return (basePending + bonusPending).map { makeEntity(from: $0) }
    }

    @MainActor
    private static func makeEntity(from occ: TaskOccurrence) -> TodayTaskEntity {
        let bonusPrefix = occ.bonusForDate != nil ? "Bonus #\(max(1, occ.bonusSlot)) · " : ""
        let subtitle = "\(bonusPrefix)\(DateHelpers.formatDuration(minutes: occ.displayDurationMinutes)) · \(occ.recurrenceLabel)"
        return TodayTaskEntity(
            id: occ.id.uuidString,
            title: "\(occ.displayEmoji) \(occ.displayTitle)",
            subtitle: subtitle
        )
    }
}

// MARK: - 1. Add Cozy Task Intent

struct AddCozyTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a Cozy Task"
    static var description = IntentDescription(
        "Creates a Once or recurring task with a duration and distributes it onto a day with more free time."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Task Title",
        requestValueDialog: IntentDialog("What cozy task would you like to add?")
    )
    var title: String

    @Parameter(title: "Frequency", default: .once)
    var recurrence: SiriRecurrenceOption

    @Parameter(title: "Duration (Minutes)", default: 30)
    var durationMinutes: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            return .result(dialog: "Please tell me a name for your cozy task.")
        }
        let clampedDuration = max(5, min(360, durationMinutes))
        let kind = recurrence.recurrenceKind

        let spokenResponse: String = await { @MainActor in
            let context = CozyModelContainer.shared.mainContext
            let prefs = CozyModelContainer.fetchOrCreatePreferences(in: context)
            let today = DateHelpers.startOfDay(for: Date())

            let template = TaskTemplate(
                title: cleanTitle,
                emoji: "🌸",
                category: .selfCare,
                recurrence: kind,
                durationMinutes: clampedDuration,
                isAutoScheduled: kind != .daily,
                anchorDate: today,
                flexibleWindowDays: 7
            )
            context.insert(template)
            try? context.save()

            _ = await GoogleCalendarService.shared.syncCalendarsAndRebalance(
                context: context,
                preferences: prefs,
                referenceDate: today
            )

            let occurrences = (try? context.fetch(FetchDescriptor<TaskOccurrence>())) ?? []
            let firstScheduled = occurrences
                .filter { $0.template?.id == template.id && $0.status == .pending }
                .sorted { $0.scheduledDate < $1.scheduledDate }
                .first

            let durLabel = DateHelpers.formatDuration(minutes: clampedDuration)
            if let placed = firstScheduled {
                let dayText = DateHelpers.isSameDay(placed.scheduledDate, today)
                    ? "today"
                    : DateHelpers.fullHeaderDateString(for: placed.scheduledDate)
                return "Added “\(cleanTitle)” (\(kind.title), \(durLabel)) and scheduled it for \(dayText) based on your open time."
            } else {
                return "Added “\(cleanTitle)” (\(kind.title), \(durLabel)) to your Cozy Tasks."
            }
        }()

        return .result(dialog: IntentDialog("\(spokenResponse)"))
    }
}

// MARK: - 2. Complete Cozy Task Intent

struct CompleteCozyTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete a Cozy Task"
    static var description = IntentDescription(
        "Checks off one of today's tasks or optional bonus tasks and updates your calendar medal and streak."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Task",
        requestValueDialog: IntentDialog("Which task did you finish today?")
    )
    var task: TodayTaskEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let targetID = task.id

        let spokenResponse: String = await { @MainActor in
            let context = CozyModelContainer.shared.mainContext
            let prefs = CozyModelContainer.fetchOrCreatePreferences(in: context)
            let today = DateHelpers.startOfDay(for: Date())
            let occurrences = (try? context.fetch(FetchDescriptor<TaskOccurrence>())) ?? []

            guard let matched = occurrences.first(where: { $0.id.uuidString == targetID }) else {
                return "I couldn't find that task on today's checklist."
            }

            matched.isCompleted = true
            try? context.save()

            StreakAndBonusService.syncBonusSlots(
                context: context,
                occurrences: occurrences,
                preferences: prefs,
                today: today
            )

            let snapshot = StreakAndBonusService.evaluate(
                occurrences: occurrences,
                persistedLongestStreak: prefs.longestRecordedStreak,
                today: today
            )
            if snapshot.longestStreak > prefs.longestRecordedStreak {
                prefs.longestRecordedStreak = snapshot.longestStreak
                try? context.save()
            }

            if prefs.pushTasksToGoogleCalendar || prefs.useGoogleCalendarSync {
                _ = await GoogleCalendarService.shared.syncCalendarsAndRebalance(
                    context: context,
                    preferences: prefs,
                    referenceDate: today
                )
            } else {
                await NotificationManager.shared.syncSummaryNotifications(
                    preferences: prefs,
                    occurrences: occurrences
                )
            }

            let tier = snapshot.tier(for: today)
            switch tier {
            case .gold:
                let s = snapshot.currentStreak
                return "PERFECT! Checked off \(matched.displayTitle). Today is highlighted in Gold and your streak is Streak Days \(s)!"
            case .silver:
                let s = snapshot.currentStreak
                return "Checked off bonus task \(matched.displayTitle)! Today is highlighted in Silver and your \(s)-day streak is preserved."
            case .base:
                return "Checked off \(matched.displayTitle)! All of today's tasks are complete—two optional bonus tasks are ready if you want Silver or Gold."
            case .none:
                let remaining = occurrences.filter {
                    $0.status == .pending && $0.bonusForDate == nil && DateHelpers.isSameDay($0.scheduledDate, today)
                }.count
                return "Checked off \(matched.displayTitle)! \(remaining) task\(remaining == 1 ? "" : "s") left on today's checklist."
            }
        }()

        return .result(dialog: IntentDialog("\(spokenResponse)"))
    }
}

// MARK: - 3. Read Today's Checklist Intent

struct ReadTodaysChecklistIntent: AppIntent {
    static var title: LocalizedStringResource = "Read Today's Cozy Checklist"
    static var description = IntentDescription("Reads out your remaining tasks, bonus tasks, and minutes for today.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let spokenResponse: String = await MainActor.run {
            let context = CozyModelContainer.shared.mainContext
            let prefs = CozyModelContainer.fetchOrCreatePreferences(in: context)
            let today = DateHelpers.startOfDay(for: Date())
            let occurrences = (try? context.fetch(FetchDescriptor<TaskOccurrence>())) ?? []

            StreakAndBonusService.syncBonusSlots(
                context: context,
                occurrences: occurrences,
                preferences: prefs,
                today: today
            )

            let baseToday = occurrences.filter {
                $0.status != .skipped && $0.bonusForDate == nil && DateHelpers.isSameDay($0.scheduledDate, today)
            }
            let pendingBase = baseToday.filter { !$0.isCompleted }
            let bonusToday = occurrences
                .filter { $0.status != .skipped && ($0.bonusForDate.map { DateHelpers.isSameDay($0, today) } ?? false) }
                .sorted { $0.bonusSlot < $1.bonusSlot }
            let pendingBonus = bonusToday.filter { !$0.isCompleted }

            if baseToday.isEmpty {
                return "Your checklist is wide open today—no tasks scheduled yet."
            }

            if pendingBase.isEmpty {
                if pendingBonus.isEmpty {
                    return "You finished everything today, including your bonus tasks—it's a Gold PERFECT day!"
                }
                let bonusNames = pendingBonus.map(\.displayTitle).joined(separator: " and ")
                return "All \(baseToday.count) daily tasks are done! Optional bonus tasks available for Silver or Gold: \(bonusNames)."
            }

            let totalMinutes = pendingBase.reduce(0) { $0 + $1.displayDurationMinutes }
            let names = pendingBase.prefix(4).map(\.displayTitle).joined(separator: ", ")
            let durText = DateHelpers.formatDuration(minutes: totalMinutes)
            return "You have \(pendingBase.count) task\(pendingBase.count == 1 ? "" : "s") left today (\(durText)): \(names)."
        }

        return .result(dialog: IntentDialog("\(spokenResponse)"))
    }
}

// MARK: - 4. Check Cozy Streak Intent

struct CheckCozyStreakIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Cozy Streak"
    static var description = IntentDescription("Speaks your current streak, longest recorded streak, and today's medal tier.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let spokenResponse: String = await MainActor.run {
            let context = CozyModelContainer.shared.mainContext
            let prefs = CozyModelContainer.fetchOrCreatePreferences(in: context)
            let today = DateHelpers.startOfDay(for: Date())
            let occurrences = (try? context.fetch(FetchDescriptor<TaskOccurrence>())) ?? []

            let snapshot = StreakAndBonusService.evaluate(
                occurrences: occurrences,
                persistedLongestStreak: prefs.longestRecordedStreak,
                today: today
            )
            let todayBadge = snapshot.tier(for: today).badgeTitle(baseStyle: prefs.baseHighlightStyle)
            return "Current streak: \(snapshot.currentStreak) day\(snapshot.currentStreak == 1 ? "" : "s"). Longest recorded streak: \(snapshot.longestStreak) day\(snapshot.longestStreak == 1 ? "" : "s"). Today's status: \(todayBadge)."
        }

        return .result(dialog: IntentDialog("\(spokenResponse)"))
    }
}

// MARK: - 5. Sync Google Calendar & Balance Schedule Intent

struct SyncAndRebalanceIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Google Calendar & Balance Tasks"
    static var description = IntentDescription(
        "Reads busy blocks from Google Calendar and Apple Calendar, rebalances flexible tasks onto freer days, and pushes tasks back to Google Calendar."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let spokenResponse: String = await { @MainActor in
            let context = CozyModelContainer.shared.mainContext
            let prefs = CozyModelContainer.fetchOrCreatePreferences(in: context)
            let report = await GoogleCalendarService.shared.syncCalendarsAndRebalance(
                context: context,
                preferences: prefs,
                referenceDate: Date()
            )
            return report.statusMessage
        }()

        return .result(dialog: IntentDialog("\(spokenResponse)"))
    }
}

// MARK: - AppShortcutsProvider Registration for Siri & Shortcuts App

struct CozyAppShortcutsProvider: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .pink

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddCozyTaskIntent(),
            phrases: [
                "Add a task in \(.applicationName)",
                "Create a cozy task in \(.applicationName)",
                "Schedule a \(\.$recurrence) task in \(.applicationName)"
            ],
            shortTitle: "Add Cozy Task",
            systemImageName: "plus.circle.fill"
        )
        AppShortcut(
            intent: CompleteCozyTaskIntent(),
            phrases: [
                "Complete a task in \(.applicationName)",
                "Check off a task in \(.applicationName)",
                "Finish a task in \(.applicationName)"
            ],
            shortTitle: "Complete Task",
            systemImageName: "checkmark.circle.fill"
        )
        AppShortcut(
            intent: ReadTodaysChecklistIntent(),
            phrases: [
                "What's on my \(.applicationName) today",
                "Read today's checklist in \(.applicationName)",
                "Show my tasks in \(.applicationName)"
            ],
            shortTitle: "Today's Checklist",
            systemImageName: "checklist.checked"
        )
        AppShortcut(
            intent: CheckCozyStreakIntent(),
            phrases: [
                "Check my streak in \(.applicationName)",
                "What is my streak in \(.applicationName)"
            ],
            shortTitle: "Check Streak",
            systemImageName: "flame.fill"
        )
        AppShortcut(
            intent: SyncAndRebalanceIntent(),
            phrases: [
                "Sync Google Calendar in \(.applicationName)",
                "Balance my schedule in \(.applicationName)"
            ],
            shortTitle: "Sync & Balance",
            systemImageName: "arrow.triangle.2.circlepath.circle.fill"
        )
    }
}
