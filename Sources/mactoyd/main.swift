import Foundation
import MactoyKit
import os

private let daemonLog = Logger(subsystem: "com.mactoy", category: "mactoyd")

/// mactoyd — privileged helper daemon.
///
/// Runs as root under `launchd`, registered into the user's system via
/// `SMAppService` from the Mactoy app. Accepts XPC connections on the
/// `com.mactoy.mactoyd` mach service.
///
/// Security:
///   - Only accepts connections from binaries signed by the Mactoy
///     team identifier (MUQ3H79Y4N). A malicious client cannot pipe a
///     plan in like they could with the old osascript design.
///   - Must run as root (EUID 0) — enforced at startup.

let signingTeamIdentifier = "MUQ3H79Y4N"
let expectedClientIdentifier = "com.mactoy.Mactoy"

final class DaemonListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    /// Connection-lifecycle bookkeeping. The daemon exits 0.5 s after
    /// the LAST connection closes so launchd can respawn us fresh on
    /// the next install (which makes upgrades pick up the new
    /// `mactoyd` binary instead of leaving a stale RunLoop alive).
    /// Pre-v0.3.0 the only XPC traffic was `executePlan`, so the
    /// per-connection auto-exit pattern was safe. v0.3.0 added
    /// `probeVentoy`, which the app fires on every disk-selection
    /// change — without the cancellation logic below, the queued
    /// `exit(0)` from a probe disconnect could fire DURING a
    /// subsequent install and corrupt the bootloader mid-write.
    ///
    /// The bookkeeping: track active-connection count + a pending
    /// `DispatchWorkItem`. When a new connection arrives, cancel
    /// the pending exit. Only schedule a new exit when active count
    /// drops to zero.
    private let lock = NSLock()
    private var activeConnections = 0
    private var pendingExit: DispatchWorkItem?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard authorize(connection: newConnection) else {
            daemonLog.error("rejected unauthorized XPC client (signing-requirement check failed)")
            fputs("mactoyd: rejected unauthorized XPC client\n", stderr)
            return false
        }

        // Cancel any pending shutdown — a new client just connected.
        // This is the v0.3.0 fix for the probe→install race.
        lock.lock()
        if let pending = pendingExit {
            pending.cancel()
            pendingExit = nil
            daemonLog.info("cancelled pending exit — new connection arrived in time")
        }
        activeConnections += 1
        let activeAfter = activeConnections
        lock.unlock()

        daemonLog.info("accepted XPC client connection (active=\(activeAfter, privacy: .public))")
        newConnection.exportedInterface = NSXPCInterface(with: MactoydProtocol.self)
        newConnection.exportedObject = MactoydService(connection: newConnection)
        newConnection.remoteObjectInterface = NSXPCInterface(with: MactoyClientProtocol.self)

        newConnection.invalidationHandler = { [weak self] in
            self?.scheduleShutdownIfIdle(reason: "closed")
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.scheduleShutdownIfIdle(reason: "interrupted")
        }

        newConnection.resume()
        return true
    }

    /// Called from a connection's invalidation/interruption handler.
    /// Decrements the active-connection counter and, if it hits zero,
    /// schedules a delayed `exit(0)` that the next-arriving connection
    /// can cancel before it fires.
    private func scheduleShutdownIfIdle(reason: String) {
        lock.lock()
        activeConnections = max(0, activeConnections - 1)
        let active = activeConnections
        // If another connection is already in flight (e.g. install
        // started while a probe was being torn down), don't schedule
        // an exit at all.
        guard active == 0 else {
            lock.unlock()
            daemonLog.info("connection \(reason, privacy: .public); other connections still active (count=\(active, privacy: .public)) — not scheduling exit")
            return
        }
        // Cancel any prior pending exit (defensive — shouldn't happen
        // since acceptNewConnection cancels it, but harmless).
        pendingExit?.cancel()
        let item = DispatchWorkItem {
            daemonLog.info("XPC idle timeout, exiting for clean re-spawn (\(reason, privacy: .public))")
            fputs("mactoyd: XPC idle timeout, exiting for clean re-spawn\n", stderr)
            exit(0)
        }
        pendingExit = item
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Verify the connecting process is signed by our team identifier and
    /// has the expected bundle identifier. Prevents any process on the
    /// machine (even another admin-authorized user) from piping a plan
    /// into the root daemon.
    private func authorize(connection: NSXPCConnection) -> Bool {
        // NSXPCConnection.auditToken is declared in a private XPC header
        // but is reachable via KVC. The struct is returned wrapped in an
        // NSValue, which we copy into a stack-local audit_token_t and
        // then hand to Security Framework as Data.
        guard let nsValue = connection.value(forKey: "auditToken") as? NSValue else {
            return false
        }
        var token = audit_token_t(val: (0, 0, 0, 0, 0, 0, 0, 0))
        nsValue.getValue(&token, size: MemoryLayout<audit_token_t>.size)

        let tokenData = withUnsafeBytes(of: &token) { Data($0) }

        let attrs: [CFString: Any] = [
            kSecGuestAttributeAudit: tokenData
        ]

        var codeRef: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &codeRef)
        guard status == errSecSuccess, let code = codeRef else { return false }

        // The requirement string Apple uses in designated-requirement checks:
        // anchor apple generic (Apple-issued cert chain)
        // certificate leaf[subject.OU] = <team-id>
        // identifier = <bundle-id>
        // This exact form is what notarization outputs as the DR for our app.
        let requirementString = """
        anchor apple generic \
        and certificate leaf[subject.OU] = "\(signingTeamIdentifier)" \
        and identifier "\(expectedClientIdentifier)"
        """

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
              let req = requirement else {
            return false
        }

        let check = SecCodeCheckValidity(code, [], req)
        return check == errSecSuccess
    }
}

final class MactoydService: NSObject, MactoydProtocol {
    weak var connection: NSXPCConnection?

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func ping(reply: @escaping (String) -> Void) {
        reply(mactoydVersion)
    }

    func probeVentoy(_ bsdName: String, reply: @escaping (Data?, String?) -> Void) {
        // Ventoy probe is read-only and synchronous (a few sector reads
        // off `/dev/rdisk*`). We still hop to a detached task so we
        // don't tie up the XPC delivery queue if the disk is slow to
        // respond. The reply closure isn't Sendable, so wrap it in an
        // unchecked-Sendable shim like `executePlan` does.
        let replyBox = ProbeReplyBox(reply)
        Task.detached {
            daemonLog.info("probeVentoy: bsd=\(bsdName, privacy: .public)")
            let result = VentoyVersionProbe.probe(bsdName: bsdName)
            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(result)
                daemonLog.info("probeVentoy: bsd=\(bsdName, privacy: .public) isVentoy=\(result.isVentoyDisk, privacy: .public) version=\(result.detectedVersion ?? "n/a", privacy: .public)")
                replyBox.call(data, nil)
            } catch {
                daemonLog.error("probeVentoy: encode failed: \(error.localizedDescription, privacy: .private)")
                replyBox.call(nil, "encoding failed: \(error)")
            }
        }
    }

    func executePlan(_ planData: Data, reply: @escaping (Bool, String?) -> Void) {
        // Proxy + reply callbacks are not Sendable. Wrap both in unchecked
        // shims so they can be captured into the detached task. Safe in
        // practice: NSXPCConnection serializes proxy access, and `reply`
        // is meant to be invoked exactly once.
        let deliver = ClientProxyBox(connection: connection)
        let replyBox = ReplyBox(reply)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let sink = CallbackProgressSink { update in
            guard let data = try? encoder.encode(update) else { return }
            deliver.send(data)
        }

        Task.detached {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            do {
                let plan = try decoder.decode(InstallPlan.self, from: planData)
                daemonLog.info("executePlan: driver=\(plan.driver.rawValue, privacy: .public) target=/dev/\(plan.target.bsdName, privacy: .public)")

                let driver: any InstallDriver
                switch plan.driver {
                case .ventoy:   driver = VentoyDriver()
                case .rawImage: driver = RawImageDriver()
                }

                sink.report(.init(phase: .preparing, message: "mactoyd started, plan received"))
                try await driver.execute(plan: plan, progress: sink)
                daemonLog.info("executePlan: complete")
                sink.report(.init(phase: .done, message: "Install complete"))
                replyBox.call(true, nil)
            } catch {
                // .private — error descriptions can include filesystem
                // paths or other user-identifiable detail. Visible to
                // the local user; redacted in shared `log show` output.
                daemonLog.error("executePlan failed: \(error.localizedDescription, privacy: .private)")
                sink.report(.init(phase: .failed, message: "\(error)"))
                replyBox.call(false, "\(error)")
            }
        }
    }
}

/// Wraps an Objective-C XPC reply block so it can cross actor boundaries.
/// XPC guarantees the reply will be invoked at most once, so the
/// unchecked-Sendable annotation is safe.
final class ReplyBox: @unchecked Sendable {
    private let reply: (Bool, String?) -> Void
    init(_ reply: @escaping (Bool, String?) -> Void) { self.reply = reply }
    func call(_ success: Bool, _ err: String?) { reply(success, err) }
}

/// Same shape as ReplyBox, but for the probe reply block whose first
/// argument is `Data?` (encoded `VentoyProbeResult`) instead of `Bool`.
final class ProbeReplyBox: @unchecked Sendable {
    private let reply: (Data?, String?) -> Void
    init(_ reply: @escaping (Data?, String?) -> Void) { self.reply = reply }
    func call(_ data: Data?, _ err: String?) { reply(data, err) }
}

/// Wrapper to hand the client proxy into a @Sendable async closure.
/// NSXPCConnection's proxy delivery is thread-safe (internal serial
/// queue), so passing it across isolation boundaries is fine in practice
/// even though the Objective-C protocol isn't declared Sendable.
///
/// Holds the connection *strongly* for the lifetime of the install —
/// previously we had a weak ref that dropped under URLSession's
/// delegate queue, which is why download progress never reached the
/// UI even though the raw bytes were arriving.
final class ClientProxyBox: @unchecked Sendable {
    private let connection: NSXPCConnection?
    init(connection: NSXPCConnection?) { self.connection = connection }
    func send(_ data: Data) {
        let proxy = connection?.remoteObjectProxyWithErrorHandler { err in
            fputs("mactoyd: xpc progress delivery failed: \(err)\n", stderr)
        } as? MactoyClientProtocol
        proxy?.receiveProgress(data)
    }
}

// Entry point
guard getuid() == 0 else {
    daemonLog.fault("must be run as root (EUID 0); exiting")
    fputs("mactoyd: must be run as root (EUID 0)\n", stderr)
    exit(77)
}

daemonLog.info("mactoyd starting (version \(mactoydVersion, privacy: .public)) — listening on \(mactoydMachServiceName, privacy: .public)")

let listener = NSXPCListener(machServiceName: mactoydMachServiceName)
let delegate = DaemonListenerDelegate()
listener.delegate = delegate
listener.resume()

RunLoop.main.run()
