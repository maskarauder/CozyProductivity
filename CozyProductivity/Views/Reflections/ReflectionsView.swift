import SwiftUI

struct ReflectionsView: View {
    let occurrences: [TaskOccurrence]
    let preferences: CozyPreferences

    enum DigestScope: String, CaseIterable {
        case daily = "Today"
        case weekly = "This Week"
        case monthly = "This Month"
    }

    @State private var selectedScope: DigestScope = .daily

    private var activeDigest: AccomplishmentDigest {
        let logical = DateHelpers.logicalToday()
        switch selectedScope {
        case .daily:
            return SummaryBuilder.dailyDigest(for: logical, occurrences: occurrences)
        case .weekly:
            return SummaryBuilder.weeklyDigest(containing: logical, occurrences: occurrences)
        case .monthly:
            return SummaryBuilder.monthlyDigest(containing: logical, occurrences: occurrences)
        }
    }

    private var isADDFriendly: Bool {
        preferences.addFriendlyMode
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: isADDFriendly ? 14 : 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isADDFriendly ? "Summaries" : "Cozy Reflections")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(CozyTheme.inkPrimary)
                        if !isADDFriendly {
                            Text("Celebrate everything you've gently checked off")
                                .font(.footnote)
                                .foregroundStyle(CozyTheme.inkSecondary)
                        }
                    }

                    // Scope Picker
                    HStack(spacing: 8) {
                        ForEach(DigestScope.allCases, id: \.self) { scope in
                            let selected = selectedScope == scope
                            Button {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                    selectedScope = scope
                                }
                            } label: {
                                Text(scope.rawValue)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(selected ? .white : CozyTheme.inkSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(
                                                selected
                                                    ? AnyShapeStyle(CozyTheme.primaryButtonGradient)
                                                    : AnyShapeStyle(Color.white.opacity(0.65))
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(5)
                    .background(Capsule().fill(CozyTheme.softBlushFill))

                    // Stats Hero Card
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(activeDigest.periodLabel)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(CozyTheme.deepRose)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.white.opacity(0.75)))
                            Spacer()
                            if !isADDFriendly {
                                Text(selectedScope == .daily ? "🌸" : (selectedScope == .weekly ? "🌷" : "✨"))
                                    .font(.title2)
                            }
                        }

                        HStack(spacing: 14) {
                            statTile(
                                value: "\(activeDigest.completedCount)",
                                label: "Completed"
                            )
                            statTile(
                                value: DateHelpers.formatDuration(minutes: activeDigest.totalCompletedMinutes),
                                label: isADDFriendly ? "Time" : "Cozy Time"
                            )
                            statTile(
                                value: "\(activeDigest.activeDaysCount)",
                                label: selectedScope == .daily ? (isADDFriendly ? "Active" : "Active Today") : "Days"
                            )
                        }
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

                    // Optional Streak & Medal Records Card
                    if preferences.streaksEnabled || preferences.dayRanksEnabled {
                        streakRecordsCard
                    }

                    // Notification Preview Card (hidden in ADD Friendly Mode)
                    if !isADDFriendly {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("Summary Notification Preview", systemImage: "bell.badge.fill")
                                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                                    .foregroundStyle(CozyTheme.deepRose)
                                Spacer()
                                Text(notificationScheduleBadge)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(CozyTheme.inkSecondary)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(activeDigest.notificationTitle)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(CozyTheme.inkPrimary)
                                Text(activeDigest.notificationBody)
                                    .font(.footnote)
                                    .foregroundStyle(CozyTheme.inkSecondary)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(CozyTheme.canvasMiddle)
                            )
                        }
                        .padding(18)
                        .cozyCard()
                    }

                    // Completed Moments List
                    VStack(alignment: .leading, spacing: 12) {
                        Text(isADDFriendly ? "Completed" : "Completed Moments")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(CozyTheme.deepRose)

                        if activeDigest.completedItems.isEmpty {
                            Text(isADDFriendly ? "None yet" : "Check off a task card on Today's Checklist to see your wins bloom here 🌱")
                                .font(.subheadline)
                                .foregroundStyle(CozyTheme.inkSecondary)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(activeDigest.completedItems) { item in
                                HStack(spacing: 12) {
                                    if !isADDFriendly {
                                        Text(item.emoji)
                                            .font(.title3)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(CozyTheme.inkPrimary)
                                        Text(DateHelpers.formatDuration(minutes: item.durationMinutes))
                                            .font(.caption)
                                            .foregroundStyle(CozyTheme.inkSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: isADDFriendly ? "checkmark" : "heart.fill")
                                        .font(.caption)
                                        .foregroundStyle(CozyTheme.roseAccent)
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .fill(CozyTheme.canvasMiddle)
                                )
                            }
                        }
                    }
                    .padding(18)
                    .cozyCard()
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 32)
            }
            .cozyScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(CozyTheme.inkPrimary)
                .minimumScaleFactor(0.75)
                .lineLimit(1)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(CozyTheme.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.82))
        )
    }

    private var notificationScheduleBadge: String {
        switch selectedScope {
        case .daily:
            return preferences.dailySummaryEnabled
                ? formattedTime(hour: preferences.dailySummaryHour, minute: preferences.dailySummaryMinute)
                : "Off"
        case .weekly:
            return preferences.weeklySummaryEnabled
                ? "\(DateHelpers.weekdayName(for: preferences.weeklySummaryWeekday))s"
                : "Optional · Off"
        case .monthly:
            return preferences.monthlySummaryEnabled
                ? "Day \(preferences.monthlySummaryDayOfMonth)"
                : "Optional · Off"
        }
    }

    private func formattedTime(hour: Int, minute: Int) -> String {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let date = DateHelpers.calendar.date(from: comps) ?? Date()
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var streakRecordsCard: some View {
        let snapshot = StreakAndBonusService.evaluate(
            occurrences: occurrences,
            persistedLongestStreak: preferences.longestRecordedStreak,
            optionalBonusTasksEnabled: preferences.optionalBonusTasksEnabled
        )

        return VStack(alignment: .leading, spacing: 12) {
            Label(
                preferences.streaksEnabled ? (isADDFriendly ? "Streaks" : "Streak & Medal Records") : "Day Ranks",
                systemImage: "flame.fill"
            )
            .font(.system(.subheadline, design: .rounded, weight: .bold))
            .foregroundStyle(CozyTheme.deepRose)

            if preferences.streaksEnabled {
                HStack(spacing: 12) {
                    statTile(
                        value: "\(snapshot.currentStreak)d",
                        label: isADDFriendly ? "Current" : "Current Streak"
                    )
                    statTile(
                        value: "\(snapshot.longestStreak)d",
                        label: isADDFriendly ? "Best" : "Longest Streak"
                    )
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(CozyTheme.softBlushFill.opacity(0.65))
                )
            }

            if preferences.dayRanksEnabled {
                HStack(spacing: 8) {
                    Text("🥇 Gold: \(snapshot.totalGoldDays)")
                    if preferences.optionalBonusTasksEnabled {
                        Text("·")
                        Text("🥈 Silver: \(snapshot.totalSilverDays)")
                        Text("·")
                        Text("🥉 Complete: \(snapshot.totalBronzeOrPinkDays)")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(CozyTheme.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(18)
        .cozyCard()
    }
}
