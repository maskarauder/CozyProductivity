import SwiftData
import SwiftUI

@main
struct CozyProductivityApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(CozyModelContainer.shared)
    }
}
