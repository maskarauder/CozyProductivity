import SwiftData
import SwiftUI

@main
struct CozyProductivityApp: App {
    private var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        WindowGroup {
            if isRunningUnitTests {
                Color.clear
            } else {
                RootTabView()
            }
        }
        .modelContainer(CozyModelContainer.shared)
    }
}
