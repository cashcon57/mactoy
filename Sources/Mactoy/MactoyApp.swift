import SwiftUI

@main
struct MactoyApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Mactoy") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 880, minHeight: 600)
                .task {
                    appState.startDiskEnumeration()
                }
        }
        .windowResizability(.contentMinSize)
    }
}
