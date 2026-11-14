import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \TaskTemplate.createdAt, order: .forward)
    private var templates: [TaskTemplate]

    @Query
    private var occurrences: [TaskOccurrence]

    @Query
    private var preferencesList: [CozyPreferences]

    @Query(sort: \DayCapacityOverride.date, order: .forward)
    private var overrides: [DayCapacityOverride]

    @State private var celebration = CelebrationController()
    @State private var calendarBusyByDay: [Date: Int] = [:]
    @State private var fallbackPreferences = CozyPreferences()
    @State private var hasBootstrapped = false
    @State private var showingDailyCupPrompt = false
    @State private var currentLogicalDay: Date = DateHelpers.logicalToday()

    private let cupResetTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init() {
        let cutoff = DateHelpers.addDays(
            -SmartScheduler.operationalHistoryBufferDays,
            to: DateHelpers.logicalToday()
        )
        let pendingRaw = OccurrenceStatus.pending.rawValue
        _occurrences = Query(
            filter: #Predicate<TaskOccurrence> { occ in
                occ.statusRaw == pendingRaw || occ.scheduledDate >= cutoff
            },
            sort: \TaskOccurrence.scheduledDate,
            order: .forward
        )
    }

    private var activePreferences: CozyPreferences {
        preferencesList.first ?? fallbackPreferences
    }

    var body: some View {
        ZStack {
            TabView {
                TodayChecklistView(
                    occurrences: occurrences,
                    preferences: activePreferences,
                    overrides: overrides,
                    calendarBusyByDay: calendarBusyByDay,
                    celebration: celebration,
                    onRebalanceRequested: {
                        refreshCalendarAndRebalance()
                    },
                    onNotificationsSyncRequested: {
                        syncNotifications()
                    }
                )
                .tabItem {
                    Label("Today", systemImage: "checklist.checked")
                }

                MonthCalendarView(
                    occurrences: occurrences,
                    preferences: activePreferences
                )
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }

                ScheduleOverviewView(
                    templates: templates,
                    occurrences: occurrences,
                    preferences: activePreferences,
                    overrides: overrides,
                    calendarBusyByDay: calendarBusyByDay,
                    onRebalanceRequested: {
                        refreshCalendarAndRebalance()
                    }
                )
                .tabItem {
                    Label("Schedule", systemImage: "wand.and.stars")
                }

                ReflectionsView(
                    occurrences: occurrences,
                    preferences: activePreferences
                )
                .tabItem {
                    Label("Summaries", systemImage: "sparkles")
                }

                CozySettingsView(
                    preferences: activePreferences,
                    overrides: overrides,
                    occurrences: occurrences,
                    onScheduleSettingsChanged: {
                        refreshCalendarAndRebalance()
                    },
                    onNotificationSettingsChanged: {
                        syncNotifications()
                    }
                )
                .tabItem {
                    Label("Settings", systemImage: "heart.text.square")
                }
            }
            .tint(CozyTheme.deepRose)

            ConfettiCelebrationOverlay(controller: celebration)
        }
        .preferredColorScheme(.light)
        .sheet(isPresented: $showingDailyCupPrompt) {
            DailyCupPromptSheet(
                preferences: activePreferences,
                logicalToday: currentLogicalDay
            ) {
                refreshCalendarAndRebalance()
            }
        }
        .task {
            bootstrapIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active && hasBootstrapped {
                currentLogicalDay = DateHelpers.logicalToday()
                refreshCalendarAndRebalance()
                evaluateCupPromptIfNeeded()
            } else if newPhase == .background && hasBootstrapped {
                syncNotifications()
            }
        }
        .onReceive(cupResetTimer) { _ in
            guard hasBootstrapped && scenePhase == .active else { return }
            let latestLogicalDay = DateHelpers.logicalToday()
            if !DateHelpers.isSameDay(latestLogicalDay, currentLogicalDay) {
                currentLogicalDay = latestLogicalDay
                refreshCalendarAndRebalance()
                evaluateCupPromptIfNeeded()
            }
        }
    }

    // MARK: - Lifecycle & Orchestration

    private func bootstrapIfNeeded() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        let prefs: CozyPreferences
        if let existing = preferencesList.first {
            prefs = existing
        } else {
            let created = CozyPreferences()
            modelContext.insert(created)
            try? modelContext.save()
            prefs = created
        }

        currentLogicalDay = DateHelpers.logicalToday()
        SmartScheduler.seedStarterTasksIfNeeded(context: modelContext, preferences: prefs)
        refreshCalendarAndRebalance(using: prefs)
        evaluateCupPromptIfNeeded(using: prefs)
    }

    private func evaluateCupPromptIfNeeded(using explicitPrefs: CozyPreferences? = nil) {
        let prefs = explicitPrefs ?? activePreferences
        let logicalDay = DateHelpers.logicalToday()
        currentLogicalDay = logicalDay
        if !prefs.dailyCupPromptEnabled {
            if showingDailyCupPrompt {
                showingDailyCupPrompt = false
            }
            return
        }
        if prefs.needsCupCheckIn(for: logicalDay) && !showingDailyCupPrompt {
            showingDailyCupPrompt = true
        }
    }

    private func fetchOperationalOccurrences(around today: Date) -> [TaskOccurrence] {
        let cutoff = DateHelpers.addDays(
            -SmartScheduler.operationalHistoryBufferDays,
            to: DateHelpers.startOfDay(for: today)
        )
        let pendingRaw = OccurrenceStatus.pending.rawValue
        let descriptor = FetchDescriptor<TaskOccurrence>(
            predicate: #Predicate<TaskOccurrence> { occ in
                occ.statusRaw == pendingRaw || occ.scheduledDate >= cutoff
            },
            sortBy: [SortDescriptor(\TaskOccurrence.scheduledDate, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? occurrences
    }

    private func refreshCalendarAndRebalance(using explicitPrefs: CozyPreferences? = nil) {
        let prefs = explicitPrefs ?? activePreferences
        CozyDataMigrator.migrateIfNeeded(context: modelContext, preferences: prefs)

        let today = DateHelpers.logicalToday()
        currentLogicalDay = today
        let horizonEnd = DateHelpers.addDays(SmartScheduler.defaultHorizonDays - 1, to: today)

        var localIntervalSources: [[Date: [(Date, Date)]]] = []
        var canRunImmediateLocalRebalance = true

        if prefs.useCalendarSync {
            CalendarFreeTimeService.shared.refreshAuthorizationStatus()
            if CalendarFreeTimeService.shared.hasReadAccess {
                let appleIntervals = CalendarFreeTimeService.shared.busyIntervalsByDay(
                    from: today,
                    to: horizonEnd,
                    wakingStartHour: prefs.wakingStartHour,
                    wakingEndHour: prefs.wakingEndHour
                )
                localIntervalSources.append(appleIntervals)
            } else {
                canRunImmediateLocalRebalance = false
            }
        }

        if prefs.useGoogleCalendarSync {
            switch prefs.googleSyncMode {
            case .oauthREST:
                let rawCalID = prefs.googleCalendarID.trimmingCharacters(in: .whitespacesAndNewlines)
                let calID = rawCalID.isEmpty ? "primary" : rawCalID
                let expectedDest = GoogleCalendarService.makeGoogleDestinationKey(
                    accountKey: GoogleCalendarService.shared.activeOAuthAccountIdentity,
                    calendarID: calID
                )
                if let cachedIntervals = prefs.cachedGoogleBusySnapshot?.freshIntervalsByDay(
                    forDestination: expectedDest,
                    maxAgeSeconds: GoogleCalendarService.defaultMaxCachedBusySnapshotAgeSeconds,
                    now: Date()
                ) {
                    localIntervalSources.append(cachedIntervals.filter { $0.key >= today && $0.key <= horizonEnd })
                } else if prefs.shouldAutoSyncCalendarsOnChange {
                    // Defer local rebalance until the async Google busy read succeeds (or reports failure)
                    canRunImmediateLocalRebalance = false
                }

            case .iosGoogleAccount:
                CalendarFreeTimeService.shared.refreshAuthorizationStatus()
                if CalendarFreeTimeService.shared.hasReadAccess,
                   !CalendarFreeTimeService.shared.googleAccountCalendars().isEmpty {
                    let bridgeIntervals = CalendarFreeTimeService.shared.googleBridgeBusyIntervalsByDay(
                        from: today,
                        to: horizonEnd,
                        wakingStartHour: prefs.wakingStartHour,
                        wakingEndHour: prefs.wakingEndHour
                    )
                    localIntervalSources.append(bridgeIntervals)
                } else if prefs.shouldAutoSyncCalendarsOnChange {
                    canRunImmediateLocalRebalance = false
                }
            }
        }

        let initialBusyByDay = CalendarFreeTimeService.mergeBusyIntervalsByDay(localIntervalSources)
        calendarBusyByDay = initialBusyByDay

        if canRunImmediateLocalRebalance {
            SmartScheduler.rebalance(
                context: modelContext,
                preferences: prefs,
                calendarBusyByDay: initialBusyByDay,
                referenceDate: today
            )
        }

        if prefs.shouldAutoSyncCalendarsOnChange || (prefs.autoSyncCalendarChanges && prefs.hasPendingCalendarCleanup) {
            Task { @MainActor in
                let report = await GoogleCalendarService.shared.syncCalendarsAndRebalance(
                    context: modelContext,
                    preferences: prefs,
                    referenceDate: today
                )
                if !report.mergedBusyByDay.isEmpty || !prefs.hasAnyCalendarBusySyncEnabled {
                    calendarBusyByDay = report.mergedBusyByDay
                }
            }
        } else {
            let summaryOccurrences = NotificationManager.fetchOccurrencesForSummarySync(
                context: modelContext,
                now: Date()
            )
            Task { @MainActor in
                await NotificationManager.shared.syncSummaryNotifications(
                    preferences: prefs,
                    occurrences: summaryOccurrences
                )
            }
        }
    }

    private func syncNotifications(using explicitPrefs: CozyPreferences? = nil) {
        let prefs = explicitPrefs ?? activePreferences
        let logicalDay = DateHelpers.logicalToday()
        let summaryOccurrences = NotificationManager.fetchOccurrencesForSummarySync(
            context: modelContext,
            now: Date()
        )
        Task { @MainActor in
            await NotificationManager.shared.syncSummaryNotifications(
                preferences: prefs,
                occurrences: summaryOccurrences
            )
            if prefs.autoSyncCalendarChanges && (prefs.hasAnyCalendarPushEnabled || prefs.hasPendingCalendarCleanup) {
                let report = await GoogleCalendarService.shared.pushOccurrenceChangesWithoutRebalance(
                    context: modelContext,
                    preferences: prefs,
                    referenceDate: logicalDay
                )
                if prefs.hasAnyCalendarBusySyncEnabled && !report.mergedBusyByDay.isEmpty {
                    calendarBusyByDay = report.mergedBusyByDay
                }
            }
        }
    }
}
