import Foundation
import SwiftData

enum CozyModelContainer {
    static let schema = Schema([
        TaskTemplate.self,
        TaskOccurrence.self,
        CozyPreferences.self,
        DayCapacityOverride.self
    ])

    static let shared: ModelContainer = {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to initialize CozyProductivity ModelContainer: \(error)")
        }
    }()

    @MainActor
    static func fetchOrCreatePreferences(in context: ModelContext) -> CozyPreferences {
        if let existing = (try? context.fetch(FetchDescriptor<CozyPreferences>()))?.first {
            CozyDataMigrator.migrateIfNeeded(context: context, preferences: existing)
            return existing
        }
        let created = CozyPreferences()
        context.insert(created)
        CozyDataMigrator.migrateIfNeeded(context: context, preferences: created)
        try? context.save()
        return created
    }
}

@MainActor
protocol CozyMigrationStore {
    func fetchTemplates() throws -> [TaskTemplate]
    func fetchOverrides() throws -> [DayCapacityOverride]
    func fetchOccurrences(requiringVersion version: Int, limit: Int) throws -> [TaskOccurrence]
    func save() throws
}

@MainActor
private struct SwiftDataMigrationStore: CozyMigrationStore {
    let context: ModelContext

    func fetchTemplates() throws -> [TaskTemplate] {
        try context.fetch(FetchDescriptor<TaskTemplate>())
    }

    func fetchOverrides() throws -> [DayCapacityOverride] {
        try context.fetch(FetchDescriptor<DayCapacityOverride>())
    }

    func fetchOccurrences(requiringVersion version: Int, limit: Int) throws -> [TaskOccurrence] {
        var descriptor = FetchDescriptor<TaskOccurrence>(
            predicate: #Predicate<TaskOccurrence> { occ in
                occ.snapshotSchemaVersion < version || occ.scheduledDayKey == ""
            }
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    func save() throws {
        try context.save()
    }
}

@MainActor
enum CozyDataMigrator {
    nonisolated static let currentVersion = 3
    private nonisolated static let batchSize = 400

    private enum MigrationError: Error {
        case noProgress
    }

    /// Returns true only after every required batch and the completion marker have been saved.
    /// A failed read/write leaves the marker unchanged so a later invocation can retry.
    @discardableResult
    static func migrateIfNeeded(
        context: ModelContext,
        preferences: CozyPreferences,
        calendar: Calendar = DateHelpers.calendar
    ) -> Bool {
        migrateIfNeeded(
            store: SwiftDataMigrationStore(context: context),
            preferences: preferences,
            calendar: calendar
        )
    }

    @discardableResult
    static func migrateIfNeeded(
        store: any CozyMigrationStore,
        preferences: CozyPreferences,
        calendar: Calendar = DateHelpers.calendar
    ) -> Bool {
        guard preferences.appliedDataMigrationVersion < currentVersion else { return true }
        let previousVersion = preferences.appliedDataMigrationVersion

        do {
            for template in try store.fetchTemplates() {
                template.normalizeCivilDates(in: calendar)
            }
            for item in try store.fetchOverrides() {
                item.normalizeCivilDates(in: calendar)
            }

            let targetSchema = TaskOccurrence.currentSnapshotSchemaVersion
            while true {
                let batch = try store.fetchOccurrences(requiringVersion: targetSchema, limit: batchSize)
                if batch.isEmpty {
                    preferences.appliedDataMigrationVersion = currentVersion
                    try store.save()
                    return true
                }

                var progressedInBatch = false
                for occ in batch {
                    let previousSchema = occ.snapshotSchemaVersion
                    let previousDayKey = occ.scheduledDayKey
                    occ.migrateLegacyRecordIfNeeded(calendar: calendar)
                    if occ.snapshotSchemaVersion != previousSchema || occ.scheduledDayKey != previousDayKey {
                        progressedInBatch = true
                    }
                }
                guard progressedInBatch else { throw MigrationError.noProgress }

                // Save the invalidation with each completed batch. If a later batch fails, the
                // next attempt can resume from persisted rows without trusting a stale archive.
                preferences.historicalStreakArchive = nil
                try store.save()
            }
        } catch {
            // In particular, undo an in-memory completion marker if its final save failed.
            // Do not roll back the caller's unrelated edits or previously successful batches.
            preferences.appliedDataMigrationVersion = previousVersion
            return false
        }
    }
}
