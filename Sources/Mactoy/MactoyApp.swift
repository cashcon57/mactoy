import SwiftUI
import os

private let appLog = Logger(subsystem: "com.mactoy", category: "lifecycle")

@main
struct MactoyApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var themeStore = ThemeStore()

    init() {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        appLog.info("Mactoy launch: v\(v, privacy: .public) build \(b, privacy: .public)")
    }

    var body: some Scene {
        WindowGroup("Mactoy") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(themeStore)
                .frame(minWidth: 880, minHeight: 600)
                .task {
                    appLog.info("first-window task: starting disk enumeration")
                    appState.startDiskEnumeration()
                    // Local catalog shows at once; the online one replaces it when it arrives.
                    Task { await themeStore.load() }
                }
        }
        .windowResizability(.contentMinSize)
    }
}
