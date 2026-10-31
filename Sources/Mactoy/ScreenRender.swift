#if DEBUG
import AppKit
import SwiftUI
import MactoyKit

/// Screenshots of the main screens, for checking the UI on each macOS version
/// in CI (`.github/workflows/ui-screens.yml`). Debug builds only: release
/// builds don't contain this code.
///
/// Launch a debug build with `MACTOY_RENDER_SCREENS=<folder>`. The app shows
/// two made-up drives instead of the real ones, saves one PNG per screen into
/// the folder, and quits. It never lists real disks, talks to the helper or
/// opens a file picker.
@MainActor
enum ScreenRender {
    static var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["MACTOY_RENDER_SCREENS"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static let disks = [
        DiskTarget(bsdName: "disk4", sizeInBytes: 64_000_000_000, isExternal: true, isRemovable: true,
                   mediaName: "SanDisk Extreme", volumes: []),
        DiskTarget(bsdName: "disk6", sizeInBytes: 128_000_000_000, isExternal: true, isRemovable: true,
                   mediaName: "Samsung BAR Plus", volumes: []),
    ]

    static func run(_ state: AppState, into folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        state.timeMachineLookup = { [] }
        state.ventoyProber = { .unknownDisk(bsdName: $0, reason: "screenshot mode") }
        state.usedBytesEstimator = { _ in nil }
        state.disks = disks
        state.selectedDiskBSD = disks[0].bsdName
        await settle(3)

        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width >= 600 }) else {
            print("screen render: no window")
            NSApp.terminate(nil)
            return
        }
        window.setContentSize(NSSize(width: 1000, height: 720))
        window.center()

        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for mode in AppMode.allCases {
                state.mode = mode
                await settle()
                capture(window, "\(mode.rawValue)-\(dark ? "dark" : "light")", into: folder)
            }
        }

        NSApp.appearance = NSAppearance(named: .aqua)
        state.mode = .flashImage
        state.status = .running(ProgressUpdate(phase: .writing, message: "Writing the image to the drive",
                                               bytesDone: 3_200_000_000, bytesTotal: 5_800_000_000))
        await settle()
        capture(window, "status-running", into: folder)
        state.status = .failed("The image's SHA-256 doesn't match the one you entered. The download may be incomplete or damaged; download it again. Nothing was written to the drive.")
        await settle()
        capture(window, "status-failed", into: folder)
        state.status = .success("Done. The drive is ready.")
        await settle()
        capture(window, "status-success", into: folder)
        state.status = .idle

        state.mode = .installVentoy
        state.pendingEraseConfirmation = EraseConfirmation(mode: .installVentoy, disk: disks[0], usedBytes: 12_000_000_000,
                                                           totalBytes: disks[0].sizeInBytes, partitionStyle: .mbr)
        await settle(1.5)
        if let sheet = window.attachedSheet {
            capture(sheet, "erase-confirmation-sheet", into: folder)
        }
        state.pendingEraseConfirmation = nil
        await settle()

        state.disks = []
        state.selectedDiskBSD = nil
        await settle()
        capture(window, "no-disks", into: folder)

        print("screen render: done")
        NSApp.terminate(nil)
    }

    private static func settle(_ seconds: Double = 0.8) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Captures one window (never the screen) with `screencapture -l`, which
    /// includes the window frame and toolbar. If that fails, for example
    /// without Screen Recording permission, it draws the window's views instead.
    private static func capture(_ window: NSWindow, _ name: String, into folder: URL) {
        let file = folder.appendingPathComponent("\(name).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try? p.run()
        p.waitUntilExit()
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if p.terminationStatus == 0, size > 0 {
            print("screen render: \(name).png")
            return
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("screen render: \(name) failed")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        print("screen render: \(name).png (drawn, screencapture failed)")
    }
}
#endif
