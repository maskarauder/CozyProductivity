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
            return existing
        }
        let created = CozyPreferences()
        context.insert(created)
        try? context.save()
        return created
    }
}
