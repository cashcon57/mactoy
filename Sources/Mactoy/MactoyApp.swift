import SwiftUI
import os

private let appLog = Logger(subsystem: "com.mactoy", category: "lifecycle")

@main
struct MactoyApp: App {
    @StateObject private var appState = AppState()

    init() {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        appLog.info("Mactoy launch: v\(v, privacy: .public) build \(b, privacy: .public)")
    }

    var body: some Scene {
        WindowGroup("Mactoy") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 880, minHeight: 600)
                .task {
                    appLog.info("first-window task: starting disk enumeration")
                    appState.startDiskEnumeration()
                }
        }
        .windowResizability(.contentMinSize)
    }
}
