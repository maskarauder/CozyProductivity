# CozyProductivity 🌸

A calm, pastel-pink iPhone task tracking app built natively with **SwiftUI**, **SwiftData**, **EventKit**, and **UserNotifications** (iOS 17+).

## Features

- **Today's Checklist Cards**: Tactile pastel cards for the current day with duration badges, recurrence tags, spring animations, and quick actions.
- **Confetti Celebration**: Checking off any task card shoots multi-shape pastel confetti (hearts, sakura petals, ribbons, and sparkles) with haptic feedback and an encouraging banner.
- **Flexible Recurring & Once Tasks**: Supports **Once**, **Daily**, **Weekly**, **Every 2 Weeks**, **Monthly**, and **Custom (Every N Days)** tasks, each with a configurable duration.
- **Smart Free-Time Distribution (`SmartScheduler`)**:
  - Configurable free-time budgets per weekday plus single-day overrides (e.g., busy travel days or restful days off).
  - Optional **Apple Calendar (`EventKit`)** busy-time sync to automatically steer tasks away from meeting-heavy days.
  - Guilt-free end-of-day rollover: unfinished weekly, monthly, and once tasks automatically redistribute to upcoming free days without piling up missed daily habits.
- **Summary Notifications**:
  - **End-of-Day Notification**: Summarizes every task and total minutes you completed that day.
  - **Optional Weekly & Monthly Notifications**: Celebrates your broader rhythm and completed tasks across the week or month.

## Project Structure

```text
CozyProductivity/
├── App/          # @main App entry point, SwiftData container, RootTabView orchestration
├── Theme/        # CozyTheme pastel pink palette, gradients, confetti colors & modifiers
├── Models/       # SwiftData @Model definitions (TaskTemplate, TaskOccurrence, CozyPreferences, DayCapacityOverride)
├── Services/     # SmartScheduler, CalendarFreeTimeService, SummaryBuilder, NotificationManager, DateHelpers
├── Views/        # TodayChecklistView, ConfettiCelebrationOverlay, ScheduleOverviewView, TaskEditorSheet, ReflectionsView, CozySettingsView
└── Assets.xcassets/ # Pastel rose AccentColor & 1024x1024 AppIcon
CozyProductivityTests/
└── SmartSchedulerTests.swift # Unit tests for load balancing, calendar busy-time deduction, rollover & digests
```

## Getting Started in Xcode

1. Open `CozyProductivity.xcodeproj` in **Xcode 15 / 16+**.
2. Select the **CozyProductivity** scheme and choose an iPhone simulator (iOS 17.0+) or your physical iPhone (set your Development Team under *Signing & Capabilities* if deploying to hardware).
3. Press **⌘R** to build and run, or **⌘U** to run the unit tests in `CozyProductivityTests`.
