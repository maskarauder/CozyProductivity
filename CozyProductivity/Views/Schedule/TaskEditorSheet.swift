import SwiftData
import SwiftUI

struct TaskEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    var existingTemplate: TaskTemplate?
    var addFriendlyMode: Bool = false
    var onSaved: () -> Void

    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var emoji: String = "🌸"
    @State private var category: TaskCategory = .selfCare
    @State private var recurrence: RecurrenceKind = .once
    @State private var durationMinutes: Int = 30
    @State private var weight: TaskWeight = .light
    @State private var hasHardDeadline: Bool = false
    @State private var hardDeadlineDate: Date = DateHelpers.addDays(3, to: DateHelpers.logicalToday())
    @State private var customIntervalDays: Int = 3
    @State private var isAutoScheduled: Bool = true
    @State private var anchorDate: Date = DateHelpers.logicalToday()
    @State private var flexibleWindowDays: Int = 7

    private let emojiChoices = [
        "🌸", "🌷", "🎀", "💖", "✨", "🪴",
        "🧺", "🏡", "🍵", "📖", "💌", "🕯️",
        "🧁", "🛁", "🧘‍♀️", "🎨", "🛒", "🌙"
    ]

    private let durationPresets = [10, 15, 20, 30, 45, 60, 90, 120]

    init(
        existingTemplate: TaskTemplate? = nil,
        addFriendlyMode: Bool = false,
        onSaved: @escaping () -> Void
    ) {
        self.existingTemplate = existingTemplate
        self.addFriendlyMode = addFriendlyMode
        self.onSaved = onSaved
        if let task = existingTemplate {
            _title = State(initialValue: task.title)
            _notes = State(initialValue: task.notes)
            _emoji = State(initialValue: task.emoji)
            _category = State(initialValue: task.category)
            _recurrence = State(initialValue: task.recurrence)
            _durationMinutes = State(initialValue: task.durationMinutes)
            _weight = State(initialValue: task.weight)
            _hasHardDeadline = State(initialValue: task.hasHardDeadline)
            _hardDeadlineDate = State(initialValue: task.normalizedHardDeadline() ?? task.hardDeadlineDate ?? DateHelpers.addDays(3, to: DateHelpers.logicalToday()))
            _customIntervalDays = State(initialValue: task.customIntervalDays)
            _isAutoScheduled = State(initialValue: task.isAutoScheduled)
            _anchorDate = State(initialValue: task.normalizedAnchorDate())
            _flexibleWindowDays = State(initialValue: task.flexibleWindowDays)
        }
    }

    private var effectiveRankingMinutes: Int {
        durationMinutes + weight.extraRankingMinutes
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Title & Notes Card
                    VStack(alignment: .leading, spacing: 14) {
                        Text(addFriendlyMode ? "Task" : "Task Details")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(CozyTheme.deepRose)

                        HStack(spacing: 12) {
                            if !addFriendlyMode {
                                Text(emoji)
                                    .font(.system(size: 30))
                                    .frame(width: 50, height: 50)
                                    .background(
                                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                                            .fill(CozyTheme.softBlushFill)
                                    )
                            }

                            TextField(addFriendlyMode ? "Task name" : "e.g., Take out the trash", text: $title)
                                .font(.system(.body, design: .rounded, weight: .medium))
                                .foregroundStyle(CozyTheme.inkPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(CozyTheme.canvasMiddle)
                                )
                        }

                        if !addFriendlyMode {
                            // Emoji Picker Row
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(emojiChoices, id: \.self) { choice in
                                        Button {
                                            emoji = choice
                                        } label: {
                                            Text(choice)
                                                .font(.title3)
                                                .frame(width: 38, height: 38)
                                                .background(
                                                    Circle()
                                                        .fill(emoji == choice ? CozyTheme.petalPill : Color.clear)
                                                )
                                                .overlay(
                                                    Circle()
                                                        .strokeBorder(
                                                            emoji == choice ? CozyTheme.roseAccent : CozyTheme.cardBorder.opacity(0.5),
                                                            lineWidth: 1
                                                        )
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        if !addFriendlyMode || !notes.isEmpty {
                            TextField(addFriendlyMode ? "Notes" : "Optional gentle note or checklist steps...", text: $notes, axis: .vertical)
                                .lineLimit(2...4)
                                .font(.subheadline)
                                .foregroundStyle(CozyTheme.inkPrimary)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(CozyTheme.canvasMiddle)
                                )
                        }

                        if !addFriendlyMode {
                            // Category Pills
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(TaskCategory.allCases) { item in
                                        let selected = category == item
                                        Button {
                                            category = item
                                        } label: {
                                            HStack(spacing: 5) {
                                                Text(item.defaultEmoji)
                                                Text(item.title)
                                                    .font(.caption.weight(.semibold))
                                            }
                                            .foregroundStyle(selected ? .white : CozyTheme.inkPrimary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(
                                                Capsule(style: .continuous)
                                                    .fill(
                                                        selected
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
                    }
                    .padding(18)
                    .cozyCard()

                    // Duration & Task Weight Card
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label(addFriendlyMode ? "Duration" : "Length of Time", systemImage: "clock.fill")
                                .font(.system(.subheadline, design: .rounded, weight: .bold))
                                .foregroundStyle(CozyTheme.deepRose)
                            Spacer()
                            Text(DateHelpers.formatDuration(minutes: durationMinutes))
                                .font(.system(.headline, design: .rounded, weight: .bold))
                                .foregroundStyle(CozyTheme.roseAccent)
                        }

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                            ForEach(durationPresets, id: \.self) { preset in
                                let selected = durationMinutes == preset
                                Button {
                                    durationMinutes = preset
                                } label: {
                                    Text(DateHelpers.formatDuration(minutes: preset))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(selected ? .white : CozyTheme.inkPrimary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 9)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(
                                                    selected
                                                        ? AnyShapeStyle(CozyTheme.primaryButtonGradient)
                                                        : AnyShapeStyle(CozyTheme.softBlushFill)
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Stepper(
                            addFriendlyMode
                                ? DateHelpers.formatDuration(minutes: durationMinutes)
                                : "Fine-tune: \(DateHelpers.formatDuration(minutes: durationMinutes))",
                            value: $durationMinutes,
                            in: 5...360,
                            step: 5
                        )
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(CozyTheme.inkSecondary)

                        Divider().overlay(CozyTheme.cardBorder)

                        // Task Weight Selector (Light +0m, Normal +30m, Heavy +1h)
                        HStack {
                            Label(addFriendlyMode ? "Weight" : "Task Weight", systemImage: "scalemass.fill")
                                .font(.system(.subheadline, design: .rounded, weight: .bold))
                                .foregroundStyle(CozyTheme.deepRose)
                            Spacer()
                            Text(addFriendlyMode ? DateHelpers.formatDuration(minutes: effectiveRankingMinutes) : "Ranks as \(DateHelpers.formatDuration(minutes: effectiveRankingMinutes))")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(CozyTheme.deepRose)
                        }

                        HStack(spacing: 8) {
                            ForEach(TaskWeight.allCases) { option in
                                let selected = weight == option
                                Button {
                                    weight = option
                                } label: {
                                    VStack(spacing: 3) {
                                        if !addFriendlyMode {
                                            Text(option.emoji)
                                                .font(.subheadline)
                                        }
                                        Text(option.title)
                                            .font(.caption.weight(.bold))
                                        Text(option.extraRankingMinutes == 0 ? "+0m" : "+\(DateHelpers.formatDuration(minutes: option.extraRankingMinutes))")
                                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                                            .opacity(0.85)
                                    }
                                    .foregroundStyle(selected ? .white : CozyTheme.inkPrimary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(
                                                selected
                                                    ? AnyShapeStyle(CozyTheme.primaryButtonGradient)
                                                    : AnyShapeStyle(CozyTheme.softBlushFill)
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !addFriendlyMode {
                            Text("Default is Light (30m). Normal adds 30m and Heavy adds 1h to ranking & daily cup load.")
                                .font(.caption2)
                                .foregroundStyle(CozyTheme.inkSecondary)
                        }
                    }
                    .padding(18)
                    .cozyCard()

                    // Recurrence, Smart Auto-Scheduling & Hard Deadline Card
                    VStack(alignment: .leading, spacing: 14) {
                        Label(addFriendlyMode ? "Schedule" : "How Often & When", systemImage: "wand.and.stars")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(CozyTheme.deepRose)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            ForEach(RecurrenceKind.allCases) { kind in
                                let selected = recurrence == kind
                                Button {
                                    recurrence = kind
                                    if kind == .daily {
                                        isAutoScheduled = false
                                    } else if existingTemplate == nil {
                                        isAutoScheduled = true
                                    }
                                } label: {
                                    VStack(spacing: 4) {
                                        if !addFriendlyMode {
                                            Image(systemName: kind.systemImage)
                                                .font(.subheadline)
                                        }
                                        Text(kind.title)
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.8)
                                    }
                                    .foregroundStyle(selected ? .white : CozyTheme.inkPrimary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(
                                                selected
                                                    ? AnyShapeStyle(CozyTheme.primaryButtonGradient)
                                                    : AnyShapeStyle(CozyTheme.softBlushFill)
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if recurrence == .customDays {
                            Stepper(
                                "Every \(customIntervalDays) days",
                                value: $customIntervalDays,
                                in: 2...60
                            )
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(CozyTheme.inkPrimary)
                        }

                        if recurrence.supportsFlexibleDaySelection {
                            Divider()
                                .overlay(CozyTheme.cardBorder)

                            Toggle(isOn: $isAutoScheduled) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(addFriendlyMode ? "Auto-schedule" : "Auto-distribute to freest day ✨")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(CozyTheme.inkPrimary)
                                    if !addFriendlyMode {
                                        Text(autoScheduleExplanation)
                                            .font(.caption)
                                            .foregroundStyle(CozyTheme.inkSecondary)
                                    }
                                }
                            }
                            .tint(CozyTheme.roseAccent)

                            if isAutoScheduled && recurrence == .once && !hasHardDeadline {
                                Picker(addFriendlyMode ? "Window" : "Schedule within", selection: $flexibleWindowDays) {
                                    Text("3 days").tag(3)
                                    Text("7 days").tag(7)
                                    Text("14 days").tag(14)
                                    Text("30 days").tag(30)
                                }
                                .pickerStyle(.menu)
                                .tint(CozyTheme.deepRose)
                                .font(.subheadline)
                                .foregroundStyle(CozyTheme.inkPrimary)
                            } else if !isAutoScheduled {
                                DatePicker(
                                    recurrence == .once ? "Date" : "Anchor Date",
                                    selection: $anchorDate,
                                    displayedComponents: .date
                                )
                                .tint(CozyTheme.roseAccent)
                                .font(.subheadline)
                                .foregroundStyle(CozyTheme.inkPrimary)
                            }
                        } else if !addFriendlyMode {
                            Text("Daily tasks appear gently on each day's checklist (and step back if your daily cup is empty).")
                                .font(.caption)
                                .foregroundStyle(CozyTheme.inkSecondary)
                        }

                        Divider()
                            .overlay(CozyTheme.cardBorder)

                        // Hard Deadline Section
                        Toggle(isOn: $hasHardDeadline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Hard Deadline", systemImage: "exclamationmark.triangle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(CozyTheme.inkPrimary)
                                if !addFriendlyMode {
                                    Text("Forces this task to appear before or on the deadline—even when your daily cup doesn't have enough hours.")
                                        .font(.caption)
                                        .foregroundStyle(CozyTheme.inkSecondary)
                                }
                            }
                        }
                        .tint(CozyTheme.roseAccent)

                        if hasHardDeadline {
                            DatePicker(
                                "Due Date",
                                selection: $hardDeadlineDate,
                                displayedComponents: .date
                            )
                            .tint(CozyTheme.roseAccent)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(CozyTheme.deepRose)
                        }
                    }
                    .padding(18)
                    .cozyCard()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .cozyScreenBackground()
            .navigationTitle(existingTemplate == nil ? "New Task" : "Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(CozyTheme.inkSecondary)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveTask()
                    }
                    .fontWeight(.bold)
                    .foregroundStyle(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CozyTheme.inkMuted : CozyTheme.deepRose)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var autoScheduleExplanation: String {
        switch recurrence {
        case .once:
            return "Places this task on whichever upcoming day in your window has the most free time."
        case .weekly:
            return "Picks the day each week with the most open free time."
        case .biweekly:
            return "Picks the freest day in each 2-week cycle."
        case .monthly:
            return "Finds your calmest day each month so busy weeks stay light."
        case .customDays:
            return "Picks the freest day inside each \(customIntervalDays)-day cycle."
        case .daily:
            return ""
        }
    }

    private func saveTask() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDeadline = hasHardDeadline ? DateHelpers.startOfDay(for: hardDeadlineDate) : nil

        if let task = existingTemplate {
            task.title = trimmedTitle
            task.notes = trimmedNotes
            task.emoji = emoji
            task.category = category
            task.recurrence = recurrence
            task.durationMinutes = durationMinutes
            task.weight = weight
            task.setHardDeadline(normalizedDeadline, hasDeadline: hasHardDeadline)
            task.customIntervalDays = customIntervalDays
            task.isAutoScheduled = recurrence == .daily ? false : isAutoScheduled
            task.setAnchorDate(anchorDate)
            task.flexibleWindowDays = flexibleWindowDays

            // Refresh snapshots ONLY on pending occurrences so completed/skipped history stays frozen
            for occ in task.occurrences where occ.status == .pending {
                occ.hasCustomWeightOverride = false
                let occDay = occ.scheduledDay()
                let win = DateHelpers.periodWindow(for: task, containing: occDay)
                let scopedDeadline = SmartScheduler.effectivePeriodDeadline(
                    for: task,
                    window: win,
                    calendar: DateHelpers.calendar
                )
                occ.refreshPendingSnapshotsFromTemplate(periodDeadline: scopedDeadline)
            }
        } else {
            let created = TaskTemplate(
                title: trimmedTitle,
                notes: trimmedNotes,
                emoji: emoji,
                category: category,
                recurrence: recurrence,
                durationMinutes: durationMinutes,
                weight: weight,
                hasHardDeadline: hasHardDeadline,
                hardDeadlineDate: normalizedDeadline,
                customIntervalDays: customIntervalDays,
                isAutoScheduled: recurrence == .daily ? false : isAutoScheduled,
                anchorDate: anchorDate,
                flexibleWindowDays: flexibleWindowDays,
                calendar: DateHelpers.calendar
            )
            modelContext.insert(created)
        }

        try? modelContext.save()
        onSaved()
        dismiss()
    }
}
