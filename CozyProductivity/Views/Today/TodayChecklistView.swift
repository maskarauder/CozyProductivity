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

    private struct BonusSlotSelection: Identifiable {
        let id: Int // 1 or 2
    }

    @State private var showingNewTaskSheet = false
    @State private var editingTemplate: TaskTemplate?
    @State private var pickingBonusSlot: BonusSlotSelection?

    private var today: Date {
        DateHelpers.startOfDay(for: Date())
    }

    private var baseTodaysOccurrences: [TaskOccurrence] {
        occurrences
            .filter {
                $0.status != .skipped
                    && $0.bonusForDate == nil
                    && DateHelpers.isSameDay($0.scheduledDate, today)
            }
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

    private var pendingBaseToday: [TaskOccurrence] {
        baseTodaysOccurrences.filter { !$0.isCompleted }
    }

    private var completedBaseToday: [TaskOccurrence] {
        baseTodaysOccurrences.filter { $0.isCompleted }
    }

    private var allBaseCompletedToday: Bool {
        !baseTodaysOccurrences.isEmpty && pendingBaseToday.isEmpty
    }

    private func bonusOccurrence(forSlot slot: Int) -> TaskOccurrence? {
        occurrences.first {
            $0.status != .skipped
                && $0.bonusSlot == slot
                && ($0.bonusForDate.map { DateHelpers.isSameDay($0, today) } ?? false)
        }
    }

    private var streakSnapshot: StreakSnapshot {
        StreakAndBonusService.evaluate(
            occurrences: occurrences,
            persistedLongestStreak: preferences.longestRecordedStreak,
            today: today
        )
    }

    private var todayTier: DayCompletionTier {
        streakSnapshot.tier(for: today)
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

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headerSection

                        progressSummaryCard

                        if baseTodaysOccurrences.isEmpty {
                            emptyTodayCard
                        } else {
                            if !pendingBaseToday.isEmpty {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("Today's Checklist")
                                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                                        .foregroundStyle(CozyTheme.deepRose)

                                    ForEach(pendingBaseToday) { occ in
                                        checklistCard(for: occ)
                                    }
                                }
                            }

                            if allBaseCompletedToday {
                                bonusTasksSection
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }

                            if !completedBaseToday.isEmpty {
                                VStack(alignment: .leading, spacing: 14) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "heart.fill")
                                            .font(.caption)
                                            .foregroundStyle(CozyTheme.roseAccent)
                                        Text("Completed Today (\(completedBaseToday.count))")
                                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                                            .foregroundStyle(CozyTheme.inkSecondary)
                                    }
                                    .padding(.top, 4)

                                    ForEach(completedBaseToday) { occ in
                                        checklistCard(for: occ)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 96)
                    .animation(.spring(response: 0.44, dampingFraction: 0.80), value: allBaseCompletedToday)
                    .animation(.spring(response: 0.40, dampingFraction: 0.82), value: todayTier)
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
            .sheet(item: $pickingBonusSlot) { selection in
                bonusTaskPickerSheet(forSlot: selection.id)
            }
        }
    }

    // MARK: - Header & Progress Card

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(DateHelpers.cozyGreeting())
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(CozyTheme.inkPrimary)

                HStack(spacing: 8) {
                    Text(DateHelpers.fullHeaderDateString(for: today))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(CozyTheme.inkSecondary)

                    if streakSnapshot.currentStreak > 0 || streakSnapshot.longestStreak > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "flame.fill")
                                .font(.caption2)
                                .foregroundStyle(CozyTheme.goldBorder)
                            Text("Streak \(streakSnapshot.currentStreak)d")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(CozyTheme.inkPrimary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(CozyTheme.pastelButter))
                    }
                }
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
        let totalCount = baseTodaysOccurrences.count
        let doneCount = completedBaseToday.count
        let progress = totalCount > 0 ? Double(doneCount) / Double(totalCount) : 0.0
        let remainingTaskMinutes = pendingBaseToday.reduce(0) { $0 + $1.displayDurationMinutes }
        let baseStyle = preferences.baseHighlightStyle

        return HStack(spacing: 18) {
            // Circular Pastel / Medal Progress Ring
            ZStack {
                Circle()
                    .stroke(CozyTheme.petalPill, lineWidth: 9)
                    .frame(width: 68, height: 68)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        ringGradient(baseStyle: baseStyle),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 68, height: 68)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: progress)

                VStack(spacing: 0) {
                    if todayTier != .none {
                        Text(todayTier.medalEmoji)
                            .font(.title3)
                    } else {
                        Text("\(doneCount)/\(totalCount)")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(CozyTheme.inkPrimary)
                        Text("done")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(CozyTheme.inkSecondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(statusHeadline(total: totalCount, done: doneCount))
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(CozyTheme.inkPrimary)

                    if todayTier != .none {
                        Text(todayTier.badgeTitle(baseStyle: baseStyle))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(todayTier.inkColor(baseStyle: baseStyle))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(todayTier.fillGradient(baseStyle: baseStyle) ?? CozyTheme.headerCardGradient)
                            )
                            .overlay(
                                Capsule().strokeBorder(todayTier.borderColor(baseStyle: baseStyle), lineWidth: 1)
                            )
                    }
                }

                Text(
                    remainingTaskMinutes > 0
                        ? "\(DateHelpers.formatDuration(minutes: remainingTaskMinutes)) left on checklist · \(DateHelpers.formatDuration(minutes: todaySummary.remainingFreeMinutes)) extra free budget"
                        : "All daily tasks done! · Current streak: \(streakSnapshot.currentStreak)d (Best: \(streakSnapshot.longestStreak)d)"
                )
                .font(.caption)
                .foregroundStyle(CozyTheme.inkSecondary)

                if preferences.hasAnyCalendarBusySyncEnabled && todaySummary.calendarBusyMinutes > 0 {
                    let calSourceLabel: String = {
                        if preferences.useCalendarSync && preferences.useGoogleCalendarSync {
                            return "Apple + Google Calendar"
                        } else if preferences.useGoogleCalendarSync {
                            return "Google Calendar"
                        } else {
                            return "Apple Calendar"
                        }
                    }()
                    Label(
                        "\(DateHelpers.formatDuration(minutes: todaySummary.calendarBusyMinutes)) busy on \(calSourceLabel)",
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
                .fill(summaryBackgroundGradient(baseStyle: baseStyle))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    todayTier == .none ? CozyTheme.cardBorder : todayTier.borderColor(baseStyle: baseStyle),
                    lineWidth: todayTier == .none ? 1 : 1.5
                )
        )
        .shadow(color: CozyTheme.roseAccent.opacity(0.10), radius: 14, x: 0, y: 6)
    }

    // MARK: - Two Optional Bonus Tasks Section (Next 7 Days)

    private var bonusTasksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Optional Bonus Tasks", systemImage: "sparkles")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(CozyTheme.deepRose)
                Spacer()
                Text("From next 7 days")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CozyTheme.inkSecondary)
            }

            Text("1 bonus task highlights today in Silver (preserves streak). Complete both for Gold PERFECT (+1 streak)!")
                .font(.caption)
                .foregroundStyle(CozyTheme.inkSecondary)

            ForEach([1, 2], id: \.self) { slot in
                bonusSlotCard(slot: slot)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.76))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    todayTier == .gold
                        ? CozyTheme.goldBorder
                        : (todayTier == .silver ? CozyTheme.silverBorder : CozyTheme.cardBorder),
                    lineWidth: 1.3
                )
        )
    }

    @ViewBuilder
    private func bonusSlotCard(slot: Int) -> some View {
        let assigned = bonusOccurrence(forSlot: slot)
        let candidates = StreakAndBonusService.eligibleCandidatesForBonusSlot(
            slot: slot,
            occurrences: occurrences,
            today: today
        )
        let tierBadgeLabel = slot == 1 ? "Bonus 1 · 🥈 Silver" : "Bonus 2 · 🥇 Gold"

        if let occ = assigned {
            HStack(spacing: 12) {
                Button {
                    toggleCompletion(for: occ)
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                occ.isCompleted
                                    ? AnyShapeStyle(todayTier == .gold ? CozyTheme.goldGradient : CozyTheme.silverGradient)
                                    : AnyShapeStyle(CozyTheme.softBlushFill)
                            )
                            .frame(width: 34, height: 34)
                            .overlay(
                                Circle().strokeBorder(
                                    occ.isCompleted
                                        ? (todayTier == .gold ? CozyTheme.goldBorder : CozyTheme.silverBorder)
                                        : CozyTheme.roseAccent.opacity(0.65),
                                    lineWidth: 2
                                )
                            )

                        if occ.isCompleted {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(todayTier == .gold ? CozyTheme.goldInk : CozyTheme.silverInk)
                        }
                    }
                    .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(occ.displayEmoji)
                        Text(occ.displayTitle)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(occ.isCompleted ? CozyTheme.inkMuted : CozyTheme.inkPrimary)
                            .strikethrough(occ.isCompleted, color: CozyTheme.inkMuted)
                            .lineLimit(2)
                    }

                    HStack(spacing: 6) {
                        Text(tierBadgeLabel)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(slot == 2 ? CozyTheme.goldInk : CozyTheme.silverInk)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(slot == 2 ? CozyTheme.goldGradient : CozyTheme.silverGradient)
                            )

                        Text("\(DateHelpers.shortWeekdayName(for: occ.scheduledDate)) · \(DateHelpers.formatDuration(minutes: occ.displayDurationMinutes))")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(CozyTheme.inkSecondary)
                    }
                }

                Spacer(minLength: 4)

                if !occ.isCompleted && candidates.count > 1 {
                    Button {
                        pickingBonusSlot = BonusSlotSelection(id: slot)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Swap")
                        }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(CozyTheme.deepRose)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(CozyTheme.petalPill))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(13)
            .cozyCard(isCompleted: occ.isCompleted, cornerRadius: 18)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture {
                toggleCompletion(for: occ)
            }
        } else {
            Button {
                if !candidates.isEmpty {
                    pickingBonusSlot = BonusSlotSelection(id: slot)
                } else {
                    showingNewTaskSheet = true
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: candidates.isEmpty ? "plus.circle.fill" : "sparkles")
                        .font(.title3)
                        .foregroundStyle(CozyTheme.roseAccent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidates.isEmpty ? "No more upcoming tasks in next 7 days" : "Choose \(tierBadgeLabel) Task")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(CozyTheme.inkPrimary)
                        Text(candidates.isEmpty ? "Tap to add an upcoming task to unlock this bonus slot" : "Select from \(candidates.count) upcoming tasks in the next 7 days")
                            .font(.caption)
                            .foregroundStyle(CozyTheme.inkSecondary)
                    }

                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(CozyTheme.inkMuted)
                }
                .padding(14)
                .cozyCard(cornerRadius: 18)
            }
            .buttonStyle(.plain)
        }
    }

    private func bonusTaskPickerSheet(forSlot slot: Int) -> some View {
        let candidates = StreakAndBonusService.eligibleCandidatesForBonusSlot(
            slot: slot,
            occurrences: occurrences,
            today: today
        )
        let currentSelectionID = bonusOccurrence(forSlot: slot)?.id

        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pick any task scheduled within the next 7 days for Optional Bonus Slot \(slot):")
                        .font(.footnote)
                        .foregroundStyle(CozyTheme.inkSecondary)
                        .padding(.horizontal, 4)

                    if candidates.isEmpty {
                        Text("No uncompleted tasks are scheduled in the next 7 days yet 🌸")
                            .font(.subheadline)
                            .foregroundStyle(CozyTheme.inkSecondary)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(candidates) { candidate in
                            let isSelected = candidate.id == currentSelectionID
                            Button {
                                StreakAndBonusService.selectBonusTask(
                                    candidate,
                                    forSlot: slot,
                                    occurrences: occurrences,
                                    context: modelContext,
                                    today: today
                                )
                                pickingBonusSlot = nil
                            } label: {
                                HStack(spacing: 12) {
                                    Text(candidate.displayEmoji)
                                        .font(.title3)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(candidate.displayTitle)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(CozyTheme.inkPrimary)
                                        Text("\(DateHelpers.fullHeaderDateString(for: candidate.scheduledDate)) · \(DateHelpers.formatDuration(minutes: candidate.displayDurationMinutes)) · \(candidate.recurrenceLabel)")
                                            .font(.caption)
                                            .foregroundStyle(CozyTheme.inkSecondary)
                                    }
                                    Spacer()
                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(CozyTheme.roseAccent)
                                    } else {
                                        Text("Select")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Capsule().fill(CozyTheme.primaryButtonGradient))
                                    }
                                }
                                .padding(14)
                                .cozyCard(cornerRadius: 18)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(18)
            }
            .cozyScreenBackground()
            .navigationTitle("Bonus Task \(slot) (Next 7 Days)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        pickingBonusSlot = nil
                    }
                    .foregroundStyle(CozyTheme.deepRose)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Base Checklist Card & Empty State

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
                    occurrence.scheduledDate = DateHelpers.addDays(1, to: today)
                }
                try? modelContext.save()
                onRebalanceRequested()
            },
            onDeleteTemplate: {
                deleteTemplatePreservingHistory(for: occurrence)
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

    // MARK: - Actions & Styling Helpers

    private func toggleCompletion(for occurrence: TaskOccurrence) {
        let previousTier = streakSnapshot.tier(for: today)
        let becomingCompleted = !occurrence.isCompleted
        occurrence.isCompleted = becomingCompleted
        try? modelContext.save()

        StreakAndBonusService.syncBonusSlots(
            context: modelContext,
            occurrences: occurrences,
            preferences: preferences,
            today: today
        )

        let updatedSnapshot = StreakAndBonusService.evaluate(
            occurrences: occurrences,
            persistedLongestStreak: preferences.longestRecordedStreak,
            today: today
        )
        let newTier = updatedSnapshot.tier(for: today)

        if becomingCompleted {
            if newTier == .gold && previousTier < .gold {
                celebration.celebrateGoldPerfect(streakDays: updatedSnapshot.currentStreak)
            } else if newTier == .silver && previousTier < .silver {
                celebration.celebrateSilver(
                    taskTitle: occurrence.displayTitle,
                    streakDays: updatedSnapshot.currentStreak
                )
            } else if newTier == .base && previousTier < .base {
                celebration.celebrate(
                    taskTitle: occurrence.displayTitle,
                    allDoneForToday: true
                )
            } else {
                celebration.celebrate(
                    taskTitle: occurrence.displayTitle,
                    allDoneForToday: false
                )
            }
        }

        onNotificationsSyncRequested()
    }

    private func moveOccurrenceToTomorrow(_ occurrence: TaskOccurrence) {
        occurrence.scheduledDate = DateHelpers.addDays(1, to: today)
        occurrence.isManuallyPinned = true
        try? modelContext.save()
        StreakAndBonusService.syncBonusSlots(
            context: modelContext,
            occurrences: occurrences,
            preferences: preferences,
            today: today
        )
        onNotificationsSyncRequested()
    }

    private func deleteTemplatePreservingHistory(for occurrence: TaskOccurrence) {
        if let template = occurrence.template {
            for item in template.occurrences where item.status == .pending {
                modelContext.delete(item)
            }
            modelContext.delete(template)
        } else if occurrence.status == .pending {
            modelContext.delete(occurrence)
        }
        try? modelContext.save()
        onRebalanceRequested()
    }

    private func statusHeadline(total: Int, done: Int) -> String {
        if total == 0 {
            return "Peaceful & unhurried ✨"
        }
        switch todayTier {
        case .gold:
            return "PERFECT Gold Day! 🥇"
        case .silver:
            return "Silver Day Achieved! 🥈"
        case .base:
            return "Daily Checklist Complete! 🌸"
        case .none:
            return done == 0 ? "A gentle start awaits 🌸" : "Warm momentum going 🌷"
        }
    }

    private func ringGradient(baseStyle: BaseHighlightColorStyle) -> LinearGradient {
        switch todayTier {
        case .gold: return CozyTheme.goldGradient
        case .silver: return CozyTheme.silverGradient
        case .base: return baseStyle.gradient
        case .none: return CozyTheme.primaryButtonGradient
        }
    }

    private func summaryBackgroundGradient(baseStyle: BaseHighlightColorStyle) -> LinearGradient {
        switch todayTier {
        case .gold:
            return LinearGradient(
                colors: [Color(red: 1.0, green: 0.97, blue: 0.84), Color(red: 1.0, green: 0.91, blue: 0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .silver:
            return LinearGradient(
                colors: [Color(red: 0.96, green: 0.97, blue: 1.0), Color(red: 0.89, green: 0.92, blue: 0.97)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .base:
            return baseStyle == .roseBronze
                ? LinearGradient(
                    colors: [Color(red: 1.0, green: 0.93, blue: 0.91), Color(red: 0.97, green: 0.85, blue: 0.82)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                : CozyTheme.headerCardGradient
        case .none:
            return CozyTheme.headerCardGradient
        }
    }
}
