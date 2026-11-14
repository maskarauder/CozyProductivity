import AppIntents
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
    @State private var testNotificationStatusMessage: String?
    @State private var googleAuthErrorMessage: String?
    private var googleService = GoogleCalendarService.shared

    private let orderedWeekdays = [2, 3, 4, 5, 6, 7, 1] // Monday -> Sunday

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cozy Preferences")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(CozyTheme.inkPrimary)
                        Text("Budgets, Google & Apple Calendar sync, Siri & summaries")
                            .font(.footnote)
                            .foregroundStyle(CozyTheme.inkSecondary)
                    }

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
                DayOverrideSheet(existingOverrides: overrides) {
                    onScheduleSettingsChanged()
                }
            }
        }
    }

    // MARK: - Weekday Free-Time Budgets

    private var weekdayBudgetsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Daily Free-Time Budgets", systemImage: "clock.badge.checkmark")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(CozyTheme.deepRose)

            Text("How much calm task time you generally have on each day of the week. Flexible tasks automatically gravitate toward days with more open time.")
                .font(.caption)
                .foregroundStyle(CozyTheme.inkSecondary)

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
            .filter { $0.date >= DateHelpers.startOfDay(for: Date()) }
            .sorted { $0.date < $1.date }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Single-Day Overrides", systemImage: "sparkles")
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
                Text("Going on a trip or having a cozy day off? Add a one-day free-time override anytime.")
                    .font(.caption)
                    .foregroundStyle(CozyTheme.inkSecondary)
            } else {
                ForEach(upcomingOverrides) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DateHelpers.fullHeaderDateString(for: item.date))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(CozyTheme.inkPrimary)
                            if !item.note.isEmpty {
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
        let phrases: [(String, String)] = [
            ("“Hey Siri, add a task in Cozy Tasks”", "Prompts for title, frequency (Once, Daily, Weekly, Monthly) & duration, then places it on a freer day."),
            ("“Hey Siri, complete a task in Cozy Tasks”", "Checks off any daily or bonus task and announces Silver / Gold PERFECT streak milestones."),
            ("“Hey Siri, what's on my Cozy Tasks today?”", "Reads out your remaining checklist items, bonus slots, and minutes."),
            ("“Hey Siri, check my streak in Cozy Tasks”", "Speaks your current Gold/Silver streak and longest recorded streak."),
            ("“Hey Siri, sync Google Calendar in Cozy Tasks”", "Merges Google Calendar events, rebalances tasks, and pushes scheduled blocks.")
        ]

        return VStack(alignment: .leading, spacing: 12) {
            Label("Siri & Shortcuts Voice Commands", systemImage: "waveform.and.mic")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(CozyTheme.deepRose)

            Text("Ready out-of-the-box with Apple App Intents—no external API keys required.")
                .font(.caption)
                .foregroundStyle(CozyTheme.inkSecondary)

            SiriTipView(intent: AddCozyTaskIntent())
                .siriTipViewStyle(.automatic)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(phrases, id: \.0) { phrase, detail in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phrase)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(CozyTheme.inkPrimary)
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(CozyTheme.inkSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
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
                Label("Google Calendar Two-Way Sync", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(CozyTheme.deepRose)
                Spacer()
                if googleService.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(CozyTheme.roseAccent)
                }
            }

            Text("Reads busy Google Calendar blocks to merge into free-time calculations, and pushes/updates scheduled Cozy Tasks back onto Google Calendar.")
                .font(.caption)
                .foregroundStyle(CozyTheme.inkSecondary)

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

            Text(preferences.googleSyncMode.subtitle)
                .font(.caption2)
                .foregroundStyle(CozyTheme.inkSecondary)

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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read & Merge Google Busy Events")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CozyTheme.inkPrimary)
                    Text("Unions overlapping Google + Apple Calendar events so busy days automatically get lighter task loads.")
                        .font(.caption)
                        .foregroundStyle(CozyTheme.inkSecondary)
                }
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Push & Merge Scheduled Tasks")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CozyTheme.inkPrimary)
                    Text("Creates and updates Cozy Tasks in open Google Calendar slots—moving them when rebalanced and marking ✅ when completed.")
                        .font(.caption)
                        .foregroundStyle(CozyTheme.inkSecondary)
                }
            }
            .tint(CozyTheme.roseAccent)

            if preferences.pushTasksToGoogleCalendar {
                Stepper(
                    "Preferred task push time: \(preferences.googleTaskPushStartHour):00",
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
                        referenceDate: Date()
                    )
                    onScheduleSettingsChanged()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(googleService.isSyncing ? "Syncing & Merging…" : "Sync & Merge Google Calendar Now")
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
                    Label("Grant Calendar Access for Google Bridge", systemImage: "lock.open.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CozyTheme.deepRose)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(CozyTheme.petalPill))
                }
                .buttonStyle(.plain)
            } else if detected.isEmpty {
                Text("Add your Gmail account in iPhone Settings → Calendar → Accounts to sync automatically without an OAuth Client ID.")
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

    // MARK: - Optional Apple Calendar Sync

    private var calendarSyncCard: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                VStack(alignment: .leading, spacing: 3) {
                    Label("Apple Calendar Busy-Time Sync", systemImage: "calendar")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(CozyTheme.deepRose)
                    Text("Deducts busy events on your iPhone calendar so packed days stay lighter.")
                        .font(.caption)
                        .foregroundStyle(CozyTheme.inkSecondary)
                }
            }
            .tint(CozyTheme.roseAccent)

            if preferences.useCalendarSync {
                Divider().overlay(CozyTheme.cardBorder)
                calendarDeductionControls
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

        Text(preferences.calendarDeductionMode.subtitle)
            .font(.caption2)
            .foregroundStyle(CozyTheme.inkSecondary)

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
            Label("Summary Notifications", systemImage: "bell.badge.fill")
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("End-of-Day Accomplishment Summary")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CozyTheme.inkPrimary)
                    Text("Evening recap of everything you checked off today.")
                        .font(.caption)
                        .foregroundStyle(CozyTheme.inkSecondary)
                }
            }
            .tint(CozyTheme.roseAccent)

            if preferences.dailySummaryEnabled {
                DatePicker(
                    "Evening Notification Time",
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weekly Reflection Notification")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CozyTheme.inkPrimary)
                    Text("Optional weekly wrap-up celebrating your completed tasks.")
                        .font(.caption)
                        .foregroundStyle(CozyTheme.inkSecondary)
                }
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Monthly Celebration Notification")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CozyTheme.inkPrimary)
                    Text("Optional monthly milestone summary of your cozy progress.")
                        .font(.caption)
                        .foregroundStyle(CozyTheme.inkSecondary)
                }
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
                        ? "Test summary scheduled! Watch for the banner in ~3 seconds 🌸"
                        : "Please enable notifications for CozyProductivity in iPhone Settings."
                }
            } label: {
                HStack {
                    Image(systemName: "paperplane.fill")
                    Text("Send Test Today Summary (3s)")
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
