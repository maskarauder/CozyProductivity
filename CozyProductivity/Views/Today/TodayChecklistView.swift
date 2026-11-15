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
    @State private var showingCupPromptSheet = false
    @State private var editingTemplate: TaskTemplate?
    @State private var pickingBonusSlot: BonusSlotSelection?

    private var today: Date {
        DateHelpers.logicalToday()
    }

    private var baseTodaysOccurrences: [TaskOccurrence] {
        occurrences
            .filter {
                $0.status.isScheduled
                    && $0.bonusDay() == nil
                    && DateHelpers.isSameDay($0.scheduledDay(), today)
            }
            .sorted { lhs, rhs in
                if lhs.isCompleted != rhs.isCompleted {
                    return !lhs.isCompleted
                }
                let lhsUrgent = (lhs.effectiveHardDeadline() ?? .distantFuture) <= today
                let rhsUrgent = (rhs.effectiveHardDeadline() ?? .distantFuture) <= today
                if lhsUrgent != rhsUrgent {
                    return lhsUrgent && !rhsUrgent
                }
                if lhs.effectiveLoadMinutes != rhs.effectiveLoadMinutes {
                    return lhs.effectiveLoadMinutes < rhs.effectiveLoadMinutes
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
            $0.status.isScheduled
                && $0.bonusSlot == slot
                && ($0.bonusDay().map { DateHelpers.isSameDay($0, today) } ?? false)
        }
    }

    private var streakSnapshot: StreakSnapshot {
        StreakAndBonusService.evaluate(
            occurrences: occurrences,
            persistedLongestStreak: preferences.longestRecordedStreak,
            optionalBonusTasksEnabled: preferences.optionalBonusTasksEnabled,
            historicalArchive: preferences.historicalStreakArchive,
            today: today
        )
    }

    private var todayTier: DayCompletionTier {
        streakSnapshot.tier(for: today)
    }

    private var isADDFriendly: Bool {
        preferences.addFriendlyMode
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
                    VStack(alignment: .leading, spacing: isADDFriendly ? 14 : 20) {
                        headerSection

                        progressSummaryCard

                        if baseTodaysOccurrences.isEmpty {
                            emptyTodayCard
                        } else {
                            if !pendingBaseToday.isEmpty {
                                VStack(alignment: .leading, spacing: isADDFriendly ? 10 : 14) {
                                    if !isADDFriendly {
                                        Text("Today's Checklist")
                                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                                            .foregroundStyle(CozyTheme.deepRose)
                                    }

                                    ForEach(pendingBaseToday) { occ in
                                        checklistCard(for: occ)
                                    }
                                }
                            }

                            if allBaseCompletedToday && preferences.optionalBonusTasksEnabled {
                                bonusTasksSection
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }

                            if !completedBaseToday.isEmpty {
                                VStack(alignment: .leading, spacing: isADDFriendly ? 10 : 14) {
                                    HStack(spacing: 6) {
                                        if !isADDFriendly {
                                            Image(systemName: "heart.fill")
                                                .font(.caption)
                                                .foregroundStyle(CozyTheme.roseAccent)
                                        }
                                        Text(isADDFriendly ? "Done (\(completedBaseToday.count))" : "Completed Today (\(completedBaseToday.count))")
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
                        Text(isADDFriendly ? "Task" : "New Task")
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
                TaskEditorSheet(addFriendlyMode: isADDFriendly) {
                    onRebalanceRequested()
                }
            }
            .sheet(isPresented: $showingCupPromptSheet) {
                DailyCupPromptSheet(
                    preferences: preferences,
                    logicalToday: today
                ) {
                    onRebalanceRequested()
                }
            }
            .sheet(item: $editingTemplate) { template in
                TaskEditorSheet(
                    existingTemplate: template,
                    addFriendlyMode: isADDFriendly
                ) {
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
        let activeCup = preferences.cupHours(for: today)

        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isADDFriendly ? "Today" : DateHelpers.cozyGreeting())
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(CozyTheme.inkPrimary)

                HStack(spacing: 8) {
                    Text(isADDFriendly ? DateHelpers.shortMonthDayString(for: today) : DateHelpers.fullHeaderDateString(for: today))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(CozyTheme.inkSecondary)

                    if preferences.streaksEnabled && (streakSnapshot.currentStreak > 0 || streakSnapshot.longestStreak > 0) {
                        HStack(spacing: 4) {
                            Image(systemName: "flame.fill")
                                .font(.caption2)
                                .foregroundStyle(CozyTheme.goldBorder)
                            Text(isADDFriendly ? "\(streakSnapshot.currentStreak)d" : "Streak \(streakSnapshot.currentStreak)d")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(CozyTheme.inkPrimary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(CozyTheme.pastelButter))
                    }
                }
            }

            Spacer(minLength: 6)

            HStack(spacing: 6) {
                if preferences.dailyCupPromptEnabled || activeCup != nil {
                    Button {
                        showingCupPromptSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            if !isADDFriendly {
                                Text(activeCup == 0 ? "🫖" : "🍵")
                                    .font(.caption)
                            }
                            Text(activeCup.map { isADDFriendly ? "\($0)h" : "Cup \($0)h" } ?? (isADDFriendly ? "Cup" : "Set Cup"))
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(CozyTheme.deepRose)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(CozyTheme.softBlushFill)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(CozyTheme.cardBorder, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("How full is your cup today")
                }

                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        onRebalanceRequested()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                            .font(.caption.weight(.bold))
                        if !isADDFriendly {
                            Text("Balance")
                                .font(.caption.weight(.bold))
                        }
                    }
                    .foregroundStyle(CozyTheme.deepRose)
                    .padding(.horizontal, 11)
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
    }

    private var progressSummaryCard: some View {
        let totalCount = baseTodaysOccurrences.count
        let doneCount = completedBaseToday.count
        let progress = totalCount > 0 ? Double(doneCount) / Double(totalCount) : 0.0
        let remainingTaskMinutes = pendingBaseToday.reduce(0) { $0 + $1.displayDurationMinutes }
        let remainingLoadMinutes = pendingBaseToday.reduce(0) { $0 + $1.effectiveLoadMinutes }
        let baseStyle = preferences.baseHighlightStyle
        let activeCup = preferences.cupHours(for: today)
        let showRanks = preferences.dayRanksEnabled

        return HStack(spacing: 18) {
            // Circular Pastel / Optional Medal Progress Ring
            ZStack {
                Circle()
                    .stroke(CozyTheme.petalPill, lineWidth: 9)
                    .frame(width: isADDFriendly ? 56 : 68, height: isADDFriendly ? 56 : 68)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        ringGradient(baseStyle: baseStyle),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: isADDFriendly ? 56 : 68, height: isADDFriendly ? 56 : 68)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: progress)

                VStack(spacing: 0) {
                    if showRanks && todayTier != .none {
                        Text(todayTier.medalEmoji)
                            .font(.title3)
                    } else if activeCup == 0 && totalCount == 0 && !isADDFriendly {
                        Text("🫖")
                            .font(.title3)
                    } else {
                        Text("\(doneCount)/\(totalCount)")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(CozyTheme.inkPrimary)
                        if !isADDFriendly {
                            Text("done")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(CozyTheme.inkSecondary)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(statusHeadline(total: totalCount, done: doneCount, activeCup: activeCup))
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(CozyTheme.inkPrimary)

                    if showRanks && todayTier != .none && !isADDFriendly {
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

                let detail = summaryDetailLine(
                    totalCount: totalCount,
                    remainingTaskMinutes: remainingTaskMinutes,
                    remainingLoadMinutes: remainingLoadMinutes,
                    activeCup: activeCup
                )
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(CozyTheme.inkSecondary)
                }

                if !isADDFriendly && preferences.hasAnyCalendarBusySyncEnabled && todaySummary.calendarBusyMinutes > 0 {
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
        .padding(isADDFriendly ? 14 : 18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(summaryBackgroundGradient(baseStyle: baseStyle))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    (!showRanks || todayTier == .none) ? CozyTheme.cardBorder : todayTier.borderColor(baseStyle: baseStyle),
                    lineWidth: (!showRanks || todayTier == .none) ? 1 : 1.5
                )
        )
        .shadow(color: CozyTheme.roseAccent.opacity(0.10), radius: 14, x: 0, y: 6)
    }

    // MARK: - Two Optional Bonus Tasks Section (Next 7 Days)

    private var bonusTasksSection: some View {
        let showRanks = preferences.dayRanksEnabled

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(isADDFriendly ? "Bonus Tasks" : "Optional Bonus Tasks", systemImage: "sparkles")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(CozyTheme.deepRose)
                Spacer()
                if !isADDFriendly {
                    Text("From next 7 days")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CozyTheme.inkSecondary)
                }
            }

            if !isADDFriendly {
                if showRanks && preferences.streaksEnabled {
                    Text("1 bonus task highlights today in Silver (preserves streak). Complete both for Gold PERFECT (+1 streak)!")
                        .font(.caption)
                        .foregroundStyle(CozyTheme.inkSecondary)
                } else if showRanks {
                    Text("1 bonus task highlights today in Silver. Complete both for Gold PERFECT!")
                        .font(.caption)
                        .foregroundStyle(CozyTheme.inkSecondary)
                } else {
                    Text("Pull up to 2 extra tasks forward from the next 7 days.")
                        .font(.caption)
                        .foregroundStyle(CozyTheme.inkSecondary)
                }
            }

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
                    showRanks && todayTier == .gold
                        ? CozyTheme.goldBorder
                        : (showRanks && todayTier == .silver ? CozyTheme.silverBorder : CozyTheme.cardBorder),
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
        let showRanks = preferences.dayRanksEnabled
        let tierBadgeLabel: String = {
            if showRanks && !isADDFriendly {
                return slot == 1 ? "Bonus 1 · 🥈 Silver" : "Bonus 2 · 🥇 Gold"
            }
            return "Bonus \(slot)"
        }()

        if let occ = assigned {
            HStack(spacing: 12) {
                Button {
                    toggleCompletion(for: occ)
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                occ.isCompleted
                                    ? (showRanks
                                        ? AnyShapeStyle(todayTier == .gold ? CozyTheme.goldGradient : CozyTheme.silverGradient)
                                        : AnyShapeStyle(CozyTheme.primaryButtonGradient))
                                    : AnyShapeStyle(CozyTheme.softBlushFill)
                            )
                            .frame(width: 34, height: 34)
                            .overlay(
                                Circle().strokeBorder(
                                    occ.isCompleted
                                        ? (showRanks ? (todayTier == .gold ? CozyTheme.goldBorder : CozyTheme.silverBorder) : CozyTheme.roseAccent)
                                        : CozyTheme.roseAccent.opacity(0.65),
                                    lineWidth: 2
                                )
                            )

                        if occ.isCompleted {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(showRanks ? (todayTier == .gold ? CozyTheme.goldInk : CozyTheme.silverInk) : .white)
                        }
                    }
                    .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if !isADDFriendly {
                            Text(occ.displayEmoji)
                        }
                        Text(occ.displayTitle)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(occ.isCompleted ? CozyTheme.inkMuted : CozyTheme.inkPrimary)
                            .strikethrough(occ.isCompleted, color: CozyTheme.inkMuted)
                            .lineLimit(2)
                    }

                    HStack(spacing: 6) {
                        Text(tierBadgeLabel)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(showRanks ? (slot == 2 ? CozyTheme.goldInk : CozyTheme.silverInk) : CozyTheme.deepRose)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(
                                    showRanks
                                        ? AnyShapeStyle(slot == 2 ? CozyTheme.goldGradient : CozyTheme.silverGradient)
                                        : AnyShapeStyle(CozyTheme.petalPill)
                                )
                            )

                        Text("\(DateHelpers.shortWeekdayName(for: occ.scheduledDay())) · \(DateHelpers.formatDuration(minutes: occ.displayDurationMinutes))")
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
                            if !isADDFriendly {
                                Text("Swap")
                            }
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
                        Text(candidates.isEmpty ? (isADDFriendly ? "No upcoming tasks" : "No more upcoming tasks in next 7 days") : "Choose \(tierBadgeLabel)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(CozyTheme.inkPrimary)
                        if !isADDFriendly {
                            Text(candidates.isEmpty ? "Tap to add an upcoming task" : "Select from \(candidates.count) upcoming tasks")
                                .font(.caption)
                                .foregroundStyle(CozyTheme.inkSecondary)
                        }
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
                    if !isADDFriendly {
                        Text("Pick any task scheduled within the next 7 days for Bonus Slot \(slot):")
                            .font(.footnote)
                            .foregroundStyle(CozyTheme.inkSecondary)
                            .padding(.horizontal, 4)
                    }

                    if candidates.isEmpty {
                        Text(isADDFriendly ? "No upcoming tasks." : "No uncompleted tasks are scheduled in the next 7 days yet 🌸")
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
                                onNotificationsSyncRequested()
                                pickingBonusSlot = nil
                            } label: {
                                HStack(spacing: 12) {
                                    if !isADDFriendly {
                                        Text(candidate.displayEmoji)
                                            .font(.title3)
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(candidate.displayTitle)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(CozyTheme.inkPrimary)
                                        Text("\(DateHelpers.shortMonthDayString(for: candidate.scheduledDay())) · \(DateHelpers.formatDuration(minutes: candidate.displayDurationMinutes))")
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
            .navigationTitle("Bonus \(slot)")
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
            today: today,
            addFriendlyMode: isADDFriendly,
            onToggleComplete: {
                toggleCompletion(for: occurrence)
            },
            onAdjustWeight: { newWeight in
                adjustWeight(for: occurrence, to: newWeight, updateTemplate: true)
            },
            onEditTemplate: {
                editingTemplate = occurrence.template
            },
            onMoveToTomorrow: {
                moveOccurrenceToTomorrow(occurrence)
            },
            onMoveToFreestDay: {
                occurrence.isManuallyPinned = false
                if DateHelpers.isSameDay(occurrence.scheduledDay(), today) {
                    occurrence.setScheduledDay(DateHelpers.addDays(1, to: today))
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
        let isEmptyCupDay = preferences.cupHours(for: today) == 0

        return VStack(spacing: isADDFriendly ? 6 : 12) {
            if !isADDFriendly {
                Text(isEmptyCupDay ? "🫖" : "🌷")
                    .font(.system(size: 42))
            }
            Text(
                isADDFriendly
                    ? (isEmptyCupDay ? "0 hours today" : "No tasks today")
                    : (isEmptyCupDay ? "Your cup is resting at 0 hours today" : "Your day is wide open & calm")
            )
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(CozyTheme.inkPrimary)
            .multilineTextAlignment(.center)

            if !isADDFriendly {
                Text(
                    isEmptyCupDay
                        ? "Tasks without a hard deadline moved back a day so you can gently recharge. Tap your Cup badge above anytime if your energy shifts 🌸"
                        : "Add recurring or once tasks and Cozy will automatically place them on days with the most free time."
                )
                .font(.subheadline)
                .foregroundStyle(CozyTheme.inkSecondary)
                .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(isADDFriendly ? 20 : 28)
        .cozyCard()
    }

    // MARK: - Actions & Styling Helpers

    private func adjustWeight(
        for occurrence: TaskOccurrence,
        to newWeight: TaskWeight,
        updateTemplate: Bool
    ) {
        let previousWeight = occurrence.displayWeight
        occurrence.applyWeightAdjustment(newWeight, updateTemplate: updateTemplate)
        try? modelContext.save()

        if previousWeight != newWeight {
            onRebalanceRequested()
            StreakAndBonusService.syncBonusSlots(
                context: modelContext,
                occurrences: occurrences,
                preferences: preferences,
                today: today
            )
        }
    }

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
            optionalBonusTasksEnabled: preferences.optionalBonusTasksEnabled,
            historicalArchive: preferences.historicalStreakArchive,
            today: today
        )
        let newTier = updatedSnapshot.tier(for: today)
        let celebrationOptions = CelebrationController.Options(
            confettiEnabled: preferences.confettiEnabled,
            streaksEnabled: preferences.streaksEnabled,
            dayRanksEnabled: preferences.dayRanksEnabled,
            optionalBonusTasksEnabled: preferences.optionalBonusTasksEnabled,
            addFriendlyMode: preferences.addFriendlyMode
        )

        if becomingCompleted {
            if newTier == .gold && previousTier < .gold {
                celebration.celebrateGoldPerfect(
                    streakDays: updatedSnapshot.currentStreak,
                    options: celebrationOptions
                )
            } else if newTier == .silver && previousTier < .silver {
                celebration.celebrateSilver(
                    taskTitle: occurrence.displayTitle,
                    streakDays: updatedSnapshot.currentStreak,
                    options: celebrationOptions
                )
            } else if newTier == .base && previousTier < .base {
                celebration.celebrate(
                    taskTitle: occurrence.displayTitle,
                    allDoneForToday: true,
                    options: celebrationOptions
                )
            } else {
                celebration.celebrate(
                    taskTitle: occurrence.displayTitle,
                    allDoneForToday: false,
                    options: celebrationOptions
                )
            }
        }

        onNotificationsSyncRequested()
    }

    private func moveOccurrenceToTomorrow(_ occurrence: TaskOccurrence) {
        occurrence.setScheduledDay(DateHelpers.addDays(1, to: today))
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
            for item in template.occurrences {
                if item.status == .pending {
                    preferences.enqueuePendingDeletions(for: item)
                    modelContext.delete(item)
                } else {
                    item.freezeSnapshotsFromCurrentState()
                }
            }
            modelContext.delete(template)
        } else if occurrence.status == .pending {
            preferences.enqueuePendingDeletions(for: occurrence)
            modelContext.delete(occurrence)
        }
        try? modelContext.save()
        onRebalanceRequested()
    }

    private func statusHeadline(total: Int, done: Int, activeCup: Int?) -> String {
        if isADDFriendly {
            if total == 0 {
                return activeCup == 0 ? "0 hours today" : "Open day"
            }
            let remaining = max(0, total - done)
            return remaining == 0 ? "All done" : "\(remaining) left"
        }

        if total == 0 {
            if activeCup == 0 {
                return "Empty cup rest day 🫖"
            }
            return "Peaceful & unhurried ✨"
        }
        if !preferences.dayRanksEnabled {
            return done >= total ? "Daily Checklist Complete! 🌸" : (done == 0 ? "A gentle start awaits 🌸" : "Warm momentum going 🌷")
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

    private func summaryDetailLine(
        totalCount: Int,
        remainingTaskMinutes: Int,
        remainingLoadMinutes: Int,
        activeCup: Int?
    ) -> String {
        if isADDFriendly {
            if totalCount == 0 { return "" }
            if remainingTaskMinutes > 0 {
                return "\(DateHelpers.formatDuration(minutes: remainingTaskMinutes)) left"
            }
            return preferences.streaksEnabled ? "Streak \(streakSnapshot.currentStreak)d" : ""
        }

        if totalCount == 0 && activeCup == 0 {
            if preferences.streaksEnabled {
                return "Cup is 0h · Tasks moved back a day (streak safe at \(streakSnapshot.currentStreak)d)"
            }
            return "Cup is 0h · Tasks moved back a day"
        }
        if remainingTaskMinutes > 0 {
            let cupSuffix: String
            if let hrs = activeCup {
                cupSuffix = "\(DateHelpers.formatDuration(minutes: todaySummary.remainingFreeMinutes)) left in \(hrs)h cup"
            } else {
                cupSuffix = "\(DateHelpers.formatDuration(minutes: todaySummary.remainingFreeMinutes)) extra free budget"
            }
            if remainingLoadMinutes != remainingTaskMinutes {
                return "\(DateHelpers.formatDuration(minutes: remainingTaskMinutes)) tasks (\(DateHelpers.formatDuration(minutes: remainingLoadMinutes)) w/ weight) · \(cupSuffix)"
            }
            return "\(DateHelpers.formatDuration(minutes: remainingTaskMinutes)) left on checklist · \(cupSuffix)"
        }
        if preferences.streaksEnabled {
            return "All daily tasks done! · Current streak: \(streakSnapshot.currentStreak)d (Best: \(streakSnapshot.longestStreak)d)"
        }
        return "All daily tasks done!"
    }

    private func ringGradient(baseStyle: BaseHighlightColorStyle) -> LinearGradient {
        guard preferences.dayRanksEnabled else {
            return CozyTheme.primaryButtonGradient
        }
        switch todayTier {
        case .gold: return CozyTheme.goldGradient
        case .silver: return CozyTheme.silverGradient
        case .base: return baseStyle.gradient
        case .none: return CozyTheme.primaryButtonGradient
        }
    }

    private func summaryBackgroundGradient(baseStyle: BaseHighlightColorStyle) -> LinearGradient {
        guard preferences.dayRanksEnabled else {
            return CozyTheme.headerCardGradient
        }
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
