import Foundation
import SwiftData
import XCTest
@testable import CozyProductivity

@MainActor
final class MigrationFollowupTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        result.firstWeekday = 2
        return result
    }

    private func day(_ key: String, in calendar: Calendar) -> Date {
        DateHelpers.date(fromDayKey: key, calendar: calendar)!
    }

    func testActualPreviousSnapshotSchemaPreservesHistoryAndRecoversDailyDateAfterTravel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CozyPreviousSchema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("History.store")
        let utc = calendar("GMT")
        let newYork = calendar("America/New_York")
        let utcDay = day("2026-11-14", in: utc)

        // These models contain the stored fields from 8dde195, including its valid frozen
        // snapshots, but genuinely lack the newly introduced snapshotSchemaVersion column.
        let savedIDs = try writePreviousSchemaStore(at: storeURL, utcDay: utcDay)

        let schema = CozyModelContainer.schema
        let configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let preferences = CozyPreferences()
        context.insert(preferences)
        let upgradedRows = try context.fetch(FetchDescriptor<TaskOccurrence>())
        XCTAssertEqual(upgradedRows.count, 3)
        XCTAssertTrue(upgradedRows.allSatisfy { $0.snapshotSchemaVersion == 0 })

        XCTAssertTrue(CozyDataMigrator.migrateIfNeeded(
            context: context,
            preferences: preferences,
            calendar: newYork
        ))
        XCTAssertEqual(preferences.appliedDataMigrationVersion, CozyDataMigrator.currentVersion)

        for (id, expectedCategory) in zip(savedIDs.history, [TaskCategory.home, .selfCare]) {
            let occurrence = try XCTUnwrap(upgradedRows.first { $0.id == id })
            XCTAssertEqual(occurrence.displayCategory, expectedCategory)
            XCTAssertEqual(occurrence.displayNotes, "")
            XCTAssertEqual(occurrence.displayTitle, "Original title")
            XCTAssertEqual(occurrence.displayDurationMinutes, 15)
            XCTAssertEqual(occurrence.displayRecurrenceKind, .weekly)
        }

        let habit = try XCTUnwrap(upgradedRows.first { $0.id == savedIDs.habit })
        XCTAssertEqual(habit.scheduledDayKey, "2026-11-14")
        XCTAssertEqual(habit.scheduledDay(calendar: newYork), day("2026-11-14", in: newYork))
        SmartScheduler.rebalance(
            context: context,
            preferences: preferences,
            referenceDate: day("2026-11-14", in: newYork),
            horizonDays: 7,
            calendar: newYork
        )
        XCTAssertEqual(habit.status, .pending)
        let todayRows = try context.fetch(FetchDescriptor<TaskOccurrence>()).filter {
            $0.template?.id == habit.template?.id && $0.periodKey == "daily:2026-11-14"
        }
        XCTAssertEqual(todayRows.count, 1)
    }

    private func writePreviousSchemaStore(at url: URL, utcDay: Date) throws -> (history: [UUID], habit: UUID) {
        // Reopening outside this scope releases the previous model container first.
        let schema = Schema([
            PreviousSnapshotModels.TaskTemplate.self,
            PreviousSnapshotModels.TaskOccurrence.self
        ])
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        var history: [UUID] = []
        for category in ["home", "selfCare"] {
            let template = PreviousSnapshotModels.TaskTemplate(day: utcDay, category: category)
            context.insert(template)
            let occurrence = PreviousSnapshotModels.TaskOccurrence(day: utcDay, template: template)
            context.insert(occurrence)
            history.append(occurrence.id)
            // An edit after completion must not replace these already valid snapshots at upgrade.
            template.categoryRaw = "errands"
            template.notes = "Added after completion"
            template.title = "New title"
            template.durationMinutes = 90
        }

        let daily = PreviousSnapshotModels.TaskTemplate(day: utcDay, category: "home")
        daily.recurrenceRaw = "daily"
        daily.isAutoScheduled = false
        context.insert(daily)
        let habit = PreviousSnapshotModels.TaskOccurrence(day: utcDay, template: daily)
        habit.statusRaw = "pending"
        habit.completedAt = nil
        habit.periodKey = "daily:2026-11-14"
        habit.scheduledDayKey = ""
        habit.scheduledTimezoneID = ""
        context.insert(habit)
        try context.save()
        return (history, habit.id)
    }

    func testUnversionedSnapshotDisplayDoesNotReadLaterTemplateEdits() {
        let template = TaskTemplate(title: "Original", notes: "", category: .selfCare)
        let occurrence = TaskOccurrence(
            scheduledDate: Date(), periodKey: "once:test", status: .completed, template: template
        )
        occurrence.snapshotSchemaVersion = 0
        template.notes = "Later note"
        template.category = .errands
        XCTAssertEqual(occurrence.displayNotes, "")
        XCTAssertEqual(occurrence.displayCategory, .selfCare)
        occurrence.migrateLegacyRecordIfNeeded()
        XCTAssertEqual(occurrence.displayNotes, "")
        XCTAssertEqual(occurrence.displayCategory, .selfCare)
    }

    func testDailyRecoveryPreservesExistingKeysAndManualPinsAndRejectsInvalidDates() {
        let utc = calendar("GMT")
        let newYork = calendar("America/New_York")
        let rawDate = day("2026-11-14", in: utc)
        let template = TaskTemplate(title: "Habit", recurrence: .daily, anchorDate: rawDate, calendar: utc)

        let invalid = TaskOccurrence(
            scheduledDate: rawDate, periodKey: "daily:2026-02-30", template: template, calendar: utc
        )
        invalid.scheduledDayKey = ""
        invalid.scheduledTimezoneID = ""
        invalid.normalizeCivilDates(in: newYork)
        XCTAssertEqual(invalid.scheduledDayKey, "2026-11-13")

        let pinned = TaskOccurrence(
            scheduledDate: rawDate, periodKey: "daily:2026-11-20", isManuallyPinned: true,
            template: template, calendar: utc
        )
        pinned.scheduledDayKey = ""
        pinned.scheduledTimezoneID = ""
        pinned.normalizeCivilDates(in: newYork)
        XCTAssertEqual(pinned.scheduledDayKey, "2026-11-13")

        let keyed = TaskOccurrence(
            scheduledDate: rawDate, periodKey: "daily:2026-11-20", template: template, calendar: utc
        )
        keyed.normalizeCivilDates(in: newYork)
        XCTAssertEqual(keyed.scheduledDayKey, "2026-11-14")
    }

    func testMigrationReadFailuresRemainRetryable() {
        for failingRead in MigrationTestStore.Read.allCases {
            let prefs = CozyPreferences()
            let store = MigrationTestStore(preferences: prefs)
            store.failRead = failingRead
            XCTAssertFalse(CozyDataMigrator.migrateIfNeeded(store: store, preferences: prefs))
            XCTAssertEqual(prefs.appliedDataMigrationVersion, 0)
            XCTAssertTrue(store.savedVersions.isEmpty)
            store.failRead = nil
            XCTAssertTrue(CozyDataMigrator.migrateIfNeeded(store: store, preferences: prefs))
            XCTAssertEqual(store.savedVersions.last, CozyDataMigrator.currentVersion)
        }
    }

    func testBatchAndCompletionSaveFailuresDoNotRecordMigrationSuccess() {
        for failingSave in [1, 2] {
            let prefs = CozyPreferences()
            let store = MigrationTestStore(preferences: prefs)
            store.failSaveNumber = failingSave
            XCTAssertFalse(CozyDataMigrator.migrateIfNeeded(store: store, preferences: prefs))
            XCTAssertEqual(prefs.appliedDataMigrationVersion, 0)
            XCTAssertFalse(store.savedVersions.contains(CozyDataMigrator.currentVersion))
            store.failSaveNumber = nil
            XCTAssertTrue(CozyDataMigrator.migrateIfNeeded(store: store, preferences: prefs))
            XCTAssertEqual(prefs.appliedDataMigrationVersion, CozyDataMigrator.currentVersion)
            XCTAssertEqual(store.savedVersions.last, CozyDataMigrator.currentVersion)
        }
    }
}

@MainActor
private final class MigrationTestStore: CozyMigrationStore {
    enum Read: CaseIterable, Equatable { case templates, overrides, occurrences }
    enum Failure: Error { case injected }

    let preferences: CozyPreferences
    let template: TaskTemplate
    let occurrence: TaskOccurrence
    var failRead: Read?
    var failSaveNumber: Int?
    var savesAttempted = 0
    var savedVersions: [Int] = []

    init(preferences: CozyPreferences) {
        self.preferences = preferences
        let historyTemplate = TaskTemplate(title: "History", category: .home)
        template = historyTemplate
        occurrence = TaskOccurrence(
            scheduledDate: Date(), periodKey: "once:legacy", status: .completed, template: historyTemplate
        )
        occurrence.snapshotSchemaVersion = 0
    }

    func fetchTemplates() throws -> [TaskTemplate] {
        if failRead == .templates { throw Failure.injected }
        return [template]
    }

    func fetchOverrides() throws -> [DayCapacityOverride] {
        if failRead == .overrides { throw Failure.injected }
        return []
    }

    func fetchOccurrences(requiringVersion version: Int, limit: Int) throws -> [TaskOccurrence] {
        if failRead == .occurrences { throw Failure.injected }
        return occurrence.snapshotSchemaVersion < version || occurrence.scheduledDayKey.isEmpty ? [occurrence] : []
    }

    func save() throws {
        savesAttempted += 1
        if savesAttempted == failSaveNumber { throw Failure.injected }
        savedVersions.append(preferences.appliedDataMigrationVersion)
    }
}

// Stored property declarations copied from 8dde195. Keep these separate from the app models so
// the on-disk fixture exercises SwiftData adding a missing field, not just reopening today's schema.
private enum PreviousSnapshotModels {
    @Model
    final class TaskTemplate {

        var id: UUID
        var title: String
        var notes: String
        var emoji: String
        var categoryRaw: String
        var recurrenceRaw: String

        var durationMinutes: Int

        var weightRaw: String = TaskWeight.light.rawValue

        var hasHardDeadline: Bool = false
        var hardDeadlineDate: Date? = nil
        var hardDeadlineDayKey: String = ""
        var hardDeadlineTimezoneID: String = ""

        var customIntervalDays: Int

        var isAutoScheduled: Bool

        var anchorDate: Date
        var anchorDayKey: String = ""
        var anchorTimezoneID: String = ""

        var flexibleWindowDays: Int

        var isActive: Bool
        var createdAt: Date

        @Relationship(deleteRule: .nullify, inverse: \TaskOccurrence.template)
        var occurrences: [TaskOccurrence] = []
        init(day: Date, category: String) {
            id = UUID()
            title = "Original title"
            notes = ""
            emoji = "🌸"
            categoryRaw = category
            recurrenceRaw = "weekly"
            durationMinutes = 15
            customIntervalDays = 3
            isAutoScheduled = true
            anchorDate = day
            anchorDayKey = "2026-11-14"
            anchorTimezoneID = "GMT"
            flexibleWindowDays = 7
            isActive = true
            createdAt = day
        }
    }
    @Model
    final class TaskOccurrence {

        var id: UUID

        var scheduledDate: Date
        var scheduledDayKey: String = ""
        var scheduledTimezoneID: String = ""

        var periodKey: String

        var statusRaw: String
        var completedAt: Date?

        var isManuallyPinned: Bool

        var bonusForDate: Date? = nil
        var bonusForDayKey: String = ""
        var bonusTimezoneID: String = ""
        var bonusSlot: Int = 0

        var googleCalendarEventId: String? = nil
        var googleSyncedDestination: String? = nil
        var syncedEKEventIdentifier: String? = nil
        var googleBridgeSyncedDestination: String? = nil
        var lastCalendarSyncSignature: String? = nil
        var appleCalendarEventIdentifier: String? = nil
        var appleSyncedDestination: String? = nil
        var lastAppleCalendarSyncSignature: String? = nil

        var weightSnapshotRaw: String = TaskWeight.light.rawValue
        var hasCustomWeightOverride: Bool = false
        var hardDeadlineSnapshot: Date? = nil
        var hardDeadlineSnapshotDayKey: String = ""

        var titleSnapshot: String
        var emojiSnapshot: String
        var durationMinutesSnapshot: Int
        var notesSnapshot: String = ""
        var recurrenceKindSnapshotRaw: String = RecurrenceKind.once.rawValue
        var recurrenceLabelSnapshot: String = "Once"
        var categorySnapshotRaw: String = TaskCategory.selfCare.rawValue

        var template: TaskTemplate?
        init(day: Date, template: TaskTemplate) {
            id = UUID()
            scheduledDate = day
            scheduledDayKey = "2026-11-14"
            scheduledTimezoneID = "GMT"
            periodKey = "weekly:2026-11-09"
            statusRaw = "completed"
            completedAt = day.addingTimeInterval(18 * 3600)
            isManuallyPinned = false
            titleSnapshot = template.title
            emojiSnapshot = template.emoji
            durationMinutesSnapshot = template.durationMinutes
            notesSnapshot = template.notes
            recurrenceKindSnapshotRaw = template.recurrenceRaw
            recurrenceLabelSnapshot = "Weekly"
            categorySnapshotRaw = template.categoryRaw
            self.template = template
        }
    }
}
