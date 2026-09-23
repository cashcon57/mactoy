import Foundation
import MactoyKit
import os

/// Runs the bundled `mactoyd` helper daemon over XPC. Assumes the
/// daemon has already been registered + approved via `HelperLifecycle`
/// (AppState gates on this before calling `run(...)`).
enum HelperInvoker {

    enum HelperError: LocalizedError {
        case xpcUnreachable(String)
        case executionFailed(String)

        var errorDescription: String? {
            switch self {
            case .xpcUnreachable(let s):
                return "Could not reach the Mactoy helper daemon: \(s)"
            case .executionFailed(let s):
                return s
            }
        }
    }

    /// Cheap read-only probe of a USB drive. Returns the parsed
    /// `VentoyProbeResult`, or throws if the daemon is unreachable.
    /// **Always** returns a result (never nil); a non-Ventoy disk
    /// surfaces as `isVentoyDisk == false` rather than as an error.
    static func probeVentoy(bsdName: String) async throws -> VentoyProbeResult {
        let connection = NSXPCConnection(machServiceName: mactoydMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: MactoydProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<VentoyProbeResult, Error>) in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ err in
                cont.resume(throwing: HelperError.xpcUnreachable("\(err)"))
            }) as? MactoydProtocol else {
                cont.resume(throwing: HelperError.xpcUnreachable("proxy unavailable"))
                return
            }
            proxy.probeVentoy(bsdName) { resultData, errMsg in
                if let resultData {
                    do {
                        let decoded = try JSONDecoder().decode(VentoyProbeResult.self, from: resultData)
                        cont.resume(returning: decoded)
                    } catch {
                        cont.resume(throwing: HelperError.executionFailed("probe decode failed: \(error)"))
                    }
                } else {
                    cont.resume(throwing: HelperError.executionFailed(errMsg ?? "probe failed with no detail"))
                }
            }
        }
    }

    static func run(
        plan: InstallPlan,
        onUpdate: @escaping @MainActor (ProgressUpdate) -> Void
    ) async throws {

        let connection = NSXPCConnection(machServiceName: mactoydMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: MactoydProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: MactoyClientProtocol.self)

        let forwarder = ProgressForwarder { update in
            Task { @MainActor in onUpdate(update) }
        }
        connection.exportedObject = forwarder

        var invalidationErr: String?
        connection.invalidationHandler = { invalidationErr = "connection invalidated" }
        connection.interruptionHandler = { invalidationErr = "connection interrupted" }
        connection.resume()
        defer { connection.invalidate() }

        // Version handshake (v0.4.0). launchd can be holding a
        // registration for a *different copy* of Mactoy than the one
        // that's running — e.g. this build opened from the DMG while
        // an older one in /Applications owns the daemon. An older
        // daemon decodes a v3 plan without complaint and ignores what
        // it doesn't know: it would write the shim layout regardless of
        // `secureBoot`, and still has the v0.3.x MBR update bug.
        let daemonVersion = try await Self.ping(connection)
        guard daemonVersion == mactoydVersion else {
            throw HelperError.executionFailed(
                "The installed Mactoy helper is version \(daemonVersion), but this is Mactoy \(mactoydVersion). " +
                "Nothing was written. Quit any other copy of Mactoy, then in System Settings → General → " +
                "\(SystemSettingsStrings.loginItemsPane) turn the Mactoy toggle off and back on, and try again."
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let planData = try encoder.encode(plan)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ err in
                cont.resume(throwing: HelperError.xpcUnreachable("\(err)"))
            }) as? MactoydProtocol else {
                cont.resume(throwing: HelperError.xpcUnreachable("proxy unavailable"))
                return
            }

            proxy.executePlan(planData) { success, errMsg in
                if success {
                    cont.resume()
                } else if let invalidationErr {
                    cont.resume(throwing: HelperError.xpcUnreachable(invalidationErr))
                } else {
                    cont.resume(throwing: HelperError.executionFailed(errMsg ?? "mactoyd reported failure with no detail"))
                }
            }
        }
    }
}

extension HelperInvoker {
    /// Ask the daemon on `connection` for its version string.
    fileprivate static func ping(_ connection: NSXPCConnection) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ err in
                cont.resume(throwing: HelperError.xpcUnreachable("\(err)"))
            }) as? MactoydProtocol else {
                cont.resume(throwing: HelperError.xpcUnreachable("proxy unavailable"))
                return
            }
            proxy.ping { version in cont.resume(returning: version) }
        }
    }
}

/// Receives progress callbacks from the daemon over XPC and forwards
/// them to the app via the @MainActor closure supplied by `run`.
///
/// **Throttled to ~30 Hz** to bound SwiftUI invalidation rate during a
/// flash. Without this, a large image producing hundreds of progress
/// updates per second would (a) spawn a `Task { @MainActor in ... }`
/// per update and (b) fire `objectWillChange` on `AppState` twice per
/// update (once for `log.append`, once for `status = .running`),
/// invalidating every `@EnvironmentObject` subscriber at the same
/// rate. v0.2.0 shipped without this throttle and a user reported
/// runaway memory pressure on a multi-GB flash.
///
/// Phase transitions and terminal updates (`.done` / `.failed`) are
/// **never dropped** — only intra-phase progress updates with a
/// fraction change are coalesced.
final class ProgressForwarder: NSObject, MactoyClientProtocol, @unchecked Sendable {
    private let callback: (ProgressUpdate) -> Void
    private let decoder: JSONDecoder
    private let lock = NSLock()
    private var lastDeliveredAt: TimeInterval = 0
    private var lastDeliveredPhase: ProgressUpdate.Phase?
    /// Most recent throttled-out update. Flushed when the next phase
    /// transition or terminal update arrives, so the user always sees
    /// the final intra-phase frame (e.g. ".writing 99.9%") before the
    /// phase changes. Without this the progress bar appears to freeze
    /// at 95-99% before jumping to "Install complete".
    private var pendingDropped: ProgressUpdate?
    private static let minIntervalSec: TimeInterval = 1.0 / 30.0  // ~33ms

    private static let log = Logger(subsystem: "com.mactoy", category: "xpc.progress")

    init(callback: @escaping (ProgressUpdate) -> Void) {
        self.callback = callback
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
    }

    func receiveProgress(_ updateData: Data) {
        guard let update = try? decoder.decode(ProgressUpdate.self, from: updateData) else {
            Self.log.error("dropped malformed progress update from daemon")
            return
        }

        lock.lock()
        // ProcessInfo.processInfo.systemUptime is monotonic across the
        // process lifetime and does NOT advance during system sleep.
        // For our throttle that's fine: if the system sleeps mid-flash
        // the daemon also sleeps, so progress updates pause too — the
        // throttle window resumes correctly on wake.
        let now = ProcessInfo.processInfo.systemUptime
        let isPhaseTransition = update.phase != lastDeliveredPhase
        let isTerminal = update.phase == .done || update.phase == .failed
        let withinThrottle = (now - lastDeliveredAt) < Self.minIntervalSec
        let shouldDrop = !isPhaseTransition && !isTerminal && withinThrottle

        // If we're about to deliver a phase transition or terminal
        // update and we have a buffered intra-phase tick that was
        // throttled out, flush it FIRST so the user sees 100% before
        // "Install complete".
        let toFlushFirst: ProgressUpdate? = (!shouldDrop && (isPhaseTransition || isTerminal))
            ? pendingDropped : nil

        if shouldDrop {
            pendingDropped = update
        } else {
            pendingDropped = nil
            lastDeliveredAt = now
            lastDeliveredPhase = update.phase
        }
        lock.unlock()

        if let toFlushFirst { callback(toFlushFirst) }
        if !shouldDrop { callback(update) }
    }
}
