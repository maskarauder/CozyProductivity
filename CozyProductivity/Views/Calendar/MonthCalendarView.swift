import SwiftData
import SwiftUI

struct MonthCalendarView: View {
    @Environment(\.modelContext) private var modelContext

    let occurrences: [TaskOccurrence]
    let preferences: CozyPreferences

    @State private var displayedMonthStart: Date = {
        let cal = DateHelpers.calendar
        let logical = DateHelpers.logicalToday(calendar: cal)
        let comps = cal.dateComponents([.year, .month], from: logical)
        return cal.date(from: comps) ?? logical
    }()

    @State private var selectedDate: Date = DateHelpers.logicalToday()
    @State private var showingMonthYearPicker = false
    @State private var pickerYear: Int = DateHelpers.calendar.component(.year, from: DateHelpers.logicalToday())

    private var today: Date {
        DateHelpers.logicalToday()
    }

    private var calendar: Calendar {
        DateHelpers.calendar
    }

    private var streakSnapshot: StreakSnapshot {
        StreakAndBonusService.evaluate(
            occurrences: occurrences,
            persistedLongestStreak: preferences.longestRecordedStreak,
            optionalBonusTasksEnabled: preferences.optionalBonusTasksEnabled,
            today: today,
            calendar: calendar
        )
    }

    private var baseStyle: BaseHighlightColorStyle {
        preferences.baseHighlightStyle
    }

    private var isADDFriendly: Bool {
        preferences.addFriendlyMode
    }

    private var isDisplayingCurrentMonth: Bool {
        let c1 = calendar.dateComponents([.year, .month], from: displayedMonthStart)
        let c2 = calendar.dateComponents([.year, .month], from: today)
        return c1.year == c2.year && c1.month == c2.month
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: isADDFriendly ? 14 : 18) {
                    headerSection

                    if preferences.streaksEnabled {
                        streakStatsCard
                    }

                    monthCalendarCard

                    selectedDayInspectorCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 34)
            }
            .cozyScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingMonthYearPicker) {
                monthYearPickerSheet
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(isADDFriendly ? "Calendar" : "Cozy Calendar")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(CozyTheme.inkPrimary)
                if !isADDFriendly {
                    Text(
                        preferences.streaksEnabled
                            ? "Browse months & years to celebrate your streak history"
                            : "Browse past & predicted task schedules across months"
                    )
                    .font(.footnote)
                    .foregroundStyle(CozyTheme.inkSecondary)
                }
            }
            Spacer()
            if !isDisplayingCurrentMonth {
                Button {
                    jumpToToday()
                } label: {
                    Text("Today")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(CozyTheme.deepRose)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(CozyTheme.petalPill))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Current Streak & Longest Recorded Streak Card

    private var streakStatsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                streakMetricBox(
                    icon: "flame.fill",
                    iconColor: CozyTheme.goldBorder,
                    value: "\(streakSnapshot.currentStreak)",
                    unit: streakSnapshot.currentStreak == 1 ? "day" : "days",
                    title: isADDFriendly ? "Current" : "Current Streak"
                )

                streakMetricBox(
                    icon: "crown.fill",
                    iconColor: CozyTheme.deepRose,
                    value: "\(streakSnapshot.longestStreak)",
                    unit: streakSnapshot.longestStreak == 1 ? "day" : "days",
                    title: isADDFriendly ? "Best" : "Longest Streak"
                )
            }

            if !isADDFriendly && preferences.dayRanksEnabled {
                HStack(spacing: 10) {
                    if preferences.optionalBonusTasksEnabled {
                        Text("🥈 Silver preserves streak")
                        Text("·")
                    }
                    Text("🥇 Gold +1 streak")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(CozyTheme.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(CozyTheme.headerCardGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(CozyTheme.cardBorder, lineWidth: 1)
        )
    }

    private func streakMetricBox(
        icon: String,
        iconColor: Color,
        value: String,
        unit: String,
        title: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 38, height: 38)
                .background(
                    Circle().fill(CozyTheme.softBlushFill)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(.title2, design: .rounded, weight: .black))
                        .foregroundStyle(CozyTheme.inkPrimary)
                    Text(unit)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CozyTheme.inkSecondary)
                }
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CozyTheme.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.88))
        )
    }

    // MARK: - Month Grid Card

    private var monthCalendarCard: some View {
        let gridCells = buildMonthGridCells()
        let monthStats = monthlyMedalCounts(for: gridCells.compactMap { $0 })
        let showRanks = preferences.dayRanksEnabled

        return VStack(alignment: .leading, spacing: 14) {
            // Month / Year Navigation Bar
            HStack {
                Button {
                    shiftMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(CozyTheme.deepRose)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(CozyTheme.softBlushFill))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous month")

                Spacer()

                Button {
                    pickerYear = calendar.component(.year, from: displayedMonthStart)
                    showingMonthYearPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Text(monthYearTitle(for: displayedMonthStart))
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(CozyTheme.inkPrimary)
                        Image(systemName: "chevron.down.circle.fill")
                            .font(.caption)
                            .foregroundStyle(CozyTheme.roseAccent)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(CozyTheme.canvasMiddle))
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    shiftMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(CozyTheme.deepRose)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(CozyTheme.softBlushFill))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next month")
            }

            // Weekday Column Headers
            let headers = orderedWeekdaySymbols()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 8) {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(CozyTheme.inkMuted)
                        .frame(maxWidth: .infinity)
                }

                // Day Cells
                ForEach(Array(gridCells.enumerated()), id: \.offset) { _, maybeDate in
                    if let cellDate = maybeDate {
                        dayCell(for: cellDate)
                    } else {
                        Color.clear
                            .frame(height: 44)
                    }
                }
            }

            if showRanks {
                Divider().overlay(CozyTheme.cardBorder)

                // Tier Legend + Base Highlight Color Switcher (Bronze vs Pink)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        if preferences.optionalBonusTasksEnabled {
                            legendBadge(
                                gradient: baseStyle.gradient,
                                border: baseStyle.borderColor,
                                label: isADDFriendly ? "\(monthStats.base)" : "All Done (\(monthStats.base))"
                            )
                            legendBadge(
                                gradient: CozyTheme.silverGradient,
                                border: CozyTheme.silverBorder,
                                label: "Silver (\(monthStats.silver))"
                            )
                        }
                        legendBadge(
                            gradient: CozyTheme.goldGradient,
                            border: CozyTheme.goldBorder,
                            label: "Gold (\(monthStats.gold))"
                        )
                    }

                    if preferences.optionalBonusTasksEnabled && !isADDFriendly {
                        HStack {
                            Text("Base complete color:")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(CozyTheme.inkSecondary)

                            Spacer()

                            ForEach(BaseHighlightColorStyle.allCases) { style in
                                let active = preferences.baseHighlightStyle == style
                                Button {
                                    preferences.baseHighlightStyle = style
                                    try? modelContext.save()
                                } label: {
                                    Text(style.title)
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(active ? style.inkColor : CozyTheme.inkSecondary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            Capsule().fill(
                                                active
                                                    ? AnyShapeStyle(style.gradient)
                                                    : AnyShapeStyle(CozyTheme.canvasMiddle)
                                            )
                                        )
                                        .overlay(
                                            Capsule().strokeBorder(
                                                active ? style.borderColor : CozyTheme.cardBorder.opacity(0.6),
                                                lineWidth: 1
                                            )
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .cozyCard()
    }

    private func dayCell(for date: Date) -> some View {
        let dayNumber = calendar.component(.day, from: date)
        let summary = streakSnapshot.summary(for: date)
        let tier = summary.tier
        let showRanks = preferences.dayRanksEnabled
        let isToday = DateHelpers.isSameDay(date, today, calendar: calendar)
        let isFuture = date > today
        let isSelected = DateHelpers.isSameDay(date, selectedDate, calendar: calendar)
        let isCompletedDay = !isFuture && summary.allBaseCompleted
        let hasPartialProgress = !isCompletedDay && !isFuture && summary.baseCompletedCount > 0
        let hasPredictedFutureTasks = isFuture && summary.baseTotalCount > 0

        let cellTextColor: Color = {
            if showRanks {
                return tier.inkColor(baseStyle: baseStyle)
            }
            return isCompletedDay ? CozyTheme.deepRose : CozyTheme.inkPrimary
        }()

        let cellFill: AnyShapeStyle = {
            if showRanks, let grad = tier.fillGradient(baseStyle: baseStyle) {
                return AnyShapeStyle(grad)
            }
            if isCompletedDay {
                return AnyShapeStyle(CozyTheme.pinkHighlightGradient)
            }
            return AnyShapeStyle(isToday ? CozyTheme.softBlushFill.opacity(0.75) : Color.white.opacity(0.55))
        }()

        let cellBorder: Color = {
            if isSelected { return CozyTheme.deepRose }
            if showRanks && tier != .none { return tier.borderColor(baseStyle: baseStyle) }
            if isCompletedDay { return CozyTheme.pinkHighlightBorder }
            if isToday { return CozyTheme.roseAccent }
            return Color.clear
        }()

        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                selectedDate = date
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 2) {
                    Text("\(dayNumber)")
                        .font(.system(.subheadline, design: .rounded, weight: isCompletedDay || isToday ? .bold : .medium))
                        .foregroundStyle(cellTextColor)

                    if showRanks && tier == .gold {
                        Image(systemName: "sparkles")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(CozyTheme.goldInk)
                    } else if showRanks && tier == .silver {
                        Circle()
                            .fill(CozyTheme.silverInk.opacity(0.75))
                            .frame(width: 5, height: 5)
                    } else if showRanks && tier == .base {
                        Circle()
                            .fill(baseStyle.inkColor.opacity(0.75))
                            .frame(width: 5, height: 5)
                    } else if isCompletedDay {
                        Circle()
                            .fill(CozyTheme.deepRose.opacity(0.8))
                            .frame(width: 5, height: 5)
                    } else if hasPartialProgress {
                        Circle()
                            .fill(CozyTheme.roseAccent.opacity(0.55))
                            .frame(width: 4, height: 4)
                    } else if hasPredictedFutureTasks {
                        Circle()
                            .fill(CozyTheme.deepRose.opacity(0.35))
                            .frame(width: 4, height: 4)
                    } else {
                        Color.clear.frame(width: 4, height: 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(cellFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(
                            cellBorder,
                            lineWidth: isSelected ? 2.2 : 1.2
                        )
                )
                .shadow(
                    color: (showRanks && tier == .gold) ? CozyTheme.goldBorder.opacity(0.28) : Color.clear,
                    radius: 5,
                    x: 0,
                    y: 2
                )
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Selected Day Inspector

    private var selectedDayInspectorCard: some View {
        let summary = streakSnapshot.summary(for: selectedDate)
        let tier = summary.tier
        let showRanks = preferences.dayRanksEnabled
        let isFuture = selectedDate > today
        let isSelectedToday = DateHelpers.isSameDay(selectedDate, today, calendar: calendar)

        let baseItems = occurrences
            .filter {
                $0.status != .skipped
                    && $0.bonusForDate == nil
                    && DateHelpers.isSameDay($0.scheduledDate, selectedDate, calendar: calendar)
            }
            .sorted { $0.displayTitle < $1.displayTitle }

        let bonusItems = preferences.optionalBonusTasksEnabled
            ? occurrences
                .filter {
                    $0.status != .skipped
                        && ($0.bonusForDate.map { DateHelpers.isSameDay($0, selectedDate, calendar: calendar) } ?? false)
                        && ($0.isCompleted || isSelectedToday)
                }
                .sorted { $0.bonusSlot < $1.bonusSlot }
            : []

        let dateFormatter: DateFormatter = {
            let fmt = DateFormatter()
            fmt.dateFormat = isADDFriendly ? "MMM d, yyyy" : "EEEE, MMM d, yyyy"
            return fmt
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dateFormatter.string(from: selectedDate))
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(CozyTheme.inkPrimary)

                    if isFuture && summary.baseTotalCount > 0 {
                        Text(
                            isADDFriendly
                                ? "\(summary.baseTotalCount) upcoming"
                                : "Predicted schedule · \(summary.baseTotalCount) upcoming task\(summary.baseTotalCount == 1 ? "" : "s")"
                        )
                        .font(.caption)
                        .foregroundStyle(CozyTheme.inkSecondary)
                    } else if summary.baseTotalCount > 0 {
                        let bonusClause = (!isADDFriendly && preferences.optionalBonusTasksEnabled)
                            ? " · \(summary.bonusCompletedCount)/2 bonus tasks"
                            : ""
                        Text(
                            isADDFriendly
                                ? "\(summary.baseCompletedCount)/\(summary.baseTotalCount) done"
                                : "\(summary.baseCompletedCount)/\(summary.baseTotalCount) daily tasks\(bonusClause)"
                        )
                        .font(.caption)
                        .foregroundStyle(CozyTheme.inkSecondary)
                    } else if isSelectedToday && preferences.cupHours(for: today, calendar: calendar) == 0 {
                        Text(isADDFriendly ? "0 hours today" : "Empty cup rest day (0h) · Tasks moved back a day")
                            .font(.caption)
                            .foregroundStyle(CozyTheme.inkSecondary)
                    } else if !isADDFriendly {
                        Text(isFuture ? "Open predicted day · No tasks scheduled yet" : "No tasks recorded on this date")
                            .font(.caption)
                            .foregroundStyle(CozyTheme.inkSecondary)
                    }
                }

                Spacer()

                if showRanks && tier != .none {
                    HStack(spacing: 4) {
                        Text(tier.medalEmoji)
                        if !isADDFriendly {
                            Text(tier.badgeTitle(baseStyle: baseStyle))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(tier.inkColor(baseStyle: baseStyle))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(tier.fillGradient(baseStyle: baseStyle) ?? CozyTheme.headerCardGradient)
                    )
                    .overlay(
                        Capsule().strokeBorder(tier.borderColor(baseStyle: baseStyle), lineWidth: 1)
                    )
                } else if !showRanks && !isFuture && summary.allBaseCompleted {
                    Text("Done")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(CozyTheme.deepRose)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(CozyTheme.petalPill))
                }
            }

            if !baseItems.isEmpty {
                ForEach(baseItems) { item in
                    dayTaskRow(item: item, isBonus: false)
                }
            }

            if !bonusItems.isEmpty {
                Text(isADDFriendly ? "Bonus" : "Optional Bonus Tasks")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(CozyTheme.deepRose)
                    .padding(.top, 4)

                ForEach(bonusItems) { item in
                    dayTaskRow(item: item, isBonus: true)
                }
            }
        }
        .padding(18)
        .cozyCard()
    }

    private func dayTaskRow(item: TaskOccurrence, isBonus: Bool) -> some View {
        let weight = item.displayWeight
        let deadline = item.effectiveHardDeadline(calendar: calendar)

        return HStack(spacing: 8) {
            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.isCompleted ? CozyTheme.roseAccent : CozyTheme.inkMuted)
            if !isADDFriendly {
                Text(item.displayEmoji)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(item.isCompleted ? CozyTheme.inkPrimary : CozyTheme.inkSecondary)
                if let deadline {
                    Text(
                        isADDFriendly
                            ? "Due \(DateHelpers.shortMonthDayString(for: deadline, calendar: calendar))"
                            : "📌 Hard deadline \(DateHelpers.shortMonthDayString(for: deadline, calendar: calendar))"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CozyTheme.deepRose)
                }
            }
            Spacer()
            if isBonus {
                Text("Bonus")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(preferences.dayRanksEnabled ? CozyTheme.goldInk : CozyTheme.deepRose)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(
                            preferences.dayRanksEnabled
                                ? AnyShapeStyle(CozyTheme.goldGradient)
                                : AnyShapeStyle(CozyTheme.petalPill)
                        )
                    )
            }
            if !isADDFriendly || weight != .light {
                Text(isADDFriendly ? weight.title : "\(weight.emoji) \(weight.title)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(weight.pillForeground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(weight.pillBackground))
            }
            Text(DateHelpers.formatDuration(minutes: item.displayDurationMinutes))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(CozyTheme.inkMuted)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(CozyTheme.canvasMiddle)
        )
    }

    // MARK: - Month & Year Jump Picker Sheet

    private var monthYearPickerSheet: some View {
        let monthSymbols = calendar.shortMonthSymbols
        let activeMonth = calendar.component(.month, from: displayedMonthStart)
        let activeYear = calendar.component(.year, from: displayedMonthStart)

        return NavigationStack {
            VStack(spacing: 22) {
                // Year Selector
                HStack(spacing: 24) {
                    Button {
                        pickerYear -= 1
                    } label: {
                        Image(systemName: "chevron.left.circle.fill")
                            .font(.title2)
                            .foregroundStyle(CozyTheme.roseAccent)
                    }
                    .buttonStyle(.plain)

                    Text(String(pickerYear))
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(CozyTheme.inkPrimary)
                        .frame(minWidth: 96)

                    Button {
                        pickerYear += 1
                    } label: {
                        Image(systemName: "chevron.right.circle.fill")
                            .font(.title2)
                            .foregroundStyle(CozyTheme.roseAccent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 12)

                // 12-Month Grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(1...12, id: \.self) { monthIndex in
                        let isSelected = pickerYear == activeYear && monthIndex == activeMonth
                        Button {
                            var comps = DateComponents()
                            comps.year = pickerYear
                            comps.month = monthIndex
                            comps.day = 1
                            if let target = calendar.date(from: comps) {
                                displayedMonthStart = DateHelpers.startOfDay(for: target, calendar: calendar)
                                selectedDate = displayedMonthStart
                            }
                            showingMonthYearPicker = false
                        } label: {
                            Text(monthSymbols[monthIndex - 1])
                                .font(.system(.subheadline, design: .rounded, weight: .bold))
                                .foregroundStyle(isSelected ? .white : CozyTheme.inkPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
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
                .padding(.horizontal, 18)

                Spacer()
            }
            .padding(.top, 10)
            .cozyScreenBackground()
            .navigationTitle("Jump to Month & Year")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        showingMonthYearPicker = false
                    }
                    .foregroundStyle(CozyTheme.deepRose)
                }
            }
        }
        .presentationDetents([.height(360)])
    }

    // MARK: - Helpers

    private func legendBadge(gradient: LinearGradient, border: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(gradient)
                .frame(width: 13, height: 13)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(border, lineWidth: 1)
                )
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(CozyTheme.inkSecondary)
        }
    }

    private func shiftMonth(by delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: displayedMonthStart) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.84)) {
            displayedMonthStart = DateHelpers.startOfDay(for: next, calendar: calendar)
            if DateHelpers.isSameDay(displayedMonthStart, monthStart(for: today), calendar: calendar) {
                selectedDate = today
            } else {
                selectedDate = displayedMonthStart
            }
        }
    }

    private func jumpToToday() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.84)) {
            displayedMonthStart = monthStart(for: today)
            selectedDate = today
        }
    }

    private func monthStart(for date: Date) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: comps).map { DateHelpers.startOfDay(for: $0, calendar: calendar) } ?? date
    }

    private func monthYearTitle(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        return fmt.string(from: date)
    }

    private func orderedWeekdaySymbols() -> [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday // 1 = Sun ... 7 = Sat
        return (0..<7).map { offset in
            symbols[(first - 1 + offset) % 7]
        }
    }

    private func buildMonthGridCells() -> [Date?] {
        let start = monthStart(for: displayedMonthStart)
        let daysInMonth = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        let firstWeekdayOfMonth = calendar.component(.weekday, from: start)
        let leadingEmptyCount = (firstWeekdayOfMonth - calendar.firstWeekday + 7) % 7

        var cells: [Date?] = Array(repeating: nil, count: leadingEmptyCount)
        for dayOffset in 0..<daysInMonth {
            cells.append(DateHelpers.addDays(dayOffset, to: start, calendar: calendar))
        }
        return cells
    }

    private func monthlyMedalCounts(for dates: [Date]) -> (base: Int, silver: Int, gold: Int) {
        var b = 0, s = 0, g = 0
        for d in dates where d <= today {
            switch streakSnapshot.tier(for: d, calendar: calendar) {
            case .none: break
            case .base: b += 1
            case .silver: s += 1
            case .gold: g += 1
            }
        }
        return (b, s, g)
    }
}
