import SwiftUI

@main
struct MactoyApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup("Mactoy") {
            ContentView()
                .environment(appState)
                .frame(minWidth: 880, minHeight: 600)
                .task {
                    appState.startDiskEnumeration()
                }
        }
        .windowResizability(.contentMinSize)
    }
}
