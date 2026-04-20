import Foundation
import MactoyKit

/// mactoyd — privileged helper that executes an InstallPlan read from stdin (JSON)
/// and reports ProgressUpdates to stdout (NDJSON). Must run as root.
///
/// Invoked by Mactoy.app via `osascript` with admin privileges.

struct Mactoyd {
    static func main() async {
        guard getuid() == 0 else {
            fputs("mactoyd: must be run as root (EUID 0)\n", stderr)
            exit(77)
        }

        // Read plan JSON from stdin
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        guard !stdinData.isEmpty else {
            fputs("mactoyd: no plan received on stdin\n", stderr)
            exit(64)
        }

        let plan: InstallPlan
        do {
            let decoder = JSONDecoder()
            plan = try decoder.decode(InstallPlan.self, from: stdinData)
        } catch {
            fputs("mactoyd: failed to decode plan: \(error)\n", stderr)
            exit(65)
        }

        let progress = NDJSONProgressSink()
        progress.report(.init(phase: .preparing, message: "mactoyd started, plan received"))

        let driver: any InstallDriver
        switch plan.driver {
        case .ventoy:   driver = VentoyDriver()
        case .rawImage: driver = RawImageDriver()
        }

        do {
            try await driver.execute(plan: plan, progress: progress)
            progress.report(.init(phase: .done, message: "Install complete"))
            exit(0)
        } catch {
            progress.report(.init(phase: .failed, message: "\(error)"))
            fputs("mactoyd: \(error)\n", stderr)
            exit(1)
        }
    }
}

await Mactoyd.main()
