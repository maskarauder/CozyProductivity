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
enum CozyDataMigrator {
    nonisolated static let currentVersion = 2
    private nonisolated static let batchSize = 400

    /// Performs an idempotent, batched persistent-store upgrade across all legacy templates, overrides, and occurrences.
    /// Backfills civil `"YYYY-MM-DD"` day keys across all historical records and upgrades occurrence snapshots without mislabeling completed history.
    static func migrateIfNeeded(
        context: ModelContext,
        preferences: CozyPreferences,
        calendar: Calendar = DateHelpers.calendar
    ) {
        guard preferences.appliedDataMigrationVersion < currentVersion else { return }

        let templates = (try? context.fetch(FetchDescriptor<TaskTemplate>())) ?? []
        for template in templates {
            template.normalizeCivilDates(in: calendar)
        }

        let overrides = (try? context.fetch(FetchDescriptor<DayCapacityOverride>())) ?? []
        for item in overrides {
            item.normalizeCivilDates(in: calendar)
        }

        let targetSchema = TaskOccurrence.currentSnapshotSchemaVersion
        var migratedAnyOccurrences = false
        var safetyPasses = 0

        while safetyPasses < 500 {
            safetyPasses += 1
            var descriptor = FetchDescriptor<TaskOccurrence>(
                predicate: #Predicate<TaskOccurrence> { occ in
                    occ.snapshotSchemaVersion < targetSchema || occ.scheduledDayKey == ""
                }
            )
            descriptor.fetchLimit = batchSize

            let batch = (try? context.fetch(descriptor)) ?? []
            guard !batch.isEmpty else { break }

            var progressedInBatch = false
            for occ in batch {
                let prevVersion = occ.snapshotSchemaVersion
                let prevDayKey = occ.scheduledDayKey
                occ.migrateLegacyRecordIfNeeded(calendar: calendar)
                if occ.scheduledDayKey.isEmpty {
                    let norm = DateHelpers.startOfDay(for: occ.scheduledDate, calendar: calendar)
                    occ.scheduledDate = norm
                    occ.scheduledDayKey = DateHelpers.dayKeyString(for: norm, calendar: calendar)
                    occ.scheduledTimezoneID = calendar.timeZone.identifier
                }
                if occ.snapshotSchemaVersion != prevVersion || occ.scheduledDayKey != prevDayKey {
                    progressedInBatch = true
                    migratedAnyOccurrences = true
                }
            }

            try? context.save()
            if !progressedInBatch {
                break
            }
        }

        if migratedAnyOccurrences {
            // Force historical streak checkpoint to rebuild cleanly once using migrated civil day keys
            preferences.historicalStreakArchive = nil
        }

        preferences.appliedDataMigrationVersion = currentVersion
        try? context.save()
    }
}
