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
                    wireThemes()
                    appState.startDiskEnumeration()
                    // Local catalog shows at once; the online one replaces it when it arrives.
                    Task { await themeStore.load() }
                }
        }
        .windowResizability(.contentMinSize)
    }

    /// Hands AppState the theme store's work for installs. AppState only knows
    /// these as closures, so its tests never touch a disk or the network.
    private func wireThemes() {
        appState.installThemeApplier = { [themeStore] choice, disk in
            await themeStore.applyAfterInstall(choice, disk: disk)
        }
        appState.driveThemeProbe = { [themeStore] disk in
            await themeStore.savableDriveTheme(onDisk: disk.bsdName)
        }
        appState.driveThemeSaver = { [themeStore] volume in
            // Nil means the drive no longer has a theme to keep: say so, and
            // the erase doesn't start (the user asked for it to be kept).
            guard try await themeStore.saveDriveTheme(on: volume) != nil else { throw ThemeStoreError.nothingToSave }
        }
    }
}
