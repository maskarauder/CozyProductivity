import AppIntents
import EventKit
import SwiftData
import SwiftUI

struct CozySettingsView: View {
    @Environment(\.modelContext) private var modelContext

    let preferences: CozyPreferences
    let overrides: [DayCapacityOverride]
    let occurrences: [TaskOccurrence]
    var onScheduleSettingsChanged: () -> Void
    var onNotificationSettingsChanged: () -> Void

    @State private var showingOverrideSheet = false
    @State private var showingCupPromptSheet = false
    @State private var testNotificationStatusMessage: String?
    @State private var googleAuthErrorMessage: String?
    private var googleService = GoogleCalendarService.shared

    private let orderedWeekdays = [2, 3, 4, 5, 6, 7, 1] // Monday -> Sunday

    private var isAddFriendly: Bool {
        preferences.addFriendlyMode
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: isAddFriendly ? 14 : 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isAddFriendly ? "Settings" : "Cozy Settings")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(CozyTheme.inkPrimary)
                        if !isAddFriendly {
                            Text("Focus mode, optional gamification, daily cup, Siri & calendar sync")
                                .font(.footnote)
                                .foregroundStyle(CozyTheme.inkSecondary)
                        }
                    }

                    focusAndGamificationCard

                    dailyCupAndWeightsCard

                    calendarAutoSyncCard

                    siriVoiceCommandsCard

                    googleCalendarSyncCard

                    calendarSyncCard

                    weekdayBudgetsCard

                    singleDayOverridesCard

                    notificationsCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 36)
            }
            .cozyScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingOverrideSheet) {
                DayOverrideSheet(
                    existingOverrides: overrides,
                    addFriendlyMode: isAddFriendly
                ) {
                    onScheduleSettingsChanged()
                }
            }
            .sheet(isPresented: $showingCupPromptSheet) {
                DailyCupPromptSheet(preferences: preferences) {
                    onScheduleSettingsChanged()
                }
            }
        }
    }

    @ViewBuilder
    private func settingToggleLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CozyTheme.inkPrimary)
            if !isAddFriendly && !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(CozyTheme.inkSecondary)
            }
        }
    }

    // MARK: - ADD Friendly Mode & Optional Gamification

    private var focusAndGamificationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                isAddFriendly ? "Focus & Gamification" : "ADD Friendly Mode & Gamification",
                systemImage: "sparkles.rectangle.stack.fill"
            )
            .font(.system(.subheadline, design: .rounded, weight: .bold))
            .foregroundStyle(CozyTheme.deepRose)

            Toggle(isOn: Binding(
                get: { preferences.addFriendlyMode },
                set: { enabled in
                    preferences.addFriendlyMode = enabled
                    try? modelContext.save()
                }
            )) {
                settingToggleLabel(
                    "ADD Friendly Mode",
                    detail: "Reduces text across the entire app, trims cozy details, and lists only hours in the “How full is your cup?” dialogue."
                )
            }
            .tint(CozyTheme.roseAccent)

            Divider().overlay(CozyTheme.cardBorder)

            Toggle(isOn: Binding(
                get: { preferences.streaksEnabled },
                set: { enabled in
                    preferences.streaksEnabled = enabled
                    try? modelContext.save()
                }
            )) {
                settingToggleLabel(
                    "Streaks",
                    detail: "Show current and longest recorded day streaks."
                )
            }
            .tint(CozyTheme.roseAccent)

            Toggle(isOn: Binding(
                get: { preferences.optionalBonusTasksEnabled },
                set: { enabled in
                    preferences.optionalBonusTasksEnabled = enabled
                    try? modelContext.save()
                    StreakAndBonusService.syncBonusSlots(
                        context: modelContext,
                        occurrences: occurrences,
                        preferences: preferences
                    )
                    onScheduleSettingsChanged()
                }
            )) {
                settingToggleLabel(
                    "Optional Bonus Tasks",
                    detail: "Show 2 optional tasks from the next 7 days. When off, completing your daily tasks defaults to a Gold day."
                )
            }
            .tint(CozyTheme.roseAccent)

            Toggle(isOn: Binding(
                get: { preferences.dayRanksEnabled },
                set: { enabled in
                    preferences.dayRanksEnabled = enabled
                    try? modelContext.save()
                }
            )) {
                settingToggleLabel(
                    "Day Ranks (Bronze, Silver, Gold)",
                    detail: "Highlight completed days with Bronze, Silver, and Gold ranks and PERFECT banners."
                )
            }
            .tint(CozyTheme.roseAccent)

            Toggle(isOn: Binding(
                get: { preferences.confettiEnabled },
                set: { enabled in
                    preferences.confettiEnabled = enabled
                    try? modelContext.save()
                }
            )) {
                settingToggleLabel(
                    "Confetti",
                    detail: "Shoot celebratory confetti when tasks and days are completed."
                )
            }
            .tint(CozyTheme.roseAccent)
        }
        .padding(18)
        .cozyCard()
    }

    // MARK: - Daily Cup (0–5h, 4:00 AM Reset) & Task Weights

    private var dailyCupAndWeightsCard: some View {
        let logicalToday = DateHelpers.logicalToday()
        let activeCup = preferences.cupHours(for: logicalToday)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(isAddFriendly ? "Daily Cup" : "Daily Cup & Task Weights", systemImage: "cup.and.saucer.fill")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(CozyTheme.deepRose)
                Spacer()
                Button {
                    showingCupPromptSheet = true
                } label: {
                    Text(isAddFriendly ? "Open" : (preferences.dailyCupPromptEnabled ? "Open Prompt" : "Set Today Once"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(CozyTheme.deepRose)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(CozyTheme.petalPill))
                }
                .buttonStyle(.plain)
            }

            Toggle(isOn: Binding(
                get: { preferences.dailyCupPromptEnabled },
                set: { enabled in
                    preferences.setDailyCupPromptEnabled(enabled)
                    try? modelContext.save()
                    onScheduleSettingsChanged()
                }
            )) {
                settingToggleLabel(
                    isAddFriendly ? "Daily Cup Prompt" : "“How full is your cup?” Morning Dialogue",
                    detail: "Prompts at the start of each day (resetting at 4:00 AM) for 0–5 hours. Turn off to use your weekday free-time budgets automatically."
                )
            }
            .tint(CozyTheme.roseAccent)

            if preferences.dailyCupPromptEnabled || activeCup != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        isAddFriendly
                            ? (activeCup.map { "Today: \($0) \($0 == 1 ? "hour" : "hours")" } ?? "Today:")
                            : (activeCup.map { "Today's cup: \($0) \($0 == 1 ? "hour" : "hours") (resets at 4:00 AM)" }
                                ?? "Today's cup not set yet — tap a number:")
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CozyTheme.inkPrimary)

                    HStack(spacing: 6) {
                        ForEach(0...5, id: \.self) { level in
                            let isSelected = activeCup == level
                            Button {
                                preferences.recordCupCheckIn(hours: level, for: logicalToday)
                                try? modelContext.save()
                                onScheduleSettingsChanged()
                            } label: {
                                Text("\(level)h")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(isSelected ? .white : CozyTheme.inkPrimary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .fill(
                                                isSelected
                                                    ? AnyShapeStyle(CozyTheme.primaryButtonGradient)
                                                    : AnyShapeStyle(CozyTheme.softBlushFill)
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if !isAddFriendly {
                Text("New tasks default to Light (30 min, Once) and can be edited anytime to adjust duration, Light (+0m), Normal (+30m), or Heavy (+1h) weight, and Hard Deadlines.")
                    .font(.caption2)
                    .foregroundStyle(CozyTheme.inkSecondary)
            }
        }
        .padding(18)
        .cozyCard()
    }

    // MARK: - Unified Auto-Sync All Changes (Google & Apple Calendars)

    private var calendarAutoSyncCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(isAddFriendly ? "Calendar Auto-Sync" : "Auto-Sync Calendar Changes", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(CozyTheme.deepRose)
                Spacer()
                if googleService.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(CozyTheme.roseAccent)
                }
            }

            Toggle(isOn: Binding(
                get: { preferences.autoSyncCalendarChanges },
                set: { enabled in
                    preferences.autoSyncCalendarChanges = enabled
                    try? modelContext.save()
                    if enabled {
                        onScheduleSettingsChanged()
                    }
                }
            )) {
                settingToggleLabel(
                    isAddFriendly ? "Auto-Sync Changes" : "Auto-Sync All Task & Schedule Changes",
                    detail: "Automatically syncs new tasks, edits, check-offs (✅), moves, deletions, and rebalances to Google and/or Apple Calendars."
                )
            }
            .tint(CozyTheme.roseAccent)

            Divider().overlay(CozyTheme.cardBorder)

            Toggle(isOn: Binding(
                get: { preferences.pushTasksToAppleCalendar },
                set: { enabled in
                    Task { @MainActor in
                        if enabled {
                            let granted = await CalendarFreeTimeService.shared.requestAccess()
                            preferences.pushTasksToAppleCalendar = granted
                        } else {
                            preferences.pushTasksToAppleCalendar = false
                        }
                        try? modelContext.save()
                        onScheduleSettingsChanged()
                    }
                }
            )) {
                settingToggleLabel(
                    "Sync Tasks to Apple Calendar",
                    detail: "Pushes and updates scheduled Cozy tasks directly on your iPhone / iCloud Calendar."
                )
            }
            .tint(CozyTheme.roseAccent)

            Toggle(isOn: Binding(
                get: { preferences.pushTasksToGoogleCalendar },
                set: { enabled in
                    Task { @MainActor in
                        if enabled && preferences.googleSyncMode == .iosGoogleAccount {
                            _ = await CalendarFreeTimeService.shared.requestAccess()
                        }
                        preferences.pushTasksToGoogleCalendar = enabled
                        try? modelContext.save()
                        onScheduleSettingsChanged()
                    }
                }
            )) {
                settingToggleLabel(
                    "Sync Tasks to Google Calendar",
                    detail: "Pushes and updates scheduled Cozy tasks on Google Calendar (via OAuth 2.0 or iPhone Account Bridge)."
                )
            }
            .tint(CozyTheme.roseAccent)

            if preferences.hasAnyCalendarPushEnabled {
                Stepper(
                    isAddFriendly
                        ? "Start hour: \(preferences.googleTaskPushStartHour):00"
                        : "Preferred task time slot: \(preferences.googleTaskPushStartHour):00",
                    value: Binding(
                        get: { preferences.googleTaskPushStartHour },
                        set: { val in
                            preferences.googleTaskPushStartHour = max(6, min(22, val))
                            try? modelContext.save()
                            onScheduleSettingsChanged()
                        }
                    ),
                    in: 6...22
                )
                .font(.caption.weight(.medium))
            }

            if preferences.hasAnyCalendarIntegrationEnabled {
                Button {
                    Task { @MainActor in
                        _ = await googleService.syncCalendarsAndRebalance(
                            context: modelContext,
                            preferences: preferences,
                            referenceDate: DateHelpers.logicalToday()
                        )
                        onScheduleSettingsChanged()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(googleService.isSyncing ? "Syncing…" : (isAddFriendly ? "Sync Now" : "Sync Enabled Calendars Now"))
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(CozyTheme.primaryButtonGradient)
                    )
                }
                .buttonStyle(.plain)
                .disabled(googleService.isSyncing)
            }
        }
        .padding(18)
        .cozyCard()
    }

    // MARK: - Weekday Free-Time Budgets

    private var weekdayBudgetsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(isAddFriendly ? "Weekday Hours" : "Predicted Upcoming Free-Time Budgets", systemImage: "clock.badge.checkmark")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(CozyTheme.deepRose)

            if !isAddFriendly {
                Text("Used to predict upcoming tasks on future calendar days before each morning's 0–5h Cup check-in.")
                    .font(.caption)
                    .foregroundStyle(CozyTheme.inkSecondary)
            }

            ForEach(orderedWeekdays, id: \.self) { weekday in
                let minutes = preferences.baseBudgetMinutes(forWeekday: weekday)
                HStack(spacing: 10) {
                    Text(DateHelpers.weekdayName(for: weekday))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(CozyTheme.inkPrimary)
                        .frame(width: 96, alignment: .leading)

                    Slider(
                        value: Binding(
                            get: { Double(minutes) },
                            set: { newVal in
                                let stepped = Int((newVal / 15.0).rounded()) * 15
                                preferences.setBaseBudgetMinutes(stepped, forWeekday: weekday)
                                try? modelContext.save()
                                onScheduleSettingsChanged()
                            }
                        ),
                        in: 0...360,
                        step: 15
                    )
                    .tint(CozyTheme.roseAccent)

                    Text(DateHelpers.formatDuration(minutes: minutes))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(CozyTheme.deepRose)
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
        .padding(18)
        .cozyCard()
    }

    // MARK: - Single-Day Overrides

    private var singleDayOverridesCard: some View {
        let upcomingOverrides = overrides
            .filter { $0.date >= DateHelpers.logicalToday() }
            .sorted { $0.date < $1.date }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(isAddFriendly ? "Day Overrides" : "Single-Day Overrides", systemImage: "sparkles")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(CozyTheme.deepRose)
                Spacer()
                Button {
                    showingOverrideSheet = true
                } label: {
                    Label("Add Day", systemImage: "plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(CozyTheme.deepRose)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(CozyTheme.petalPill))
                }
                .buttonStyle(.plain)
            }

            if upcomingOverrides.isEmpty {
                if !isAddFriendly {
                    Text("Going on a trip or having a day off? Add a one-day free-time override anytime.")
                        .font(.caption)
                        .foregroundStyle(CozyTheme.inkSecondary)
                }
            } else {
                ForEach(upcomingOverrides) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DateHelpers.fullHeaderDateString(for: item.date))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(CozyTheme.inkPrimary)
                            if !isAddFriendly && !item.note.isEmpty {
                                Text(item.note)
                                    .font(.caption)
                                    .foregroundStyle(CozyTheme.inkSecondary)
                            }
                        }
                        Spacer()
                        Text(DateHelpers.formatDuration(minutes: item.availableMinutes))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(CozyTheme.deepRose)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(CozyTheme.softBlushFill))

                        Button(role: .destructive) {
                            modelContext.delete(item)
                            try? modelContext.save()
                            onScheduleSettingsChanged()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(CozyTheme.inkMuted)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(CozyTheme.canvasMiddle)
                    )
                }
            }
        }
        .padding(18)
        .cozyCard()
    }

    // MARK: - Native Siri & Apple Shortcuts Voice Commands

    private var siriVoiceCommandsCard: some View {
        var phrases: [(String, String)] = [
            ("“Hey Siri, add a Cozy task to take out the trash”", "Adds a Light 30-minute Once task and places it on a freer day."),
            ("“Hey Siri, add a heavy 1-hour Cozy task to take out the trash”", "Automatically parses weight (Light/Normal/Heavy), duration, and frequency."),
            ("“Hey Siri, set my cup in Cozy”", "Sets how full your cup is today (0 to 5 hours) and rebalances tasks."),
            ("“Hey Siri, complete a task in Cozy”", "Checks off any task on your list."),
            ("“Hey Siri, what's on my Cozy today?”", "Reads out your remaining checklist items and time."),
            ("“Hey Siri, sync calendars in Cozy”", "Syncs Google and Apple Calendars and rebalances.")
        ]
        if preferences.streaksEnabled {
            phrases.append(("“Hey Siri, check my streak in Cozy”", "Speaks your current and longest recorded streak."))
        }

        return VStack(alignment: .leading, spacing: 12) {
            Label(isAddFriendly ? "Siri Commands" : "Siri & Shortcuts Voice Commands", systemImage: "waveform.and.mic")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(CozyTheme.deepRose)

            if !isAddFriendly {
                Text("Say “Cozy” with Siri—new tasks default to Light (30m) or parse weight & duration directly from your phrase.")
                    .font(.caption)
                    .foregroundStyle(CozyTheme.inkSecondary)

                SiriTipView(intent: AddCozyTaskIntent())
                    .siriTipViewStyle(.automatic)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(phrases, id: \.0) { phrase, detail in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phrase)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(CozyTheme.inkPrimary)
                        if !isAddFriendly {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(CozyTheme.inkSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(isAddFriendly ? 8 : 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(CozyTheme.canvasMiddle)
                    )
                }
            }
        }
        .padding(18)
        .cozyCard()
    }

    // MARK: - Two-Way Google Calendar Sync (Read Busy + Push/Merge Tasks)

    private var googleCalendarSyncCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(isAddFriendly ? "Google Calendar" : "Google Calendar Two-Way Sync", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(CozyTheme.deepRose)
                Spacer()
                if googleService.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(CozyTheme.roseAccent)
                }
            }

            if !isAddFriendly {
                Text("Reads busy Google Calendar blocks to merge into free-time calculations, and pushes/updates scheduled Cozy tasks back onto Google Calendar.")
                    .font(.caption)
                    .foregroundStyle(CozyTheme.inkSecondary)
            }

            Picker("Connection Mode", selection: Binding(
                get: { preferences.googleSyncMode },
                set: { mode in
                    preferences.googleSyncMode = mode
                    try? modelContext.save()
                    onScheduleSettingsChanged()
                }
            )) {
                ForEach(GoogleCalendarSyncMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if !isAddFriendly {
                Text(preferences.googleSyncMode.subtitle)
                    .font(.caption2)
                    .foregroundStyle(CozyTheme.inkSecondary)
            }

            if preferences.googleSyncMode == .oauthREST {
                googleOAuthConfigSection
            } else {
                googleIOSBridgeSection
            }

            Divider().overlay(CozyTheme.cardBorder)

            // Toggle 1: Read & Merge Busy Blocks
            Toggle(isOn: Binding(
                get: { preferences.useGoogleCalendarSync },
                set: { enabled in
                    Task { @MainActor in
                        if enabled && preferences.googleSyncMode == .iosGoogleAccount {
                            _ = await CalendarFreeTimeService.shared.requestAccess()
                        }
                        preferences.useGoogleCalendarSync = enabled
                        try? modelContext.save()
                        onScheduleSettingsChanged()
                    }
                }
            )) {
                settingToggleLabel(
                    "Read & Merge Google Busy Events",
                    detail: "Unions overlapping Google + Apple Calendar events so busy days automatically get lighter task loads."
                )
            }
            .tint(CozyTheme.roseAccent)

            // Toggle 2: Push & Merge Cozy Tasks to Google Calendar
            Toggle(isOn: Binding(
                get: { preferences.pushTasksToGoogleCalendar },
                set: { enabled in
                    Task { @MainActor in
                        if enabled && preferences.googleSyncMode == .iosGoogleAccount {
                            _ = await CalendarFreeTimeService.shared.requestAccess()
                        }
                        preferences.pushTasksToGoogleCalendar = enabled
                        try? modelContext.save()
                        onScheduleSettingsChanged()
                    }
                }
            )) {
                settingToggleLabel(
                    "Push & Merge Scheduled Tasks",
                    detail: "Creates and updates Cozy tasks in open Google Calendar slots—moving them when rebalanced and marking ✅ when completed."
                )
            }
            .tint(CozyTheme.roseAccent)

            if preferences.pushTasksToGoogleCalendar {
                Stepper(
                    isAddFriendly
                        ? "Start hour: \(preferences.googleTaskPushStartHour):00"
                        : "Preferred task push time: \(preferences.googleTaskPushStartHour):00",
                    value: Binding(
                        get: { preferences.googleTaskPushStartHour },
                        set: { val in
                            preferences.googleTaskPushStartHour = max(6, min(22, val))
                            try? modelContext.save()
                            onScheduleSettingsChanged()
                        }
                    ),
                    in: 6...22
                )
                .font(.caption.weight(.medium))
            }

            if preferences.useGoogleCalendarSync && !preferences.useCalendarSync {
                Divider().overlay(CozyTheme.cardBorder)
                calendarDeductionControls
            }

            Button {
                googleAuthErrorMessage = nil
                Task { @MainActor in
                    _ = await googleService.syncCalendarsAndRebalance(
                        context: modelContext,
                        preferences: preferences,
                        referenceDate: DateHelpers.logicalToday()
                    )
                    onScheduleSettingsChanged()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(googleService.isSyncing ? "Syncing…" : (isAddFriendly ? "Sync Google Calendar" : "Sync & Merge Google Calendar Now"))
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(CozyTheme.primaryButtonGradient)
                )
            }
            .buttonStyle(.plain)
            .disabled(googleService.isSyncing)

            if let err = googleAuthErrorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(CozyTheme.deepRose)
            } else if let status = googleService.lastSyncStatusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(CozyTheme.deepRose)
            }
        }
        .padding(18)
        .cozyCard()
    }

    @ViewBuilder
    private var googleOAuthConfigSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Google iOS OAuth Client ID")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CozyTheme.inkPrimary)
                TextField(
                    "123456-abc.apps.googleusercontent.com",
                    text: Binding(
                        get: { preferences.googleClientID },
                        set: { val in
                            preferences.googleClientID = val
                            try? modelContext.save()
                        }
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.caption)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(CozyTheme.canvasMiddle)
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Target Google Calendar ID")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CozyTheme.inkPrimary)
                TextField(
                    "primary",
                    text: Binding(
                        get: { preferences.googleCalendarID },
                        set: { val in
                            preferences.googleCalendarID = val
                            try? modelContext.save()
                        }
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.caption)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(CozyTheme.canvasMiddle)
                )
            }

            if googleService.isSignedInWithOAuth {
                HStack {
                    Label(googleService.connectedAccountLabel, systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CozyTheme.deepRose)
                    Spacer()
                    Button("Disconnect") {
                        googleService.signOut()
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(CozyTheme.inkSecondary)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(CozyTheme.softBlushFill)
                )
            } else {
                Button {
                    googleAuthErrorMessage = nil
                    Task { @MainActor in
                        do {
                            try await googleService.signInWithGoogle(clientID: preferences.googleClientID)
                            onScheduleSettingsChanged()
                        } catch {
                            googleAuthErrorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                        Text("Sign in with Google (OAuth PKCE)")
                            .fontWeight(.semibold)
                    }
                    .font(.caption)
                    .foregroundStyle(CozyTheme.deepRose)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(CozyTheme.petalPill)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var googleIOSBridgeSection: some View {
        let detected = CalendarFreeTimeService.shared.googleAccountCalendars()
        VStack(alignment: .leading, spacing: 8) {
            if !CalendarFreeTimeService.shared.hasReadAccess {
                Button {
                    Task { @MainActor in
                        _ = await CalendarFreeTimeService.shared.requestAccess()
                        onScheduleSettingsChanged()
                    }
                } label: {
                    Label(isAddFriendly ? "Grant Calendar Access" : "Grant Calendar Access for Google Bridge", systemImage: "lock.open.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CozyTheme.deepRose)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(CozyTheme.petalPill))
                }
                .buttonStyle(.plain)
            } else if detected.isEmpty {
                Text(
                    isAddFriendly
                        ? "Add Gmail in iPhone Settings → Calendar → Accounts."
                        : "Add your Gmail account in iPhone Settings → Calendar → Accounts to sync automatically without an OAuth Client ID."
                )
                .font(.caption2)
                .foregroundStyle(CozyTheme.inkSecondary)
            } else {
                Label(
                    "Detected \(detected.count) Google calendar\(detected.count == 1 ? "" : "s"): \(detected.map(\.title).joined(separator: ", "))",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(CozyTheme.deepRose)
            }
        }
    }

    // MARK: - Apple Calendar Two-Way Sync

    private var calendarSyncCard: some View {
        let appleCalendars = CalendarFreeTimeService.shared.writableAppleCalendars()

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(isAddFriendly ? "Apple Calendar" : "Apple Calendar Two-Way Sync", systemImage: "calendar")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(CozyTheme.deepRose)
                Spacer()
                Text(CalendarFreeTimeService.shared.hasReadAccess ? "Authorized" : "iPhone / iCloud")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(CozyTheme.deepRose)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(CozyTheme.softBlushFill))
            }

            Toggle(isOn: Binding(
                get: { preferences.useCalendarSync },
                set: { enabled in
                    Task { @MainActor in
                        if enabled {
                            let granted = await CalendarFreeTimeService.shared.requestAccess()
                            preferences.useCalendarSync = granted
                        } else {
                            preferences.useCalendarSync = false
                        }
                        try? modelContext.save()
                        onScheduleSettingsChanged()
                    }
                }
            )) {
                settingToggleLabel(
                    "Read & Deduct Apple Busy Events",
                    detail: "Deducts busy events on your iPhone / iCloud calendar so packed days stay lighter."
                )
            }
            .tint(CozyTheme.roseAccent)

            Toggle(isOn: Binding(
                get: { preferences.pushTasksToAppleCalendar },
                set: { enabled in
                    Task { @MainActor in
                        if enabled {
                            let granted = await CalendarFreeTimeService.shared.requestAccess()
                            preferences.pushTasksToAppleCalendar = granted
                        } else {
                            preferences.pushTasksToAppleCalendar = false
                        }
                        try? modelContext.save()
                        onScheduleSettingsChanged()
                    }
                }
            )) {
                settingToggleLabel(
                    isAddFriendly ? "Push Tasks to Apple Calendar" : "Push & Sync Scheduled Tasks to Apple Calendar",
                    detail: "Creates, updates, and cleans up Cozy tasks on your iPhone Calendar—moving them when rebalanced and marking ✅ when completed."
                )
            }
            .tint(CozyTheme.roseAccent)

            if preferences.pushTasksToAppleCalendar && CalendarFreeTimeService.shared.hasReadAccess && !appleCalendars.isEmpty {
                Picker("Target Apple Calendar", selection: Binding(
                    get: { preferences.appleTargetCalendarIdentifier },
                    set: { id in
                        preferences.appleTargetCalendarIdentifier = id
                        try? modelContext.save()
                        onScheduleSettingsChanged()
                    }
                )) {
                    Text("Default iPhone Calendar").tag("")
                    ForEach(appleCalendars, id: \.calendarIdentifier) { cal in
                        Text(cal.title).tag(cal.calendarIdentifier)
                    }
                }
                .pickerStyle(.menu)
                .tint(CozyTheme.deepRose)
                .font(.subheadline)
            }

            if preferences.useCalendarSync {
                Divider().overlay(CozyTheme.cardBorder)
                calendarDeductionControls
            }

            if preferences.useCalendarSync || preferences.pushTasksToAppleCalendar {
                Button {
                    Task { @MainActor in
                        _ = await googleService.syncCalendarsAndRebalance(
                            context: modelContext,
                            preferences: preferences,
                            referenceDate: DateHelpers.logicalToday()
                        )
                        onScheduleSettingsChanged()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(googleService.isSyncing ? "Syncing…" : (isAddFriendly ? "Sync Apple Calendar" : "Sync Apple Calendar Now"))
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(CozyTheme.primaryButtonGradient)
                    )
                }
                .buttonStyle(.plain)
                .disabled(googleService.isSyncing)
            }
        }
        .padding(18)
        .cozyCard()
    }

    @ViewBuilder
    private var calendarDeductionControls: some View {
        Picker("Deduction Style", selection: Binding(
            get: { preferences.calendarDeductionMode },
            set: { mode in
                preferences.calendarDeductionMode = mode
                try? modelContext.save()
                onScheduleSettingsChanged()
            }
        )) {
            ForEach(CalendarDeductionMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .tint(CozyTheme.deepRose)
        .font(.subheadline)

        if !isAddFriendly {
            Text(preferences.calendarDeductionMode.subtitle)
                .font(.caption2)
                .foregroundStyle(CozyTheme.inkSecondary)
        }

        HStack {
            Stepper(
                "Day starts: \(preferences.wakingStartHour):00",
                value: Binding(
                    get: { preferences.wakingStartHour },
                    set: { val in
                        preferences.wakingStartHour = min(val, preferences.wakingEndHour - 2)
                        try? modelContext.save()
                        onScheduleSettingsChanged()
                    }
                ),
                in: 5...14
            )
            .font(.caption.weight(.medium))
        }

        HStack {
            Stepper(
                "Day ends: \(preferences.wakingEndHour):00",
                value: Binding(
                    get: { preferences.wakingEndHour },
                    set: { val in
                        preferences.wakingEndHour = max(val, preferences.wakingStartHour + 2)
                        try? modelContext.save()
                        onScheduleSettingsChanged()
                    }
                ),
                in: 16...24
            )
            .font(.caption.weight(.medium))
        }
    }

    // MARK: - Daily, Weekly & Monthly Summary Notifications

    private var notificationsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(isAddFriendly ? "Notifications" : "Summary Notifications", systemImage: "bell.badge.fill")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(CozyTheme.deepRose)

            // 1. End-of-Day Summary
            Toggle(isOn: Binding(
                get: { preferences.dailySummaryEnabled },
                set: { val in
                    preferences.dailySummaryEnabled = val
                    try? modelContext.save()
                    onNotificationSettingsChanged()
                }
            )) {
                settingToggleLabel(
                    isAddFriendly ? "Daily Summary" : "End-of-Day Accomplishment Summary",
                    detail: "Evening recap of everything you checked off today."
                )
            }
            .tint(CozyTheme.roseAccent)

            if preferences.dailySummaryEnabled {
                DatePicker(
                    isAddFriendly ? "Time" : "Evening Notification Time",
                    selection: timeBinding(
                        hour: Binding(
                            get: { preferences.dailySummaryHour },
                            set: { preferences.dailySummaryHour = $0 }
                        ),
                        minute: Binding(
                            get: { preferences.dailySummaryMinute },
                            set: { preferences.dailySummaryMinute = $0 }
                        )
                    ),
                    displayedComponents: .hourAndMinute
                )
                .font(.subheadline)
                .tint(CozyTheme.roseAccent)
            }

            Divider().overlay(CozyTheme.cardBorder)

            // 2. Optional Weekly Summary
            Toggle(isOn: Binding(
                get: { preferences.weeklySummaryEnabled },
                set: { val in
                    preferences.weeklySummaryEnabled = val
                    try? modelContext.save()
                    onNotificationSettingsChanged()
                }
            )) {
                settingToggleLabel(
                    isAddFriendly ? "Weekly Summary" : "Weekly Reflection Notification",
                    detail: "Optional weekly wrap-up celebrating your completed tasks."
                )
            }
            .tint(CozyTheme.roseAccent)

            if preferences.weeklySummaryEnabled {
                HStack {
                    Text("Send on")
                        .font(.subheadline)
                    Spacer()
                    Picker("Weekday", selection: Binding(
                        get: { preferences.weeklySummaryWeekday },
                        set: { val in
                            preferences.weeklySummaryWeekday = val
                            try? modelContext.save()
                            onNotificationSettingsChanged()
                        }
                    )) {
                        ForEach(1...7, id: \.self) { wd in
                            Text(DateHelpers.weekdayName(for: wd)).tag(wd)
                        }
                    }
                    .tint(CozyTheme.deepRose)
                }

                DatePicker(
                    "Weekly Time",
                    selection: timeBinding(
                        hour: Binding(
                            get: { preferences.weeklySummaryHour },
                            set: { preferences.weeklySummaryHour = $0 }
                        ),
                        minute: Binding(
                            get: { preferences.weeklySummaryMinute },
                            set: { preferences.weeklySummaryMinute = $0 }
                        )
                    ),
                    displayedComponents: .hourAndMinute
                )
                .font(.subheadline)
                .tint(CozyTheme.roseAccent)
            }

            Divider().overlay(CozyTheme.cardBorder)

            // 3. Optional Monthly Summary
            Toggle(isOn: Binding(
                get: { preferences.monthlySummaryEnabled },
                set: { val in
                    preferences.monthlySummaryEnabled = val
                    try? modelContext.save()
                    onNotificationSettingsChanged()
                }
            )) {
                settingToggleLabel(
                    isAddFriendly ? "Monthly Summary" : "Monthly Celebration Notification",
                    detail: "Optional monthly milestone summary of your progress."
                )
            }
            .tint(CozyTheme.roseAccent)

            if preferences.monthlySummaryEnabled {
                Stepper(
                    "Day of month: \(preferences.monthlySummaryDayOfMonth)",
                    value: Binding(
                        get: { preferences.monthlySummaryDayOfMonth },
                        set: { val in
                            preferences.monthlySummaryDayOfMonth = val
                            try? modelContext.save()
                            onNotificationSettingsChanged()
                        }
                    ),
                    in: 1...28
                )
                .font(.subheadline)

                DatePicker(
                    "Monthly Time",
                    selection: timeBinding(
                        hour: Binding(
                            get: { preferences.monthlySummaryHour },
                            set: { preferences.monthlySummaryHour = $0 }
                        ),
                        minute: Binding(
                            get: { preferences.monthlySummaryMinute },
                            set: { preferences.monthlySummaryMinute = $0 }
                        )
                    ),
                    displayedComponents: .hourAndMinute
                )
                .font(.subheadline)
                .tint(CozyTheme.roseAccent)
            }

            Divider().overlay(CozyTheme.cardBorder)

            // Test Notification Button
            Button {
                Task { @MainActor in
                    let ok = await NotificationManager.shared.sendTestSummaryNotification(occurrences: occurrences)
                    testNotificationStatusMessage = ok
                        ? (isAddFriendly ? "Test summary scheduled (3s)." : "Test summary scheduled! Watch for the banner in ~3 seconds 🌸")
                        : "Please enable notifications for Cozy in iPhone Settings."
                }
            } label: {
                HStack {
                    Image(systemName: "paperplane.fill")
                    Text(isAddFriendly ? "Test Summary (3s)" : "Send Test Today Summary (3s)")
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(CozyTheme.primaryButtonGradient)
                )
            }
            .buttonStyle(.plain)

            if let msg = testNotificationStatusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(CozyTheme.deepRose)
            }
        }
        .padding(18)
        .cozyCard()
    }

    private func timeBinding(hour: Binding<Int>, minute: Binding<Int>) -> Binding<Date> {
        Binding<Date>(
            get: {
                var comps = DateHelpers.calendar.dateComponents([.year, .month, .day], from: Date())
                comps.hour = hour.wrappedValue
                comps.minute = minute.wrappedValue
                return DateHelpers.calendar.date(from: comps) ?? Date()
            },
            set: { newDate in
                let comps = DateHelpers.calendar.dateComponents([.hour, .minute], from: newDate)
                hour.wrappedValue = comps.hour ?? 20
                minute.wrappedValue = comps.minute ?? 0
                try? modelContext.save()
                onNotificationSettingsChanged()
            }
        )
    }
}
