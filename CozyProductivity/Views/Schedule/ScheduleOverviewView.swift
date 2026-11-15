import SwiftData
import SwiftUI

struct ScheduleOverviewView: View {
    @Environment(\.modelContext) private var modelContext

    let templates: [TaskTemplate]
    let occurrences: [TaskOccurrence]
    let preferences: CozyPreferences
    let overrides: [DayCapacityOverride]
    let calendarBusyByDay: [Date: Int]
    var onRebalanceRequested: () -> Void

    enum SectionTab: String, CaseIterable {
        case timeline = "14-Day Balance"
        case library = "All Tasks"
    }

    @State private var activeSection: SectionTab = .timeline
    @State private var selectedDay: Date = DateHelpers.logicalToday()
    @State private var showingNewTaskSheet = false
    @State private var editingTemplate: TaskTemplate?

    private var today: Date {
        DateHelpers.logicalToday()
    }

    private struct TimelineSnapshot {
        let summaries: [DayCapacitySummary]
        let selectedSummary: DayCapacitySummary
        let occurrencesOnSelectedDay: [TaskOccurrence]
    }

    private func makeTimelineSnapshot() -> TimelineSnapshot {
        let currentToday = today
        let summaries = SmartScheduler.buildDaySummaries(
            from: currentToday,
            days: 14,
            occurrences: occurrences,
            preferences: preferences,
            overrides: overrides,
            calendarBusyByDay: calendarBusyByDay
        )
        let activeSummary = summaries.first { DateHelpers.isSameDay($0.date, selectedDay) }
            ?? summaries.first
            ?? DayCapacitySummary(
                date: currentToday,
                baseBudgetMinutes: 90,
                calendarBusyMinutes: 0,
                effectiveCapacityMinutes: 90,
                unbookedWakingMinutes: 90,
                scheduledMinutes: 0,
                completedMinutes: 0
            )

        let targetDate = activeSummary.date
        let dayOccurrences = occurrences
            .filter { occ in
                guard occ.status.isScheduled else { return false }
                let effectiveDate = occ.isCompleted
                    ? (occ.bonusDay() ?? occ.scheduledDay())
                    : occ.scheduledDay()
                return DateHelpers.isSameDay(effectiveDate, targetDate)
            }
            .sorted { $0.effectiveLoadMinutes > $1.effectiveLoadMinutes }

        return TimelineSnapshot(
            summaries: summaries,
            selectedSummary: activeSummary,
            occurrencesOnSelectedDay: dayOccurrences
        )
    }

    private var isADDFriendly: Bool {
        preferences.addFriendlyMode
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: isADDFriendly ? 14 : 18) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(isADDFriendly ? "Schedule" : "Smart Schedule")
                                .font(.system(.title2, design: .rounded, weight: .bold))
                                .foregroundStyle(CozyTheme.inkPrimary)
                            if !isADDFriendly {
                                Text("Tasks flow naturally to days with more free time")
                                    .font(.footnote)
                                    .foregroundStyle(CozyTheme.inkSecondary)
                            }
                        }
                        Spacer()
                        Button {
                            showingNewTaskSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(
                                    Circle().fill(CozyTheme.primaryButtonGradient)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    // Pastel Pill Switcher
                    HStack(spacing: 8) {
                        ForEach(SectionTab.allCases, id: \.self) { tab in
                            let isSelected = activeSection == tab
                            Button {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    activeSection = tab
                                }
                            } label: {
                                Text(tab.rawValue)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(isSelected ? .white : CozyTheme.inkSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(
                                                isSelected
                                                    ? AnyShapeStyle(CozyTheme.primaryButtonGradient)
                                                    : AnyShapeStyle(Color.white.opacity(0.65))
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(CozyTheme.softBlushFill)
                    )

                    if activeSection == .timeline {
                        timelineContent
                    } else {
                        taskLibraryContent
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 32)
            }
            .cozyScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingNewTaskSheet) {
                TaskEditorSheet(addFriendlyMode: isADDFriendly) {
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
        }
    }

    // MARK: - 14-Day Free-Time Strip & Selected Day Breakdown

    private var timelineContent: some View {
        let snapshot = makeTimelineSnapshot()
        let summaries = snapshot.summaries
        let activeSummary = snapshot.selectedSummary
        let dayOccurrences = snapshot.occurrencesOnSelectedDay
        let maxCap = max(120, summaries.map { max($0.effectiveCapacityMinutes, $0.scheduledMinutes) }.max() ?? 180)

        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(isADDFriendly ? "Next 14 Days" : "Next 14 Days Free-Time Load", systemImage: "chart.bar.fill")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(CozyTheme.deepRose)
                    Spacer()
                    if !isADDFriendly {
                        Text("Tap a day")
                            .font(.caption)
                            .foregroundStyle(CozyTheme.inkMuted)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 10) {
                        ForEach(summaries) { summary in
                            let isSelected = DateHelpers.isSameDay(summary.date, activeSummary.date)
                            let capHeight = max(14, CGFloat(summary.effectiveCapacityMinutes) / CGFloat(maxCap) * 108)
                            let usedHeight = summary.effectiveCapacityMinutes > 0
                                ? min(capHeight, CGFloat(summary.scheduledMinutes) / CGFloat(maxCap) * 108)
                                : (summary.scheduledMinutes > 0 ? 18 : 0)

                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    selectedDay = summary.date
                                }
                            } label: {
                                VStack(spacing: 6) {
                                    Text(DateHelpers.formatDuration(minutes: summary.remainingFreeMinutes))
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .foregroundStyle(summary.isOverCapacity ? CozyTheme.deepRose : CozyTheme.inkSecondary)

                                    ZStack(alignment: .bottom) {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(CozyTheme.softBlushFill)
                                            .frame(width: 30, height: 108)

                                        // Available capacity outline/fill
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(CozyTheme.petalPill.opacity(0.65))
                                            .frame(width: 30, height: capHeight)

                                        // Scheduled minutes bar
                                        if usedHeight > 0 {
                                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                .fill(
                                                    summary.isOverCapacity
                                                        ? AnyShapeStyle(CozyTheme.deepRose)
                                                        : AnyShapeStyle(CozyTheme.primaryButtonGradient)
                                                )
                                                .frame(width: 30, height: usedHeight)
                                        }
                                    }

                                    Text(DateHelpers.shortWeekdayName(for: summary.date))
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(isSelected ? CozyTheme.deepRose : CozyTheme.inkPrimary)

                                    Text("\(DateHelpers.calendar.component(.day, from: summary.date))")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(isSelected ? .white : CozyTheme.inkSecondary)
                                        .frame(width: 24, height: 24)
                                        .background(
                                            Circle()
                                                .fill(isSelected ? CozyTheme.roseAccent : Color.clear)
                                        )
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(isSelected ? CozyTheme.softBlushFill.opacity(0.75) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if !isADDFriendly {
                    HStack(spacing: 14) {
                        legendDot(color: CozyTheme.roseAccent, label: "Scheduled tasks")
                        legendDot(color: CozyTheme.petalPill, label: "Available free budget")
                    }
                }
            }
            .padding(18)
            .cozyCard()

            // Selected Day Details
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isADDFriendly ? DateHelpers.shortMonthDayString(for: activeSummary.date) : DateHelpers.fullHeaderDateString(for: activeSummary.date))
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(CozyTheme.inkPrimary)
                        Text(
                            isADDFriendly
                                ? "\(DateHelpers.formatDuration(minutes: activeSummary.remainingFreeMinutes)) free"
                                : "\(DateHelpers.formatDuration(minutes: activeSummary.scheduledMinutes)) weighted load · \(DateHelpers.formatDuration(minutes: activeSummary.remainingFreeMinutes)) free capacity left"
                        )
                        .font(.caption)
                        .foregroundStyle(CozyTheme.inkSecondary)
                    }
                    Spacer()
                    if let cupHours = activeSummary.activeCupHours {
                        Text(isADDFriendly ? "\(cupHours)h" : "\(cupHours == 0 ? "🫖" : "🍵") Cup \(cupHours)h")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(CozyTheme.deepRose)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(CozyTheme.softBlushFill))
                    } else if activeSummary.calendarBusyMinutes > 0 {
                        Label("\(DateHelpers.formatDuration(minutes: activeSummary.calendarBusyMinutes)) cal", systemImage: "calendar")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(CozyTheme.deepRose)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(CozyTheme.petalPill))
                    }
                }

                if dayOccurrences.isEmpty {
                    Text(
                        isADDFriendly
                            ? "No tasks"
                            : (activeSummary.activeCupHours == 0
                                ? "Cup is resting at 0 hours today — tasks moved back a day 🌸"
                                : "No tasks scheduled on this day 🌸")
                    )
                    .font(.subheadline)
                    .foregroundStyle(CozyTheme.inkSecondary)
                    .padding(.vertical, 12)
                } else {
                    ForEach(dayOccurrences) { occ in
                        let weight = occ.displayWeight
                        let deadline = occ.effectiveHardDeadline()

                        Button {
                            if let template = occ.template {
                                editingTemplate = template
                            }
                        } label: {
                            HStack(spacing: 12) {
                                if !isADDFriendly {
                                    Text(occ.displayEmoji)
                                        .font(.title3)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(occ.displayTitle)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(occ.isCompleted ? CozyTheme.inkMuted : CozyTheme.inkPrimary)
                                        .strikethrough(occ.isCompleted)
                                    HStack(spacing: 6) {
                                        Text("\(occ.recurrenceLabel) · \(DateHelpers.formatDuration(minutes: occ.displayDurationMinutes))")
                                            .font(.caption)
                                            .foregroundStyle(CozyTheme.inkSecondary)

                                        if !isADDFriendly || weight != .light {
                                            Text(isADDFriendly ? weight.title : "\(weight.emoji) \(weight.badgeLabel)")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(weight.pillForeground)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(weight.pillBackground))
                                        }
                                    }
                                    if let deadline {
                                        Text(isADDFriendly ? "Due \(DateHelpers.shortMonthDayString(for: deadline))" : "📌 Hard Deadline: \(DateHelpers.shortMonthDayString(for: deadline))")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(CozyTheme.deepRose)
                                    }
                                }
                                Spacer()
                                if occ.isCompleted {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(CozyTheme.roseAccent)
                                } else if occ.template?.isAutoScheduled == true {
                                    Image(systemName: "wand.and.stars")
                                        .font(.caption)
                                        .foregroundStyle(CozyTheme.deepRose)
                                }
                                if occ.template != nil {
                                    Image(systemName: "pencil")
                                        .font(.caption)
                                        .foregroundStyle(CozyTheme.inkMuted)
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(CozyTheme.canvasMiddle)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(18)
            .cozyCard()
        }
    }

    // MARK: - Recurring & Once Task Library

    private var taskLibraryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if templates.isEmpty {
                VStack(spacing: 10) {
                    if !isADDFriendly {
                        Text("🎀")
                            .font(.largeTitle)
                    }
                    Text("No tasks yet")
                        .font(.headline)
                        .foregroundStyle(CozyTheme.inkPrimary)
                    if !isADDFriendly {
                        Text("Tap + to add once, daily, weekly, or monthly tasks.")
                            .font(.subheadline)
                            .foregroundStyle(CozyTheme.inkSecondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(28)
                .cozyCard()
            } else {
                ForEach(templates) { template in
                    let weight = template.weight
                    let deadline = template.normalizedHardDeadline()

                    HStack(spacing: 12) {
                        if !isADDFriendly {
                            Text(template.emoji)
                                .font(.title2)
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(CozyTheme.softBlushFill)
                                )
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(template.title)
                                .font(.system(.subheadline, design: .rounded, weight: .bold))
                                .foregroundStyle(template.isActive ? CozyTheme.inkPrimary : CozyTheme.inkMuted)

                            HStack(spacing: 6) {
                                Text(template.recurrenceDisplayLabel)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(template.recurrence.pillForeground)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(template.recurrence.pillBackground))

                                Text(DateHelpers.formatDuration(minutes: template.durationMinutes))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(CozyTheme.deepRose)

                                if !isADDFriendly || weight != .light {
                                    Text(isADDFriendly ? weight.title : "\(weight.emoji) \(weight.badgeLabel)")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(weight.pillForeground)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(weight.pillBackground))
                                }
                            }

                            if deadline != nil || (!isADDFriendly && template.isAutoScheduled && template.recurrence != .daily) {
                                HStack(spacing: 8) {
                                    if let deadline {
                                        Text(isADDFriendly ? "Due \(DateHelpers.shortMonthDayString(for: deadline))" : "📌 Hard Deadline: \(DateHelpers.shortMonthDayString(for: deadline))")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(CozyTheme.deepRose)
                                    }
                                    if !isADDFriendly && template.isAutoScheduled && template.recurrence != .daily {
                                        Label("Auto", systemImage: "wand.and.stars")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(CozyTheme.inkSecondary)
                                    }
                                }
                            }
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { template.isActive },
                            set: { newValue in
                                template.isActive = newValue
                                try? modelContext.save()
                                onRebalanceRequested()
                            }
                        ))
                        .labelsHidden()
                        .tint(CozyTheme.roseAccent)

                        Button {
                            editingTemplate = template
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.subheadline)
                                .foregroundStyle(CozyTheme.deepRose)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(14)
                    .cozyCard(cornerRadius: 20)
                }
            }
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(label)
                .font(.caption2)
                .foregroundStyle(CozyTheme.inkSecondary)
        }
    }
}
