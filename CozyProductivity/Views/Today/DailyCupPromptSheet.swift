import SwiftData
import SwiftUI

struct DailyCupPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let preferences: CozyPreferences
    let logicalToday: Date
    var onSaved: () -> Void

    @State private var selectedHours: Int

    private struct CupOption: Identifiable {
        let hours: Int
        let emoji: String
        let title: String
        let subtitle: String
        var id: Int { hours }
    }

    private let options: [CupOption] = [
        CupOption(
            hours: 0,
            emoji: "🫖",
            title: "0 · Empty Cup (0 hrs)",
            subtitle: "Rest today — tasks move back a day (hard deadlines still appear)"
        ),
        CupOption(
            hours: 1,
            emoji: "🍵",
            title: "1 · A Gentle Sip (1 hr)",
            subtitle: "Room for light essentials only"
        ),
        CupOption(
            hours: 2,
            emoji: "☕",
            title: "2 · Soft Pace (2 hrs)",
            subtitle: "Calm, unhurried cozy checklist"
        ),
        CupOption(
            hours: 3,
            emoji: "🌸",
            title: "3 · Steady Cup (3 hrs)",
            subtitle: "Balanced space for normal & light tasks"
        ),
        CupOption(
            hours: 4,
            emoji: "🌷",
            title: "4 · Warm & Full (4 hrs)",
            subtitle: "Comfortable room for heavier tasks too"
        ),
        CupOption(
            hours: 5,
            emoji: "✨",
            title: "5 · Brimming Cup (5 hrs)",
            subtitle: "High-energy day with 5 full hours available"
        )
    ]

    init(
        preferences: CozyPreferences,
        logicalToday: Date = DateHelpers.logicalToday(),
        onSaved: @escaping () -> Void
    ) {
        self.preferences = preferences
        self.logicalToday = logicalToday
        self.onSaved = onSaved
        _selectedHours = State(initialValue: max(0, min(5, preferences.todayCupHours)))
    }

    private var isADDFriendly: Bool {
        preferences.addFriendlyMode
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if isADDFriendly {
                    addFriendlyBody
                } else {
                    cozyBody
                }
            }
            .cozyScreenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(preferences.hasCupCheckIn(for: logicalToday) ? "Close" : "Skip") {
                        dismiss()
                    }
                    .foregroundStyle(CozyTheme.inkSecondary)
                }
            }
        }
    }

    // MARK: - ADD Friendly Mode (Hours Only, Minimal Text)

    private var addFriendlyBody: some View {
        VStack(spacing: 16) {
            Text("How full is your cup today?")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(CozyTheme.inkPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            VStack(spacing: 8) {
                ForEach(0...5, id: \.self) { hours in
                    let isSelected = selectedHours == hours
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            selectedHours = hours
                        }
                    } label: {
                        HStack {
                            Text("\(hours) \(hours == 1 ? "hour" : "hours")")
                                .font(.system(.body, design: .rounded, weight: .bold))
                                .foregroundStyle(CozyTheme.inkPrimary)
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? CozyTheme.deepRose : CozyTheme.inkMuted.opacity(0.6))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(isSelected ? Color.white : Color.white.opacity(0.75))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(
                                    isSelected ? CozyTheme.roseAccent : CozyTheme.cardBorder,
                                    lineWidth: isSelected ? 1.8 : 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                saveCupCheckIn()
            } label: {
                Text("Save")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(CozyTheme.primaryButtonGradient)
                    )
            }
            .buttonStyle(.plain)

            if preferences.dailyCupPromptEnabled {
                Button {
                    disableDailyCupPrompt()
                } label: {
                    Text("Don't ask daily")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CozyTheme.inkSecondary)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Standard Cozy Mode

    private var cozyBody: some View {
        VStack(spacing: 18) {
            // Cozy Hero Header
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(CozyTheme.headerCardGradient)
                        .frame(width: 72, height: 72)
                        .overlay(
                            Circle().strokeBorder(CozyTheme.cardBorder, lineWidth: 1.2)
                        )

                    Text(selectedHours == 0 ? "🫖" : "🍵")
                        .font(.system(size: 36))
                }
                .padding(.top, 6)

                Text("How full is your cup today?")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(CozyTheme.inkPrimary)
                    .multilineTextAlignment(.center)

                Text("Choose 0 to 5 to set today's available hours · Resets daily at 4:00 AM")
                    .font(.caption)
                    .foregroundStyle(CozyTheme.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12)

            // Quick 0..5 Number Strip
            HStack(spacing: 8) {
                ForEach(0...5, id: \.self) { level in
                    let isSelected = selectedHours == level
                    Button {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.80)) {
                            selectedHours = level
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Text("\(level)")
                                .font(.system(.headline, design: .rounded, weight: .black))
                            Text(level == 1 ? "hr" : "hrs")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(isSelected ? .white : CozyTheme.inkPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(
                                    isSelected
                                        ? AnyShapeStyle(CozyTheme.primaryButtonGradient)
                                        : AnyShapeStyle(CozyTheme.softBlushFill)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Detailed 0..5 Cards
            VStack(spacing: 10) {
                ForEach(options) { option in
                    let isSelected = selectedHours == option.hours
                    Button {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                            selectedHours = option.hours
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(option.emoji)
                                .font(.title3)
                                .frame(width: 40, height: 40)
                                .background(
                                    Circle().fill(isSelected ? CozyTheme.petalPill : CozyTheme.canvasMiddle)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(CozyTheme.inkPrimary)
                                Text(option.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(CozyTheme.inkSecondary)
                                    .multilineTextAlignment(.leading)
                            }

                            Spacer(minLength: 0)

                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? CozyTheme.deepRose : CozyTheme.inkMuted.opacity(0.6))
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(isSelected ? Color.white : Color.white.opacity(0.75))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(
                                    isSelected ? CozyTheme.roseAccent : CozyTheme.cardBorder,
                                    lineWidth: isSelected ? 1.8 : 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("The calendar continues showing future days as predicted. Tasks with a Hard Deadline due today will always appear even if your cup is low.")
                .font(.caption2)
                .foregroundStyle(CozyTheme.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            Button {
                saveCupCheckIn()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text(
                        selectedHours == 0
                            ? "Rest Today · Move Tasks Back (0h)"
                            : "Start Today with \(selectedHours) \(selectedHours == 1 ? "Hour" : "Hours")"
                    )
                    .fontWeight(.bold)
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(CozyTheme.primaryButtonGradient)
                        .shadow(color: CozyTheme.roseAccent.opacity(0.32), radius: 10, y: 5)
                )
            }
            .buttonStyle(.plain)

            if preferences.dailyCupPromptEnabled {
                Button {
                    disableDailyCupPrompt()
                } label: {
                    Text("Disable “How full is your cup?” daily dialogue")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CozyTheme.inkSecondary)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func saveCupCheckIn() {
        preferences.recordCupCheckIn(hours: selectedHours, for: logicalToday)
        try? modelContext.save()
        onSaved()
        dismiss()
    }

    private func disableDailyCupPrompt() {
        preferences.setDailyCupPromptEnabled(false)
        try? modelContext.save()
        onSaved()
        dismiss()
    }
}
