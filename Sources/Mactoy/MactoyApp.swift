import SwiftUI
import MactoyKit
import os

private let appLog = Logger(subsystem: "com.mactoy", category: "lifecycle")

@main
struct MactoyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var themeStore = ThemeStore(legacyLibraryRoot: ThemeLibrary.legacyRoot(), defaults: .standard)

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
                // A theme removed from My Themes, or gone from the catalog, must not stay the pick for the next install.
                .onChange(of: themeStore.availability) { appState.resetInstallThemeIfUnavailable($0) }
                .alert("Clear Ventoy Downloads", isPresented: Binding(
                    get: { appState.clearDownloadsReport != nil },
                    set: { if !$0 { appState.clearDownloadsReport = nil } }
                )) {
                    Button("OK") {}
                } message: {
                    Text(appState.clearDownloadsReport ?? "")
                }
                .task {
                    appDelegate.appState = appState
                    #if DEBUG
                    // Screenshot mode for CI: made-up drives, no real disks, then quit.
                    if let folder = ScreenRender.outputDirectory {
                        // The theme list, so the Install tab's theme card has its preview.
                        Task { await themeStore.load() }
                        await ScreenRender.run(appState, into: folder)
                        return
                    }
                    #endif
                    // Before v0.8.0 macOS kept a web cache and HTTPStorages for Mactoy; nothing uses them now (issue #22).
                    Task.detached(priority: .background) { MactoyHTTP.removeStaleSharedSessionFiles() }
                    appLog.info("first-window task: starting disk enumeration")
                    wireThemes()
                    appState.startDiskEnumeration()
                    // Local catalog shows at once; the online one replaces it when it arrives.
                    Task { await themeStore.load() }
                }
        }
        .windowResizability(.contentMinSize)
        // The mode picker sits in the toolbar; the window title would only repeat the app's name.
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Clear Ventoy Downloads") {
                    Task { await appState.clearVentoyDownloads() }
                }
                .disabled(!appState.canClearDownloads)
            }
        }
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

/// Asks before quitting while Manage Disk copies files to a drive, and lets the copy remove
/// its unfinished file first.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = appState, state.imageCopy != nil else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Mactoy is copying files to a drive."
        alert.informativeText = "If you quit now, the copy stops and the unfinished file is removed from the drive. Files already copied stay."
        alert.addButton(withTitle: "Keep Copying")
        alert.addButton(withTitle: "Stop and Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        // It may have finished while the alert was up.
        guard state.imageCopy != nil else { return .terminateNow }
        state.onImageCopyEnded = { [weak state] in
            state?.onImageCopyEnded = nil
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        state.cancelImageCopy()
        return .terminateLater
    }
}
