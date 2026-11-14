import SwiftData
import SwiftUI

struct DayOverrideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let existingOverrides: [DayCapacityOverride]
    var addFriendlyMode: Bool = false
    var onSaved: () -> Void

    @State private var selectedDate: Date = DateHelpers.addDays(1, to: Date())
    @State private var availableMinutes: Int = 60
    @State private var note: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(addFriendlyMode ? "Free Time" : "Custom Day Free Time")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(CozyTheme.deepRose)

                        DatePicker(
                            "Date",
                            selection: $selectedDate,
                            in: DateHelpers.startOfDay(for: Date())...,
                            displayedComponents: .date
                        )
                        .tint(CozyTheme.roseAccent)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(addFriendlyMode ? "Hours" : "Available Free Time")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(DateHelpers.formatDuration(minutes: availableMinutes))
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(CozyTheme.roseAccent)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(availableMinutes) },
                                    set: { availableMinutes = Int(($0 / 15.0).rounded()) * 15 }
                                ),
                                in: 0...480,
                                step: 15
                            )
                            .tint(CozyTheme.roseAccent)
                        }

                        HStack(spacing: 8) {
                            quickPresetButton(addFriendlyMode ? "0m" : "Busy Day (0m)", minutes: 0)
                            quickPresetButton(addFriendlyMode ? "45m" : "Light (45m)", minutes: 45)
                            quickPresetButton(addFriendlyMode ? "4h" : "Free Day (4h)", minutes: 240)
                        }

                        if !addFriendlyMode || !note.isEmpty {
                            TextField("Optional note", text: $note)
                                .font(.subheadline)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(CozyTheme.canvasMiddle)
                                )
                        }
                    }
                    .padding(18)
                    .cozyCard()
                }
                .padding(18)
            }
            .cozyScreenBackground()
            .navigationTitle(addFriendlyMode ? "Day Override" : "Single-Day Override")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(CozyTheme.inkSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveOverride()
                    }
                    .fontWeight(.bold)
                    .foregroundStyle(CozyTheme.deepRose)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func quickPresetButton(_ label: String, minutes: Int) -> some View {
        Button {
            availableMinutes = minutes
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(availableMinutes == minutes ? .white : CozyTheme.inkPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(
                        availableMinutes == minutes
                            ? AnyShapeStyle(CozyTheme.primaryButtonGradient)
                            : AnyShapeStyle(CozyTheme.softBlushFill)
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private func saveOverride() {
        let normalized = DateHelpers.startOfDay(for: selectedDate)
        if let existing = existingOverrides.first(where: { DateHelpers.isSameDay($0.date, normalized) }) {
            existing.availableMinutes = availableMinutes
            existing.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let created = DayCapacityOverride(
                date: normalized,
                availableMinutes: availableMinutes,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            modelContext.insert(created)
        }
        try? modelContext.save()
        onSaved()
        dismiss()
    }
}
