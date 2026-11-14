import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \TaskTemplate.createdAt, order: .forward)
    private var templates: [TaskTemplate]

    @Query(sort: \TaskOccurrence.scheduledDate, order: .forward)
    private var occurrences: [TaskOccurrence]

    @Query
    private var preferencesList: [CozyPreferences]

    @Query(sort: \DayCapacityOverride.date, order: .forward)
    private var overrides: [DayCapacityOverride]

    @State private var celebration = CelebrationController()
    @State private var calendarBusyByDay: [Date: Int] = [:]
    @State private var fallbackPreferences = CozyPreferences()
    @State private var hasBootstrapped = false

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
                    Label("Schedule", systemImage: "calendar.badge.clock")
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
        .task {
            bootstrapIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active && hasBootstrapped {
                refreshCalendarAndRebalance()
            } else if newPhase == .background && hasBootstrapped {
                syncNotifications()
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

        SmartScheduler.seedStarterTasksIfNeeded(context: modelContext, preferences: prefs)
        refreshCalendarAndRebalance(using: prefs)
    }

    private func refreshCalendarAndRebalance(using explicitPrefs: CozyPreferences? = nil) {
        let prefs = explicitPrefs ?? activePreferences
        let today = DateHelpers.startOfDay(for: Date())
        let horizonEnd = DateHelpers.addDays(SmartScheduler.defaultHorizonDays - 1, to: today)

        if prefs.useCalendarSync {
            calendarBusyByDay = CalendarFreeTimeService.shared.busyMinutesByDay(
                from: today,
                to: horizonEnd,
                wakingStartHour: prefs.wakingStartHour,
                wakingEndHour: prefs.wakingEndHour
            )
        } else {
            calendarBusyByDay = [:]
        }

        SmartScheduler.rebalance(
            context: modelContext,
            preferences: prefs,
            calendarBusyByDay: calendarBusyByDay,
            referenceDate: today
        )

        syncNotifications(using: prefs)
    }

    private func syncNotifications(using explicitPrefs: CozyPreferences? = nil) {
        let prefs = explicitPrefs ?? activePreferences
        let latestOccurrences = (try? modelContext.fetch(FetchDescriptor<TaskOccurrence>())) ?? occurrences
        Task { @MainActor in
            await NotificationManager.shared.syncSummaryNotifications(
                preferences: prefs,
                occurrences: latestOccurrences
            )
        }
    }
}
