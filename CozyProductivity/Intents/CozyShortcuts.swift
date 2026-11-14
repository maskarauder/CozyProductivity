import AppIntents
import Foundation
import SwiftData

// MARK: - Siri Recurrence & Weight Enums

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

enum SiriTaskWeightOption: String, AppEnum {
    case light
    case normal
    case heavy

    static var typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "Task Weight")

    static var caseDisplayRepresentations: [SiriTaskWeightOption: DisplayRepresentation] = [
        .light: DisplayRepresentation(title: "Light", subtitle: "+0m ranking weight"),
        .normal: DisplayRepresentation(title: "Normal", subtitle: "+30m ranking weight"),
        .heavy: DisplayRepresentation(title: "Heavy", subtitle: "+1h ranking weight")
    ]

    var taskWeight: TaskWeight {
        switch self {
        case .light: return .light
        case .normal: return .normal
        case .heavy: return .heavy
        }
    }
}

// MARK: - Natural-Language Siri Task Phrase Parser

struct ParsedSiriTask: Equatable {
    let title: String
    let weight: TaskWeight
    let durationMinutes: Int
    let recurrence: RecurrenceKind
}

enum SiriTaskPhraseParser {
    private static let allowedHeaderWords: Set<String> = [
        "hey", "siri", "please", "can", "you", "could",
        "add", "create", "schedule", "make", "put", "set", "new",
        "a", "an", "my", "the", "cozy", "in", "on", "into", "with",
        "light", "lightweight", "easy",
        "normal", "medium", "regular", "standard",
        "heavy", "hard", "big",
        "once", "daily", "everyday", "weekly", "biweekly", "monthly",
        "every", "day", "week", "weeks", "month",
        "and", "half",
        "hour", "hours", "hr", "hrs",
        "minute", "minutes", "min", "mins",
        "one", "two", "three", "four", "five", "six",
        "ten", "fifteen", "twenty", "thirty", "forty", "fifty", "sixty", "ninety"
    ]

    /// Parses spoken phrases like:
    /// - `"to take out the trash"` -> `("Take out the trash", .light, 30, .once)`
    /// - `"Add a Cozy task to take out the trash"` -> `("Take out the trash", .light, 30, .once)`
    /// - `"Add a heavy 1-hour task to take out the trash"` -> `("Take out the trash", .heavy, 60, .once)`
    static func parse(
        rawInput: String,
        defaultWeight: TaskWeight = .light,
        defaultDurationMinutes: Int = 30,
        defaultRecurrence: RecurrenceKind = .once
    ) -> ParsedSiriTask {
        let clampedDefaultDuration = max(5, min(360, defaultDurationMinutes))
        var working = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty else {
            return ParsedSiriTask(
                title: "",
                weight: defaultWeight,
                durationMinutes: clampedDefaultDuration,
                recurrence: defaultRecurrence
            )
        }

        // Strip leading "Hey Siri," / "Siri," if present
        working = working.replacingOccurrences(
            of: #"^(?:hey\s+siri|siri)[,:\s]+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Strip trailing "." or "!" from speech dictation
        while let last = working.last, last == "." || last == "!" {
            working.removeLast()
        }
        working = working.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip trailing "in Cozy" / "in Cozy Tasks"
        working = working.replacingOccurrences(
            of: #"\s+(?:in|on|into|with)\s+cozy(?:\s+tasks?)?$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        var extractedHeader: String? = nil
        var bodyText = working

        // 1. Check `<header> task(s) [in cozy] [to|for|called|named|:|-] <body>`
        if let match = firstRegexCapture(
            pattern: #"^(.*?)\btasks?\b(?:\s+(?:in|for|on)\s+cozy)?(?:\s+(?:to|for|called|named)|[:\-–—])?\s+(.+)$"#,
            in: working
        ) {
            let candidateHeader = match.0.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateBody = match.1.trimmingCharacters(in: .whitespacesAndNewlines)
            if isPureMetadataHeader(candidateHeader) && !candidateBody.isEmpty {
                extractedHeader = candidateHeader
                bodyText = candidateBody
            }
        }

        // 2. If `task` was omitted (e.g. "Add a heavy 1-hour to take out the trash"), check `<non-empty metadata header> to <body>`
        if extractedHeader == nil,
           let match = firstRegexCapture(
               pattern: #"^(.+?)\s+to\s+(.+)$"#,
               in: working
           ) {
            let candidateHeader = match.0.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateBody = match.1.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidateHeader.isEmpty && isPureMetadataHeader(candidateHeader) && !candidateBody.isEmpty {
                extractedHeader = candidateHeader
                bodyText = candidateBody
            }
        }

        // 3. Strip standalone leading "to " (e.g. Siri matched "Add a Cozy task" and captured "to take out the trash")
        if extractedHeader == nil {
            bodyText = bodyText.replacingOccurrences(
                of: #"^to\s+"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var resolvedWeight = defaultWeight
        var resolvedDuration = clampedDefaultDuration
        var resolvedRecurrence = defaultRecurrence

        if let header = extractedHeader, !header.isEmpty {
            if let parsedWeight = extractWeight(from: header) {
                resolvedWeight = parsedWeight
            }
            if let parsedDuration = extractDurationMinutes(from: header) {
                resolvedDuration = max(5, min(360, parsedDuration))
            }
            if let parsedRecurrence = extractRecurrence(from: header) {
                resolvedRecurrence = parsedRecurrence
            }
        }

        let cleanTitle = capitalizeFirstCharacter(bodyText.trimmingCharacters(in: .whitespacesAndNewlines))
        return ParsedSiriTask(
            title: cleanTitle,
            weight: resolvedWeight,
            durationMinutes: resolvedDuration,
            recurrence: resolvedRecurrence
        )
    }

    private static func isPureMetadataHeader(_ header: String) -> Bool {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        let tokens = trimmed
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".")).inverted)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return true }
        for token in tokens {
            if allowedHeaderWords.contains(token) { continue }
            if Double(token) != nil { continue }
            if token.range(
                of: #"^\d+(?:\.\d+)?(?:h|hr|hrs|hour|hours|m|min|mins|minute|minutes)$"#,
                options: .regularExpression
            ) != nil {
                continue
            }
            return false
        }
        return true
    }

    private static func extractWeight(from header: String) -> TaskWeight? {
        let lower = " " + header.lowercased() + " "
        if lower.range(of: #"\b(?:heavy|hard|big)\b"#, options: .regularExpression) != nil {
            return .heavy
        }
        if lower.range(of: #"\b(?:normal|medium|regular|standard)\b"#, options: .regularExpression) != nil {
            return .normal
        }
        if lower.range(of: #"\b(?:light|lightweight|easy)\b"#, options: .regularExpression) != nil {
            return .light
        }
        return nil
    }

    private static func extractRecurrence(from header: String) -> RecurrenceKind? {
        let lower = header.lowercased()
        if lower.range(of: #"\b(?:biweekly|every\s+(?:2|two)\s+weeks?)\b"#, options: .regularExpression) != nil {
            return .biweekly
        }
        if lower.range(of: #"\b(?:daily|everyday|every\s+day)\b"#, options: .regularExpression) != nil {
            return .daily
        }
        if lower.range(of: #"\b(?:weekly|every\s+week)\b"#, options: .regularExpression) != nil {
            return .weekly
        }
        if lower.range(of: #"\b(?:monthly|every\s+month)\b"#, options: .regularExpression) != nil {
            return .monthly
        }
        if lower.range(of: #"\bonce\b"#, options: .regularExpression) != nil {
            return .once
        }
        return nil
    }

    private static func extractDurationMinutes(from header: String) -> Int? {
        var norm = header.lowercased()
        let compoundNumbers: [(String, String)] = [
            ("forty-five", "45"), ("forty five", "45"),
            ("thirty-five", "35"), ("thirty five", "35"),
            ("twenty-five", "25"), ("twenty five", "25"),
            ("ninety", "90"), ("sixty", "60"), ("fifty", "50"),
            ("forty", "40"), ("thirty", "30"), ("twenty", "20"),
            ("fifteen", "15"), ("ten", "10"),
            ("six", "6"), ("five", "5"), ("four", "4"),
            ("three", "3"), ("two", "2"), ("one", "1")
        ]
        for (word, digits) in compoundNumbers {
            norm = norm.replacingOccurrences(
                of: "\\b\(word)\\b",
                with: digits,
                options: .regularExpression
            )
        }
        norm = norm.replacingOccurrences(of: "-", with: " ")

        if norm.range(of: #"\b(?:an\s+|1\s+)?hour\s+and\s+a\s+half\b"#, options: .regularExpression) != nil
            || norm.range(of: #"\b1\s+and\s+a\s+half\s+hours?\b"#, options: .regularExpression) != nil {
            return 90
        }
        if norm.range(of: #"\bhalf\s+(?:an\s+)?hour\b"#, options: .regularExpression) != nil {
            return 30
        }
        if let hm = firstRegexCapture(
            pattern: #"(\d+)\s*(?:hours?|hrs?|h)\s*(?:and\s*)?(\d+)\s*(?:minutes?|mins?|m)\b"#,
            in: norm
        ), let h = Int(hm.0), let m = Int(hm.1) {
            return h * 60 + m
        }
        if let hOnly = firstRegexSingleCapture(
            pattern: #"(\d+(?:\.\d+)?)\s*(?:hours?|hrs?|h)\b"#,
            in: norm
        ), let hours = Double(hOnly) {
            return Int((hours * 60.0).rounded())
        }
        if norm.range(of: #"\ban\s+hour\b"#, options: .regularExpression) != nil {
            return 60
        }
        if let mOnly = firstRegexSingleCapture(
            pattern: #"(\d+)\s*(?:minutes?|mins?|m)\b"#,
            in: norm
        ), let mins = Int(mOnly) {
            return mins
        }
        return nil
    }

    private static func capitalizeFirstCharacter(_ text: String) -> String {
        guard let first = text.first else { return "" }
        return String(first).uppercased() + text.dropFirst()
    }

    private static func firstRegexCapture(pattern: String, in text: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges >= 3,
              let r1 = Range(match.range(at: 1), in: text),
              let r2 = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return (String(text[r1]), String(text[r2]))
    }

    private static func firstRegexSingleCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges >= 2,
              let r1 = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[r1])
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
        let today = DateHelpers.logicalToday()
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
        let bonusPending: [TaskOccurrence]
        if prefs.optionalBonusTasksEnabled {
            bonusPending = occurrences
                .filter {
                    $0.status == .pending
                        && ($0.bonusForDate.map { DateHelpers.isSameDay($0, today) } ?? false)
                }
                .sorted { $0.bonusSlot < $1.bonusSlot }
        } else {
            bonusPending = []
        }

        return (basePending + bonusPending).map { makeEntity(from: $0) }
    }

    @MainActor
    private static func makeEntity(from occ: TaskOccurrence) -> TodayTaskEntity {
        let bonusPrefix = occ.bonusForDate != nil ? "Bonus #\(max(1, occ.bonusSlot)) · " : ""
        let subtitle = "\(bonusPrefix)\(DateHelpers.formatDuration(minutes: occ.displayDurationMinutes)) · \(occ.displayWeight.badgeLabel) · \(occ.recurrenceLabel)"
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
        "Creates a Cozy task (defaulting to Light, 30 minutes, Once) or parses spoken weight and duration like “Add a heavy 1-hour task to take out the trash”."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Task",
        requestValueDialog: IntentDialog("What task would you like to add?")
    )
    var title: String

    @Parameter(title: "Frequency", default: .once)
    var recurrence: SiriRecurrenceOption

    @Parameter(title: "Weight", default: .light)
    var weight: SiriTaskWeightOption

    @Parameter(title: "Duration (Minutes)", default: 30)
    var durationMinutes: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let parsed = SiriTaskPhraseParser.parse(
            rawInput: title,
            defaultWeight: weight.taskWeight,
            defaultDurationMinutes: durationMinutes,
            defaultRecurrence: recurrence.recurrenceKind
        )
        guard !parsed.title.isEmpty else {
            return .result(dialog: "Please tell me a name for your task.")
        }

        let cleanTitle = parsed.title
        let clampedDuration = parsed.durationMinutes
        let kind = parsed.recurrence
        let selectedWeight = parsed.weight

        let spokenResponse: String = await { @MainActor in
            let context = CozyModelContainer.shared.mainContext
            let prefs = CozyModelContainer.fetchOrCreatePreferences(in: context)
            let today = DateHelpers.logicalToday()

            let template = TaskTemplate(
                title: cleanTitle,
                emoji: "🌸",
                category: .selfCare,
                recurrence: kind,
                durationMinutes: clampedDuration,
                weight: selectedWeight,
                isAutoScheduled: kind != .daily,
                anchorDate: today,
                flexibleWindowDays: 7
            )
            context.insert(template)
            try? context.save()

            if prefs.shouldAutoSyncCalendarsOnChange {
                _ = await GoogleCalendarService.shared.syncCalendarsAndRebalance(
                    context: context,
                    preferences: prefs,
                    referenceDate: today
                )
            } else {
                SmartScheduler.rebalance(
                    context: context,
                    preferences: prefs,
                    referenceDate: today
                )
                let latest = (try? context.fetch(FetchDescriptor<TaskOccurrence>())) ?? []
                await NotificationManager.shared.syncSummaryNotifications(
                    preferences: prefs,
                    occurrences: latest
                )
            }

            let occurrences = (try? context.fetch(FetchDescriptor<TaskOccurrence>())) ?? []
            let firstScheduled = occurrences
                .filter { $0.template?.id == template.id && $0.status == .pending }
                .sorted { $0.scheduledDate < $1.scheduledDate }
                .first

            let durLabel = DateHelpers.formatDuration(minutes: clampedDuration)
            if prefs.addFriendlyMode {
                if let placed = firstScheduled {
                    let dayText = DateHelpers.isSameDay(placed.scheduledDate, today)
                        ? "today"
                        : DateHelpers.shortMonthDayString(for: placed.scheduledDate)
                    return "Added \(cleanTitle) (\(durLabel), \(selectedWeight.title)) for \(dayText)."
                }
                return "Added \(cleanTitle) (\(durLabel), \(selectedWeight.title))."
            }

            if let placed = firstScheduled {
                let dayText = DateHelpers.isSameDay(placed.scheduledDate, today)
                    ? "today"
                    : DateHelpers.fullHeaderDateString(for: placed.scheduledDate)
                return "Added “\(cleanTitle)” (\(kind.title), \(durLabel), \(selectedWeight.badgeLabel)) and scheduled it for \(dayText)."
            } else {
                return "Added “\(cleanTitle)” (\(kind.title), \(durLabel), \(selectedWeight.badgeLabel)) to Cozy."
            }
        }()

        return .result(dialog: IntentDialog("\(spokenResponse)"))
    }
}

// MARK: - 2. Set Daily Cup Intent ("How full is your cup today?" 0–5h)

struct SetDailyCupIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Daily Cup"
    static var description = IntentDescription(
        "Answers “How full is your cup today?” between 0 and 5 hours (resetting at 4 AM) and rebalances today's schedule."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Cup Hours (0 to 5)",
        requestValueDialog: IntentDialog("How full is your cup today, from 0 to 5 hours?")
    )
    var hours: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let clampedHours = max(0, min(5, hours))

        let spokenResponse: String = await { @MainActor in
            let context = CozyModelContainer.shared.mainContext
            let prefs = CozyModelContainer.fetchOrCreatePreferences(in: context)
            let today = DateHelpers.logicalToday()

            prefs.recordCupCheckIn(hours: clampedHours, for: today)
            try? context.save()

            if prefs.shouldAutoSyncCalendarsOnChange {
                _ = await GoogleCalendarService.shared.syncCalendarsAndRebalance(
                    context: context,
                    preferences: prefs,
                    referenceDate: today
                )
            } else {
                SmartScheduler.rebalance(
                    context: context,
                    preferences: prefs,
                    referenceDate: today
                )
                let latest = (try? context.fetch(FetchDescriptor<TaskOccurrence>())) ?? []
                await NotificationManager.shared.syncSummaryNotifications(
                    preferences: prefs,
                    occurrences: latest
                )
            }

            let occurrences = (try? context.fetch(FetchDescriptor<TaskOccurrence>())) ?? []
            let todayPending = occurrences.filter {
                $0.status == .pending && $0.bonusForDate == nil && DateHelpers.isSameDay($0.scheduledDate, today)
            }

            if prefs.addFriendlyMode {
                return "\(clampedHours) \(clampedHours == 1 ? "hour" : "hours") set. \(todayPending.count) task\(todayPending.count == 1 ? "" : "s") today."
            }

            if clampedHours == 0 {
                if todayPending.isEmpty {
                    return "Set your cup to 0 hours today. All non-deadline tasks have been gently moved back a day so you can rest."
                } else {
                    return "Set your cup to 0 hours. Non-deadline tasks moved back, and \(todayPending.count) hard-deadline task\(todayPending.count == 1 ? "" : "s") remain due today."
                }
            }
            return "Set your cup to \(clampedHours) hour\(clampedHours == 1 ? "" : "s") today. You have \(todayPending.count) task\(todayPending.count == 1 ? "" : "s") scheduled for today."
        }()

        return .result(dialog: IntentDialog("\(spokenResponse)"))
    }
}

// MARK: - 3. Complete Cozy Task Intent

struct CompleteCozyTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete a Cozy Task"
    static var description = IntentDescription(
        "Checks off one of today's tasks in Cozy."
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
            let today = DateHelpers.logicalToday()
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
                optionalBonusTasksEnabled: prefs.optionalBonusTasksEnabled,
                today: today
            )
            if prefs.streaksEnabled && snapshot.longestStreak > prefs.longestRecordedStreak {
                prefs.longestRecordedStreak = snapshot.longestStreak
                try? context.save()
            }

            await NotificationManager.shared.syncSummaryNotifications(
                preferences: prefs,
                occurrences: occurrences
            )
            if prefs.autoSyncCalendarChanges && prefs.hasAnyCalendarPushEnabled {
                _ = await GoogleCalendarService.shared.pushOccurrenceChangesWithoutRebalance(
                    context: context,
                    preferences: prefs,
                    referenceDate: today
                )
            }

            let remaining = occurrences.filter {
                $0.status == .pending && $0.bonusForDate == nil && DateHelpers.isSameDay($0.scheduledDate, today)
            }.count

            if prefs.addFriendlyMode {
                return remaining == 0
                    ? "Done: \(matched.displayTitle). All tasks complete."
                    : "Done: \(matched.displayTitle). \(remaining) left."
            }

            let tier = snapshot.tier(for: today)
            switch tier {
            case .gold:
                let rankNote = prefs.dayRanksEnabled ? " Today is highlighted in Gold." : " All tasks for today are complete!"
                let streakNote = prefs.streaksEnabled ? " Streak Days \(snapshot.currentStreak)!" : ""
                let lead = prefs.dayRanksEnabled ? "PERFECT! " : ""
                return "\(lead)Checked off \(matched.displayTitle).\(rankNote)\(streakNote)"
            case .silver:
                let rankNote = prefs.dayRanksEnabled ? " Today is highlighted in Silver." : ""
                let streakNote = prefs.streaksEnabled ? " Your \(snapshot.currentStreak)-day streak is preserved." : ""
                return "Checked off bonus task \(matched.displayTitle)!\(rankNote)\(streakNote)"
            case .base:
                if prefs.optionalBonusTasksEnabled {
                    let rankHint = prefs.dayRanksEnabled ? " if you want Silver or Gold" : ""
                    return "Checked off \(matched.displayTitle)! All of today's tasks are complete—two optional bonus tasks are ready\(rankHint)."
                }
                return "Checked off \(matched.displayTitle)! All of today's tasks are complete."
            case .none:
                return "Checked off \(matched.displayTitle)! \(remaining) task\(remaining == 1 ? "" : "s") left on today's checklist."
            }
        }()

        return .result(dialog: IntentDialog("\(spokenResponse)"))
    }
}

// MARK: - 4. Read Today's Checklist Intent

struct ReadTodaysChecklistIntent: AppIntent {
    static var title: LocalizedStringResource = "Read Today's Cozy Checklist"
    static var description = IntentDescription("Reads out your remaining tasks and minutes for today in Cozy.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let spokenResponse: String = await MainActor.run {
            let context = CozyModelContainer.shared.mainContext
            let prefs = CozyModelContainer.fetchOrCreatePreferences(in: context)
            let today = DateHelpers.logicalToday()
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
            let bonusToday = prefs.optionalBonusTasksEnabled
                ? occurrences
                    .filter { $0.status != .skipped && ($0.bonusForDate.map { DateHelpers.isSameDay($0, today) } ?? false) }
                    .sorted { $0.bonusSlot < $1.bonusSlot }
                : []
            let pendingBonus = bonusToday.filter { !$0.isCompleted }

            if baseToday.isEmpty {
                if prefs.addFriendlyMode {
                    return prefs.cupHours(for: today) == 0 ? "0 hours today. No tasks." : "No tasks today."
                }
                if prefs.cupHours(for: today) == 0 {
                    return "Your cup is set to 0 hours today, so your tasks moved back a day to give you space to rest."
                }
                return "Your checklist is wide open today—no tasks scheduled yet."
            }

            if pendingBase.isEmpty {
                if prefs.addFriendlyMode {
                    return "All \(baseToday.count) tasks complete."
                }
                if !prefs.optionalBonusTasksEnabled || pendingBonus.isEmpty {
                    return prefs.dayRanksEnabled
                        ? "You finished everything today—it's a Gold PERFECT day!"
                        : "You finished all \(baseToday.count) tasks on today's checklist!"
                }
                let bonusNames = pendingBonus.map(\.displayTitle).joined(separator: " and ")
                return "All \(baseToday.count) daily tasks are done! Optional bonus tasks available: \(bonusNames)."
            }

            let totalMinutes = pendingBase.reduce(0) { $0 + $1.displayDurationMinutes }
            let names = pendingBase.prefix(4).map(\.displayTitle).joined(separator: ", ")
            let durText = DateHelpers.formatDuration(minutes: totalMinutes)
            if prefs.addFriendlyMode {
                return "\(pendingBase.count) left (\(durText)): \(names)."
            }
            return "You have \(pendingBase.count) task\(pendingBase.count == 1 ? "" : "s") left today (\(durText)): \(names)."
        }

        return .result(dialog: IntentDialog("\(spokenResponse)"))
    }
}

// MARK: - 5. Check Cozy Streak Intent

struct CheckCozyStreakIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Cozy Streak"
    static var description = IntentDescription("Speaks your current streak and today's progress in Cozy.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let spokenResponse: String = await MainActor.run {
            let context = CozyModelContainer.shared.mainContext
            let prefs = CozyModelContainer.fetchOrCreatePreferences(in: context)
            let today = DateHelpers.logicalToday()
            let occurrences = (try? context.fetch(FetchDescriptor<TaskOccurrence>())) ?? []

            let snapshot = StreakAndBonusService.evaluate(
                occurrences: occurrences,
                persistedLongestStreak: prefs.longestRecordedStreak,
                optionalBonusTasksEnabled: prefs.optionalBonusTasksEnabled,
                today: today
            )
            if !prefs.streaksEnabled {
                let summary = snapshot.summary(for: today)
                return "Streaks are turned off in Settings. Today's progress: \(summary.baseCompletedCount) of \(summary.baseTotalCount) tasks complete."
            }
            if !prefs.dayRanksEnabled || prefs.addFriendlyMode {
                return "Streak: \(snapshot.currentStreak)d (Best: \(snapshot.longestStreak)d)."
            }
            let todayBadge = snapshot.tier(for: today).badgeTitle(baseStyle: prefs.baseHighlightStyle)
            return "Current streak: \(snapshot.currentStreak) day\(snapshot.currentStreak == 1 ? "" : "s"). Longest recorded streak: \(snapshot.longestStreak) day\(snapshot.longestStreak == 1 ? "" : "s"). Today's status: \(todayBadge)."
        }

        return .result(dialog: IntentDialog("\(spokenResponse)"))
    }
}

// MARK: - 6. Sync Google & Apple Calendars + Balance Schedule Intent

struct SyncAndRebalanceIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Calendars & Balance Tasks"
    static var description = IntentDescription(
        "Reads busy blocks from Google Calendar and Apple Calendar, rebalances flexible tasks onto freer days, and pushes tasks to Google and/or Apple Calendars."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let spokenResponse: String = await { @MainActor in
            let context = CozyModelContainer.shared.mainContext
            let prefs = CozyModelContainer.fetchOrCreatePreferences(in: context)
            let report = await GoogleCalendarService.shared.syncCalendarsAndRebalance(
                context: context,
                preferences: prefs,
                referenceDate: DateHelpers.logicalToday()
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
                "Add a \(.applicationName) task",
                "Add a \(\.$weight) \(.applicationName) task",
                "Create a \(.applicationName) task",
                "Add a task in \(.applicationName)",
                "Add a \(\.$weight) task in \(.applicationName)",
                "Schedule a \(\.$recurrence) \(.applicationName) task",
                "Schedule a \(\.$recurrence) task in \(.applicationName)"
            ],
            shortTitle: "Add Cozy Task",
            systemImageName: "plus.circle.fill"
        )
        AppShortcut(
            intent: SetDailyCupIntent(),
            phrases: [
                "Set my cup in \(.applicationName)",
                "Update my daily cup in \(.applicationName)"
            ],
            shortTitle: "Set Daily Cup",
            systemImageName: "cup.and.saucer.fill"
        )
        AppShortcut(
            intent: CompleteCozyTaskIntent(),
            phrases: [
                "Complete a \(.applicationName) task",
                "Complete a task in \(.applicationName)",
                "Check off a task in \(.applicationName)"
            ],
            shortTitle: "Complete Task",
            systemImageName: "checkmark.circle.fill"
        )
        AppShortcut(
            intent: ReadTodaysChecklistIntent(),
            phrases: [
                "What's on my \(.applicationName) today",
                "Read today's checklist in \(.applicationName)",
                "Show my \(.applicationName) tasks"
            ],
            shortTitle: "Today's Checklist",
            systemImageName: "checklist.checked"
        )
        AppShortcut(
            intent: CheckCozyStreakIntent(),
            phrases: [
                "Check my streak in \(.applicationName)",
                "What is my \(.applicationName) streak"
            ],
            shortTitle: "Check Streak",
            systemImageName: "flame.fill"
        )
        AppShortcut(
            intent: SyncAndRebalanceIntent(),
            phrases: [
                "Sync calendars in \(.applicationName)",
                "Sync Google Calendar in \(.applicationName)",
                "Balance my \(.applicationName) schedule"
            ],
            shortTitle: "Sync & Balance",
            systemImageName: "arrow.triangle.2.circlepath.circle.fill"
        )
    }
}
