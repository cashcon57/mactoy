import SwiftUI

@main
struct MactoyApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup("Mactoy") {
            ContentView()
                .environment(appState)
                .frame(minWidth: 820, minHeight: 560)
                .task {
                    await appState.startDiskEnumeration()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}
