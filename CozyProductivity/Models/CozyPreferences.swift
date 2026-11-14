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

    // MARK: - Streaks & Calendar Highlight Style
    var longestRecordedStreak: Int = 0
    var baseHighlightStyleRaw: String = BaseHighlightColorStyle.roseBronze.rawValue

    // MARK: - Two-Way Google & Apple Calendar Sync
    var useGoogleCalendarSync: Bool = false
    var pushTasksToGoogleCalendar: Bool = false
    var pushTasksToAppleCalendar: Bool = false
    var appleTargetCalendarIdentifier: String = ""
    var autoSyncCalendarChanges: Bool = true
    var googleSyncModeRaw: String = GoogleCalendarSyncMode.oauthREST.rawValue
    var googleClientID: String = ""
    var googleCalendarID: String = "primary"
    var googleTaskPushStartHour: Int = 18

    // MARK: - Daily Cup Check-In (0...5 Hours, Resetting at 4:00 AM)
    var dailyCupPromptEnabled: Bool = true
    var lastCupCheckInDayKey: String = ""
    var todayCupHours: Int = 3

    // MARK: - Optional Gamification & ADD Friendly Mode
    var streaksEnabled: Bool = true
    var optionalBonusTasksEnabled: Bool = true
    var dayRanksEnabled: Bool = true
    var confettiEnabled: Bool = true
    var addFriendlyMode: Bool = false

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
        hasSeededStarterTasks: Bool = false,
        longestRecordedStreak: Int = 0,
        baseHighlightStyle: BaseHighlightColorStyle = .roseBronze,
        useGoogleCalendarSync: Bool = false,
        pushTasksToGoogleCalendar: Bool = false,
        pushTasksToAppleCalendar: Bool = false,
        appleTargetCalendarIdentifier: String = "",
        autoSyncCalendarChanges: Bool = true,
        googleSyncMode: GoogleCalendarSyncMode = .oauthREST,
        googleClientID: String = "",
        googleCalendarID: String = "primary",
        googleTaskPushStartHour: Int = 18,
        dailyCupPromptEnabled: Bool = true,
        lastCupCheckInDayKey: String = "",
        todayCupHours: Int = 3,
        streaksEnabled: Bool = true,
        optionalBonusTasksEnabled: Bool = true,
        dayRanksEnabled: Bool = true,
        confettiEnabled: Bool = true,
        addFriendlyMode: Bool = false
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
        self.longestRecordedStreak = longestRecordedStreak
        self.baseHighlightStyleRaw = baseHighlightStyle.rawValue
        self.useGoogleCalendarSync = useGoogleCalendarSync
        self.pushTasksToGoogleCalendar = pushTasksToGoogleCalendar
        self.pushTasksToAppleCalendar = pushTasksToAppleCalendar
        self.appleTargetCalendarIdentifier = appleTargetCalendarIdentifier
        self.autoSyncCalendarChanges = autoSyncCalendarChanges
        self.googleSyncModeRaw = googleSyncMode.rawValue
        self.googleClientID = googleClientID
        self.googleCalendarID = googleCalendarID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "primary" : googleCalendarID
        self.googleTaskPushStartHour = max(6, min(22, googleTaskPushStartHour))
        self.dailyCupPromptEnabled = dailyCupPromptEnabled
        self.lastCupCheckInDayKey = lastCupCheckInDayKey
        self.todayCupHours = max(0, min(5, todayCupHours))
        self.streaksEnabled = streaksEnabled
        self.optionalBonusTasksEnabled = optionalBonusTasksEnabled
        self.dayRanksEnabled = dayRanksEnabled
        self.confettiEnabled = confettiEnabled
        self.addFriendlyMode = addFriendlyMode
    }

    var calendarDeductionMode: CalendarDeductionMode {
        get { CalendarDeductionMode(rawValue: calendarDeductionModeRaw) ?? .subtractFromBudget }
        set { calendarDeductionModeRaw = newValue.rawValue }
    }

    var baseHighlightStyle: BaseHighlightColorStyle {
        get { BaseHighlightColorStyle(rawValue: baseHighlightStyleRaw) ?? .roseBronze }
        set { baseHighlightStyleRaw = newValue.rawValue }
    }

    var googleSyncMode: GoogleCalendarSyncMode {
        get { GoogleCalendarSyncMode(rawValue: googleSyncModeRaw) ?? .oauthREST }
        set { googleSyncModeRaw = newValue.rawValue }
    }

    /// True whenever Apple Calendar busy sync or Google Calendar busy sync is active.
    var hasAnyCalendarBusySyncEnabled: Bool {
        useCalendarSync || useGoogleCalendarSync
    }

    /// True whenever Cozy is configured to push/sync scheduled tasks onto Google and/or Apple Calendar.
    var hasAnyCalendarPushEnabled: Bool {
        pushTasksToGoogleCalendar || pushTasksToAppleCalendar
    }

    /// True whenever any Google or Apple Calendar read or push integration is enabled.
    var hasAnyCalendarIntegrationEnabled: Bool {
        useCalendarSync || pushTasksToAppleCalendar || useGoogleCalendarSync || pushTasksToGoogleCalendar
    }

    /// True when task/schedule changes should automatically sync to enabled Google and/or Apple Calendars.
    var shouldAutoSyncCalendarsOnChange: Bool {
        autoSyncCalendarChanges && hasAnyCalendarIntegrationEnabled
    }

    func setDailyCupPromptEnabled(_ enabled: Bool) {
        dailyCupPromptEnabled = enabled
        if !enabled {
            lastCupCheckInDayKey = ""
        }
    }

    func hasCupCheckIn(for day: Date, calendar: Calendar = DateHelpers.calendar) -> Bool {
        lastCupCheckInDayKey == DateHelpers.dayKeyString(for: day, calendar: calendar)
    }

    func needsCupCheckIn(for day: Date, calendar: Calendar = DateHelpers.calendar) -> Bool {
        guard dailyCupPromptEnabled else { return false }
        return !hasCupCheckIn(for: day, calendar: calendar)
    }

    func cupHours(for day: Date, calendar: Calendar = DateHelpers.calendar) -> Int? {
        guard hasCupCheckIn(for: day, calendar: calendar) else { return nil }
        return max(0, min(5, todayCupHours))
    }

    func recordCupCheckIn(hours: Int, for day: Date, calendar: Calendar = DateHelpers.calendar) {
        todayCupHours = max(0, min(5, hours))
        lastCupCheckInDayKey = DateHelpers.dayKeyString(for: day, calendar: calendar)
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
