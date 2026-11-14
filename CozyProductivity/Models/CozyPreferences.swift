import Foundation
import SwiftData

@Model
final class CozyPreferences {
    var id: UUID

    // MARK: - Default Free-Time Budgets per Weekday (in minutes)
    var sundayBudgetMinutes: Int
    var mondayBudgetMinutes: Int
    var tuesdayBudgetMinutes: Int
    var wednesdayBudgetMinutes: Int
    var thursdayBudgetMinutes: Int
    var fridayBudgetMinutes: Int
    var saturdayBudgetMinutes: Int

    // MARK: - Optional Apple Calendar Integration
    var useCalendarSync: Bool
    var calendarDeductionModeRaw: String
    var wakingStartHour: Int
    var wakingEndHour: Int

    // MARK: - Summary Notifications
    var dailySummaryEnabled: Bool
    var dailySummaryHour: Int
    var dailySummaryMinute: Int

    var weeklySummaryEnabled: Bool
    /// 1 = Sunday ... 7 = Saturday (matches Calendar.Component.weekday)
    var weeklySummaryWeekday: Int
    var weeklySummaryHour: Int
    var weeklySummaryMinute: Int

    var monthlySummaryEnabled: Bool
    /// 1 ... 28 so it fires reliably every month including February
    var monthlySummaryDayOfMonth: Int
    var monthlySummaryHour: Int
    var monthlySummaryMinute: Int

    var hasSeededStarterTasks: Bool

    init(
        id: UUID = UUID(),
        sundayBudgetMinutes: Int = 180,
        mondayBudgetMinutes: Int = 90,
        tuesdayBudgetMinutes: Int = 90,
        wednesdayBudgetMinutes: Int = 90,
        thursdayBudgetMinutes: Int = 90,
        fridayBudgetMinutes: Int = 105,
        saturdayBudgetMinutes: Int = 180,
        useCalendarSync: Bool = false,
        calendarDeductionMode: CalendarDeductionMode = .subtractFromBudget,
        wakingStartHour: Int = 8,
        wakingEndHour: Int = 21,
        dailySummaryEnabled: Bool = true,
        dailySummaryHour: Int = 20,
        dailySummaryMinute: Int = 30,
        weeklySummaryEnabled: Bool = true,
        weeklySummaryWeekday: Int = 1, // Sunday evening
        weeklySummaryHour: Int = 20,
        weeklySummaryMinute: Int = 0,
        monthlySummaryEnabled: Bool = false,
        monthlySummaryDayOfMonth: Int = 28,
        monthlySummaryHour: Int = 20,
        monthlySummaryMinute: Int = 0,
        hasSeededStarterTasks: Bool = false
    ) {
        self.id = id
        self.sundayBudgetMinutes = sundayBudgetMinutes
        self.mondayBudgetMinutes = mondayBudgetMinutes
        self.tuesdayBudgetMinutes = tuesdayBudgetMinutes
        self.wednesdayBudgetMinutes = wednesdayBudgetMinutes
        self.thursdayBudgetMinutes = thursdayBudgetMinutes
        self.fridayBudgetMinutes = fridayBudgetMinutes
        self.saturdayBudgetMinutes = saturdayBudgetMinutes
        self.useCalendarSync = useCalendarSync
        self.calendarDeductionModeRaw = calendarDeductionMode.rawValue
        self.wakingStartHour = wakingStartHour
        self.wakingEndHour = wakingEndHour
        self.dailySummaryEnabled = dailySummaryEnabled
        self.dailySummaryHour = dailySummaryHour
        self.dailySummaryMinute = dailySummaryMinute
        self.weeklySummaryEnabled = weeklySummaryEnabled
        self.weeklySummaryWeekday = weeklySummaryWeekday
        self.weeklySummaryHour = weeklySummaryHour
        self.weeklySummaryMinute = weeklySummaryMinute
        self.monthlySummaryEnabled = monthlySummaryEnabled
        self.monthlySummaryDayOfMonth = monthlySummaryDayOfMonth
        self.monthlySummaryHour = monthlySummaryHour
        self.monthlySummaryMinute = monthlySummaryMinute
        self.hasSeededStarterTasks = hasSeededStarterTasks
    }

    var calendarDeductionMode: CalendarDeductionMode {
        get { CalendarDeductionMode(rawValue: calendarDeductionModeRaw) ?? .subtractFromBudget }
        set { calendarDeductionModeRaw = newValue.rawValue }
    }

    /// Weekday is 1 (Sunday) ... 7 (Saturday) in Gregorian Calendar.
    func baseBudgetMinutes(forWeekday weekday: Int) -> Int {
        switch weekday {
        case 1: return sundayBudgetMinutes
        case 2: return mondayBudgetMinutes
        case 3: return tuesdayBudgetMinutes
        case 4: return wednesdayBudgetMinutes
        case 5: return thursdayBudgetMinutes
        case 6: return fridayBudgetMinutes
        case 7: return saturdayBudgetMinutes
        default: return 90
        }
    }

    func setBaseBudgetMinutes(_ minutes: Int, forWeekday weekday: Int) {
        let clamped = max(0, min(720, minutes))
        switch weekday {
        case 1: sundayBudgetMinutes = clamped
        case 2: mondayBudgetMinutes = clamped
        case 3: tuesdayBudgetMinutes = clamped
        case 4: wednesdayBudgetMinutes = clamped
        case 5: thursdayBudgetMinutes = clamped
        case 6: fridayBudgetMinutes = clamped
        case 7: saturdayBudgetMinutes = clamped
        default: break
        }
    }
}

@Model
final class DayCapacityOverride {
    var id: UUID
    var date: Date
    var availableMinutes: Int
    var note: String

    init(
        id: UUID = UUID(),
        date: Date,
        availableMinutes: Int,
        note: String = ""
    ) {
        self.id = id
        self.date = DateHelpers.startOfDay(for: date)
        self.availableMinutes = max(0, min(720, availableMinutes))
        self.note = note
    }
}
