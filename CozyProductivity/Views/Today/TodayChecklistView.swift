import SwiftData
import SwiftUI

struct TodayChecklistView: View {
    @Environment(\.modelContext) private var modelContext

    let occurrences: [TaskOccurrence]
    let preferences: CozyPreferences
    let overrides: [DayCapacityOverride]
    let calendarBusyByDay: [Date: Int]
    let celebration: CelebrationController
    var onRebalanceRequested: () -> Void
    var onNotificationsSyncRequested: () -> Void

    @State private var showingNewTaskSheet = false
    @State private var editingTemplate: TaskTemplate?
    @State private var showingPullUpcomingSheet = false

    private var today: Date {
        DateHelpers.startOfDay(for: Date())
    }

    private var todaysOccurrences: [TaskOccurrence] {
        occurrences
            .filter { $0.status != .skipped && DateHelpers.isSameDay($0.scheduledDate, today) }
            .sorted { lhs, rhs in
                if lhs.isCompleted != rhs.isCompleted {
                    return !lhs.isCompleted
                }
                if lhs.displayDurationMinutes != rhs.displayDurationMinutes {
                    return lhs.displayDurationMinutes < rhs.displayDurationMinutes
                }
                return lhs.displayTitle < rhs.displayTitle
            }
    }

    private var pendingToday: [TaskOccurrence] {
        todaysOccurrences.filter { !$0.isCompleted }
    }

    private var completedToday: [TaskOccurrence] {
        todaysOccurrences.filter { $0.isCompleted }
    }

    private var todaySummary: DayCapacitySummary {
        SmartScheduler.buildDaySummaries(
            from: today,
            days: 1,
            occurrences: occurrences,
            preferences: preferences,
            overrides: overrides,
            calendarBusyByDay: calendarBusyByDay
        ).first ?? DayCapacitySummary(
            date: today,
            baseBudgetMinutes: 90,
            calendarBusyMinutes: 0,
            effectiveCapacityMinutes: 90,
            unbookedWakingMinutes: 90,
            scheduledMinutes: 0,
            completedMinutes: 0
        )
    }

    private var upcomingPullableOccurrences: [TaskOccurrence] {
        occurrences
            .filter {
                $0.status == .pending
                    && $0.scheduledDate > today
                    && ($0.template?.recurrence != .daily)
            }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headerSection

                        progressSummaryCard

                        if todaysOccurrences.isEmpty {
                            emptyTodayCard
                        } else {
                            checklistSection
                        }

                        if !upcomingPullableOccurrences.isEmpty {
                            pullAheadBanner
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 96)
                }

                // Floating Add Task Button
                Button {
                    showingNewTaskSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
                        Text("New Task")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 15)
                    .background(
                        Capsule(style: .continuous)
                            .fill(CozyTheme.primaryButtonGradient)
                            .shadow(color: CozyTheme.roseAccent.opacity(0.38), radius: 14, x: 0, y: 7)
                    )
                }
                .padding(.trailing, 20)
                .padding(.bottom, 18)
            }
            .cozyScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingNewTaskSheet) {
                TaskEditorSheet {
                    onRebalanceRequested()
                }
            }
            .sheet(item: $editingTemplate) { template in
                TaskEditorSheet(existingTemplate: template) {
                    onRebalanceRequested()
                }
            }
            .sheet(isPresented: $showingPullUpcomingSheet) {
                pullAheadSheet
            }
        }
    }

    // MARK: - Subviews

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(DateHelpers.cozyGreeting())
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(CozyTheme.inkPrimary)

                Text(DateHelpers.fullHeaderDateString(for: today))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CozyTheme.inkSecondary)
            }

            Spacer()

            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    onRebalanceRequested()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "wand.and.stars")
                        .font(.caption.weight(.bold))
                    Text("Balance")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(CozyTheme.deepRose)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(CozyTheme.petalPill)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rebalance flexible tasks across free days")
        }
    }

    private var progressSummaryCard: some View {
        let totalCount = todaysOccurrences.count
        let doneCount = completedToday.count
        let progress = totalCount > 0 ? Double(doneCount) / Double(totalCount) : 0.0
        let remainingTaskMinutes = pendingToday.reduce(0) { $0 + $1.displayDurationMinutes }

        return HStack(spacing: 18) {
            // Circular Pastel Progress Ring
            ZStack {
                Circle()
                    .stroke(CozyTheme.petalPill, lineWidth: 9)
                    .frame(width: 68, height: 68)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        CozyTheme.primaryButtonGradient,
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 68, height: 68)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: progress)

                VStack(spacing: 0) {
                    Text("\(doneCount)/\(totalCount)")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(CozyTheme.inkPrimary)
                    Text("done")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(CozyTheme.inkSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(statusHeadline(total: totalCount, done: doneCount))
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(CozyTheme.inkPrimary)

                Text(
                    remainingTaskMinutes > 0
                        ? "\(DateHelpers.formatDuration(minutes: remainingTaskMinutes)) left on checklist · \(DateHelpers.formatDuration(minutes: todaySummary.remainingFreeMinutes)) extra free budget"
                        : "0m left on today's checklist · \(DateHelpers.formatDuration(minutes: todaySummary.effectiveCapacityMinutes)) daily budget"
                )
                .font(.caption)
                .foregroundStyle(CozyTheme.inkSecondary)

                if preferences.useCalendarSync && todaySummary.calendarBusyMinutes > 0 {
                    Label(
                        "\(DateHelpers.formatDuration(minutes: todaySummary.calendarBusyMinutes)) busy on Apple Calendar",
                        systemImage: "calendar"
                    )
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(CozyTheme.deepRose)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(CozyTheme.headerCardGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(CozyTheme.cardBorder, lineWidth: 1)
        )
        .shadow(color: CozyTheme.roseAccent.opacity(0.10), radius: 14, x: 0, y: 6)
    }

    private var checklistSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !pendingToday.isEmpty {
                Text("Today's Checklist")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(CozyTheme.deepRose)

                ForEach(pendingToday) { occ in
                    checklistCard(for: occ)
                }
            }

            if !completedToday.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(CozyTheme.roseAccent)
                    Text("Completed Today (\(completedToday.count))")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(CozyTheme.inkSecondary)
                }
                .padding(.top, pendingToday.isEmpty ? 0 : 8)

                ForEach(completedToday) { occ in
                    checklistCard(for: occ)
                }
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.80), value: completedToday.count)
    }

    private func checklistCard(for occurrence: TaskOccurrence) -> some View {
        TaskChecklistCardView(
            occurrence: occurrence,
            onToggleComplete: {
                toggleCompletion(for: occurrence)
            },
            onEditTemplate: {
                editingTemplate = occurrence.template
            },
            onMoveToTomorrow: {
                moveOccurrenceToTomorrow(occurrence)
            },
            onMoveToFreestDay: {
                occurrence.isManuallyPinned = false
                if occurrence.scheduledDate == today {
                    // Gently nudge to tomorrow or freer future day in its window
                    occurrence.scheduledDate = DateHelpers.addDays(1, to: today)
                }
                try? modelContext.save()
                onRebalanceRequested()
            },
            onDeleteTemplate: {
                if let template = occurrence.template {
                    modelContext.delete(template)
                } else {
                    modelContext.delete(occurrence)
                }
                try? modelContext.save()
                onRebalanceRequested()
            }
        )
    }

    private var emptyTodayCard: some View {
        VStack(spacing: 12) {
            Text("🌷")
                .font(.system(size: 42))
            Text("Your day is wide open & calm")
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(CozyTheme.inkPrimary)
            Text("Add recurring or once tasks and CozyProductivity will automatically place them on days with the most free time.")
                .font(.subheadline)
                .foregroundStyle(CozyTheme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .cozyCard()
    }

    private var pullAheadBanner: some View {
        Button {
            showingPullUpcomingSheet = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.title3)
                    .foregroundStyle(CozyTheme.deepRose)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Have extra cozy energy today?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CozyTheme.inkPrimary)
                    Text("Pull one of \(upcomingPullableOccurrences.count) upcoming tasks onto today's checklist")
                        .font(.caption)
                        .foregroundStyle(CozyTheme.inkSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(CozyTheme.inkMuted)
            }
            .padding(16)
            .cozyCard(cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }

    private var pullAheadSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(upcomingPullableOccurrences.prefix(15)) { occ in
                        HStack(spacing: 12) {
                            Text(occ.displayEmoji)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(occ.displayTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(CozyTheme.inkPrimary)
                                Text("Scheduled \(DateHelpers.shortWeekdayName(for: occ.scheduledDate)) · \(DateHelpers.formatDuration(minutes: occ.displayDurationMinutes))")
                                    .font(.caption)
                                    .foregroundStyle(CozyTheme.inkSecondary)
                            }
                            Spacer()
                            Button("Do Today") {
                                occ.scheduledDate = today
                                occ.isManuallyPinned = true
                                try? modelContext.save()
                                onNotificationsSyncRequested()
                                showingPullUpcomingSheet = false
                            }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(CozyTheme.primaryButtonGradient)
                            )
                            .buttonStyle(.plain)
                        }
                        .padding(14)
                        .cozyCard(cornerRadius: 18)
                    }
                }
                .padding(18)
            }
            .cozyScreenBackground()
            .navigationTitle("Upcoming Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showingPullUpcomingSheet = false
                    }
                    .foregroundStyle(CozyTheme.deepRose)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Actions

    private func toggleCompletion(for occurrence: TaskOccurrence) {
        let becomingCompleted = !occurrence.isCompleted
        occurrence.isCompleted = becomingCompleted
        try? modelContext.save()

        if becomingCompleted {
            let remainingPending = todaysOccurrences.filter { !$0.isCompleted && $0.id != occurrence.id }
            celebration.celebrate(
                taskTitle: occurrence.displayTitle,
                allDoneForToday: remainingPending.isEmpty
            )
        }

        onNotificationsSyncRequested()
    }

    private func moveOccurrenceToTomorrow(_ occurrence: TaskOccurrence) {
        occurrence.scheduledDate = DateHelpers.addDays(1, to: today)
        occurrence.isManuallyPinned = true
        try? modelContext.save()
        onNotificationsSyncRequested()
    }

    private func statusHeadline(total: Int, done: Int) -> String {
        if total == 0 {
            return "Peaceful & unhurried ✨"
        } else if done == total {
            return "Everything done today! 💖"
        } else if done == 0 {
            return "A gentle start awaits 🌸"
        } else {
            return "Warm momentum going 🌷"
        }
    }
}
