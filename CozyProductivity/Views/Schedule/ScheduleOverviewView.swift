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
    @State private var selectedDay: Date = DateHelpers.startOfDay(for: Date())
    @State private var showingNewTaskSheet = false
    @State private var editingTemplate: TaskTemplate?

    private var today: Date {
        DateHelpers.startOfDay(for: Date())
    }

    private var fourteenDaySummaries: [DayCapacitySummary] {
        SmartScheduler.buildDaySummaries(
            from: today,
            days: 14,
            occurrences: occurrences,
            preferences: preferences,
            overrides: overrides,
            calendarBusyByDay: calendarBusyByDay
        )
    }

    private var selectedSummary: DayCapacitySummary {
        fourteenDaySummaries.first { DateHelpers.isSameDay($0.date, selectedDay) }
            ?? fourteenDaySummaries.first
            ?? DayCapacitySummary(
                date: today,
                baseBudgetMinutes: 90,
                calendarBusyMinutes: 0,
                effectiveCapacityMinutes: 90,
                unbookedWakingMinutes: 90,
                scheduledMinutes: 0,
                completedMinutes: 0
            )
    }

    private var occurrencesOnSelectedDay: [TaskOccurrence] {
        occurrences
            .filter { $0.status != .skipped && DateHelpers.isSameDay($0.scheduledDate, selectedSummary.date) }
            .sorted { $0.displayDurationMinutes > $1.displayDurationMinutes }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Smart Schedule")
                                .font(.system(.title2, design: .rounded, weight: .bold))
                                .foregroundStyle(CozyTheme.inkPrimary)
                            Text("Tasks flow naturally to days with more free time")
                                .font(.footnote)
                                .foregroundStyle(CozyTheme.inkSecondary)
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
                TaskEditorSheet {
                    onRebalanceRequested()
                }
            }
            .sheet(item: $editingTemplate) { template in
                TaskEditorSheet(existingTemplate: template) {
                    onRebalanceRequested()
                }
            }
        }
    }

    // MARK: - 14-Day Free-Time Strip & Selected Day Breakdown

    private var timelineContent: some View {
        let maxCap = max(120, fourteenDaySummaries.map { max($0.effectiveCapacityMinutes, $0.scheduledMinutes) }.max() ?? 180)

        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Next 14 Days Free-Time Load", systemImage: "chart.bar.fill")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(CozyTheme.deepRose)
                    Spacer()
                    Text("Tap a day")
                        .font(.caption)
                        .foregroundStyle(CozyTheme.inkMuted)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 10) {
                        ForEach(fourteenDaySummaries) { summary in
                            let isSelected = DateHelpers.isSameDay(summary.date, selectedSummary.date)
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

                HStack(spacing: 14) {
                    legendDot(color: CozyTheme.roseAccent, label: "Scheduled tasks")
                    legendDot(color: CozyTheme.petalPill, label: "Available free budget")
                }
            }
            .padding(18)
            .cozyCard()

            // Selected Day Details
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DateHelpers.fullHeaderDateString(for: selectedSummary.date))
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(CozyTheme.inkPrimary)
                        Text("\(DateHelpers.formatDuration(minutes: selectedSummary.scheduledMinutes)) scheduled · \(DateHelpers.formatDuration(minutes: selectedSummary.remainingFreeMinutes)) free time left")
                            .font(.caption)
                            .foregroundStyle(CozyTheme.inkSecondary)
                    }
                    Spacer()
                    if selectedSummary.calendarBusyMinutes > 0 {
                        Label("\(DateHelpers.formatDuration(minutes: selectedSummary.calendarBusyMinutes)) cal", systemImage: "calendar")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(CozyTheme.deepRose)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(CozyTheme.petalPill))
                    }
                }

                if occurrencesOnSelectedDay.isEmpty {
                    Text("No tasks scheduled on this day 🌸")
                        .font(.subheadline)
                        .foregroundStyle(CozyTheme.inkSecondary)
                        .padding(.vertical, 12)
                } else {
                    ForEach(occurrencesOnSelectedDay) { occ in
                        HStack(spacing: 12) {
                            Text(occ.displayEmoji)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(occ.displayTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(occ.isCompleted ? CozyTheme.inkMuted : CozyTheme.inkPrimary)
                                    .strikethrough(occ.isCompleted)
                                Text("\(occ.recurrenceLabel) · \(DateHelpers.formatDuration(minutes: occ.displayDurationMinutes))")
                                    .font(.caption)
                                    .foregroundStyle(CozyTheme.inkSecondary)
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
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(CozyTheme.canvasMiddle)
                        )
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
                    Text("🎀")
                        .font(.largeTitle)
                    Text("No tasks yet")
                        .font(.headline)
                        .foregroundStyle(CozyTheme.inkPrimary)
                    Text("Tap + to add once, daily, weekly, or monthly tasks.")
                        .font(.subheadline)
                        .foregroundStyle(CozyTheme.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(28)
                .cozyCard()
            } else {
                ForEach(templates) { template in
                    HStack(spacing: 12) {
                        Text(template.emoji)
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(CozyTheme.softBlushFill)
                            )

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

                                if template.isAutoScheduled && template.recurrence != .daily {
                                    Label("Auto", systemImage: "wand.and.stars")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(CozyTheme.inkSecondary)
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
