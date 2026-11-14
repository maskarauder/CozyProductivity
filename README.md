# CozyProductivity 🌸

A calm, pastel-pink iPhone task tracking app built natively with **SwiftUI**, **SwiftData**, **AppIntents**, **EventKit**, **AuthenticationServices**, and **UserNotifications** (iOS 17+).

## Features

- **Today's Checklist Cards & Bonus Tasks**:
  - Tactile pastel cards for the current day with duration badges, recurrence tags, spring animations, and quick actions.
  - Completing all of today's tasks highlights the day in **Rose Bronze** (or **Pastel Pink**) and unlocks **2 optional bonus tasks** selectable from upcoming tasks within the next 7 days.
  - Completing **1 bonus task** upgrades the day to **Silver** (preserving your active streak without adding to it).
  - Completing **both bonus tasks** upgrades the day to **Gold**, firing a massive celebratory confetti barrage and displaying **`PERFECT`** with **`Streak Days X`** underneath (+1 streak).
- **Month & Year Calendar View + Streak Stats**:
  - Browse any month or jump back across previous months and years, inspect completed tasks per date, and track your **Current Streak** and **Longest Recorded Streak**.
- **Native Siri & Apple Shortcuts Voice Commands (`AppIntents`)**:
  - Zero external API keys required—works natively with Siri, Spotlight, and the Shortcuts app:
    - *“Hey Siri, add a task in Cozy Tasks”* (prompts for title, **Once** / **Daily** / **Weekly** / **Every 2 Weeks** / **Monthly**, and duration, then distributes onto a freer day).
    - *“Hey Siri, complete a task in Cozy Tasks”* (checks off daily or bonus tasks and announces Silver / Gold `PERFECT` streak updates).
    - *“Hey Siri, what's on my Cozy Tasks today?”*
    - *“Hey Siri, check my streak in Cozy Tasks”*
    - *“Hey Siri, sync Google Calendar in Cozy Tasks”*
- **Two-Way Google Calendar + Apple Calendar Sync**:
  - **Read & Union-Merge Busy Events**: Reads busy intervals from **Google Calendar** (via native OAuth 2.0 PKCE against Google Calendar REST API v3 *or* zero-setup iPhone Google Account Bridge) and **Apple Calendar (`EventKit`)**, union-merging overlapping meetings so overlapping events across both calendars are never double-counted.
  - **Push & Merge Scheduled Tasks**: Pushes scheduled Cozy Tasks back onto Google Calendar in non-overlapping open slots, updating events in place (`PATCH`) when `SmartScheduler` moves a task to a freer day and marking titles with `✅` when completed—while filtering Cozy's own pushed events out of external busy-time reads to prevent self-feedback loops.
- **Flexible Recurring & Once Tasks (`SmartScheduler`)**:
  - Supports **Once**, **Daily**, **Weekly**, **Every 2 Weeks**, **Monthly**, and **Custom (Every N Days)** tasks, each with a configurable duration.
  - Guilt-free end-of-day rollover: unfinished weekly, monthly, and once tasks automatically redistribute to upcoming free days without piling up missed daily habits.
- **Summary Notifications**:
  - **End-of-Day Notification**: Summarizes every task and total minutes you completed that day.
  - **Optional Weekly & Monthly Notifications**: Celebrates your broader rhythm and completed tasks across the week or month.

## Project Structure

```text
CozyProductivity/
├── App/          # @main App entry point, RootTabView two-way calendar + notification orchestration
├── Theme/        # CozyTheme pastel pink palette, Bronze/Silver/Gold medal gradients & modifiers
├── Models/       # SwiftData @Model definitions (TaskTemplate, TaskOccurrence, CozyPreferences, DayCapacityOverride)
├── Services/     # SmartScheduler, StreakAndBonusService, GoogleCalendarService, CalendarFreeTimeService, KeychainHelper, CozyModelContainer, SummaryBuilder, NotificationManager, DateHelpers
├── Intents/      # CozyShortcuts (Siri AppIntents, TodayTaskEntityQuery & CozyAppShortcutsProvider)
├── Views/        # TodayChecklistView, MonthCalendarView, ConfettiCelebrationOverlay, ScheduleOverviewView, TaskEditorSheet, ReflectionsView, CozySettingsView
└── Assets.xcassets/ # Pastel rose AccentColor & 1024x1024 AppIcon
CozyProductivityTests/
└── SmartSchedulerTests.swift # Unit tests for load balancing, Bronze/Silver/Gold streaks, Google+Apple Calendar union merge & Google API sync payloads
```

## Getting Started in Xcode

1. Open `CozyProductivity.xcodeproj` in **Xcode 15 / 16+**.
2. Select the **CozyProductivity** scheme and choose an iPhone simulator (iOS 17.0+) or your physical iPhone (set your Development Team under *Signing & Capabilities* if deploying to hardware).
3. *(Optional for Direct Google OAuth PKCE)*: Either use the built-in **iPhone Google Account Bridge** (zero configuration if Gmail is signed into *iPhone Settings → Calendar → Accounts*) or create an **iOS OAuth 2.0 Client ID** in Google Cloud Console with the Google Calendar API enabled and paste the Client ID into *Settings → Google Calendar Two-Way Sync* (adding the reversed Client ID URL scheme `com.googleusercontent.apps.<YOUR_PREFIX>` under *Target → Info → URL Types*).
4. Press **⌘R** to build and run, or **⌘U** to run the unit tests in `CozyProductivityTests`.
