import SwiftData
import SwiftUI

struct TaskEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    var existingTemplate: TaskTemplate?
    var onSaved: () -> Void

    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var emoji: String = "🌸"
    @State private var category: TaskCategory = .selfCare
    @State private var recurrence: RecurrenceKind = .weekly
    @State private var durationMinutes: Int = 30
    @State private var customIntervalDays: Int = 3
    @State private var isAutoScheduled: Bool = true
    @State private var anchorDate: Date = Date()
    @State private var flexibleWindowDays: Int = 7

    private let emojiChoices = [
        "🌸", "🌷", "🎀", "💖", "✨", "🪴",
        "🧺", "🏡", "🍵", "📖", "💌", "🕯️",
        "🧁", "🛁", "🧘‍♀️", "🎨", "🛒", "🌙"
    ]

    private let durationPresets = [10, 15, 20, 30, 45, 60, 90, 120]

    init(existingTemplate: TaskTemplate? = nil, onSaved: @escaping () -> Void) {
        self.existingTemplate = existingTemplate
        self.onSaved = onSaved
        if let task = existingTemplate {
            _title = State(initialValue: task.title)
            _notes = State(initialValue: task.notes)
            _emoji = State(initialValue: task.emoji)
            _category = State(initialValue: task.category)
            _recurrence = State(initialValue: task.recurrence)
            _durationMinutes = State(initialValue: task.durationMinutes)
            _customIntervalDays = State(initialValue: task.customIntervalDays)
            _isAutoScheduled = State(initialValue: task.isAutoScheduled)
            _anchorDate = State(initialValue: task.anchorDate)
            _flexibleWindowDays = State(initialValue: task.flexibleWindowDays)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Title & Notes Card
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Task Details")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(CozyTheme.deepRose)

                        HStack(spacing: 12) {
                            Text(emoji)
                                .font(.system(size: 30))
                                .frame(width: 50, height: 50)
                                .background(
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .fill(CozyTheme.softBlushFill)
                                )

                            TextField("e.g., Water plants & mist leaves", text: $title)
                                .font(.system(.body, design: .rounded, weight: .medium))
                                .foregroundStyle(CozyTheme.inkPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(CozyTheme.canvasMiddle)
                                )
                        }

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

                        TextField("Optional gentle note or checklist steps...", text: $notes, axis: .vertical)
                            .lineLimit(2...4)
                            .font(.subheadline)
                            .foregroundStyle(CozyTheme.inkPrimary)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(CozyTheme.canvasMiddle)
                            )

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
                    .padding(18)
                    .cozyCard()

                    // Duration Card
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("Length of Time", systemImage: "clock.fill")
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
                            "Fine-tune: \(DateHelpers.formatDuration(minutes: durationMinutes))",
                            value: $durationMinutes,
                            in: 5...360,
                            step: 5
                        )
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(CozyTheme.inkSecondary)
                    }
                    .padding(18)
                    .cozyCard()

                    // Recurrence & Smart Auto-Scheduling Card
                    VStack(alignment: .leading, spacing: 14) {
                        Label("How Often & When", systemImage: "wand.and.stars")
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
                                        Image(systemName: kind.systemImage)
                                            .font(.subheadline)
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
                                "Repeat every \(customIntervalDays) days",
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
                                    Text("Auto-distribute to freest day ✨")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(CozyTheme.inkPrimary)
                                    Text(autoScheduleExplanation)
                                        .font(.caption)
                                        .foregroundStyle(CozyTheme.inkSecondary)
                                }
                            }
                            .tint(CozyTheme.roseAccent)

                            if isAutoScheduled && recurrence == .once {
                                Picker("Schedule within", selection: $flexibleWindowDays) {
                                    Text("Next 3 days").tag(3)
                                    Text("Next 7 days").tag(7)
                                    Text("Next 14 days").tag(14)
                                    Text("Next 30 days").tag(30)
                                }
                                .pickerStyle(.menu)
                                .tint(CozyTheme.deepRose)
                                .font(.subheadline)
                                .foregroundStyle(CozyTheme.inkPrimary)
                            } else if !isAutoScheduled {
                                DatePicker(
                                    recurrence == .once ? "Scheduled Date" : "Preferred Anchor Date",
                                    selection: $anchorDate,
                                    displayedComponents: .date
                                )
                                .tint(CozyTheme.roseAccent)
                                .font(.subheadline)
                                .foregroundStyle(CozyTheme.inkPrimary)
                            }
                        } else {
                            Text("Daily tasks appear gently on every day's checklist and reserve \(DateHelpers.formatDuration(minutes: durationMinutes)) of your daily budget.")
                                .font(.caption)
                                .foregroundStyle(CozyTheme.inkSecondary)
                        }
                    }
                    .padding(18)
                    .cozyCard()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .cozyScreenBackground()
            .navigationTitle(existingTemplate == nil ? "New Cozy Task" : "Edit Task")
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

        if let task = existingTemplate {
            task.title = trimmedTitle
            task.notes = trimmedNotes
            task.emoji = emoji
            task.category = category
            task.recurrence = recurrence
            task.durationMinutes = durationMinutes
            task.customIntervalDays = customIntervalDays
            task.isAutoScheduled = recurrence == .daily ? false : isAutoScheduled
            task.anchorDate = DateHelpers.startOfDay(for: anchorDate)
            task.flexibleWindowDays = flexibleWindowDays
        } else {
            let created = TaskTemplate(
                title: trimmedTitle,
                notes: trimmedNotes,
                emoji: emoji,
                category: category,
                recurrence: recurrence,
                durationMinutes: durationMinutes,
                customIntervalDays: customIntervalDays,
                isAutoScheduled: recurrence == .daily ? false : isAutoScheduled,
                anchorDate: anchorDate,
                flexibleWindowDays: flexibleWindowDays
            )
            modelContext.insert(created)
        }

        try? modelContext.save()
        onSaved()
        dismiss()
    }
}
