import Foundation
import os

private let serviceLog = Logger(subsystem: "com.mactoy", category: "mactoyd")

/// What the helper runs, kept separate so tests can run `MactoydService` with drivers that
/// don't touch a disk.
public struct MactoydDependencies: Sendable {
    public var makeDriver: @Sendable (InstallPlan, FileHandle?, RunControl) throws -> any InstallDriver
    public var clearCache: @Sendable () throws -> UInt64
    public var probe: @Sendable (String) -> VentoyProbeResult

    public init(makeDriver: @escaping @Sendable (InstallPlan, FileHandle?, RunControl) throws -> any InstallDriver,
                clearCache: @escaping @Sendable () throws -> UInt64,
                probe: @escaping @Sendable (String) -> VentoyProbeResult) {
        self.makeDriver = makeDriver
        self.clearCache = clearCache
        self.probe = probe
    }

    public static let live = MactoydDependencies(
        makeDriver: { plan, image, control in
            switch plan.driver {
            case .ventoy:
                return VentoyDriver(control: control)
            case .rawImage:
                // Never open the plan's path as root: it could name a file the user can't read (#36).
                guard let image else {
                    throw DriverError.validation("Mactoy didn't hand over the image file, so nothing was written. Update Mactoy and try again.")
                }
                return RawImageDriver(image: image, control: control)
            }
        },
        clearCache: { try VentoyDownloader.clearCache() },
        probe: { VentoyVersionProbe.probe(bsdName: $0) }
    )
}

/// The helper's XPC service: one per accepted connection. The daemon (`mactoyd`) checks who's
/// calling before it creates one.
public final class MactoydService: NSObject, MactoydProtocol {
    weak var connection: NSXPCConnection?
    private let gate: RunGate
    private let dependencies: MactoydDependencies

    /// `dependencies` is replaced only in tests, which run this same service over a real XPC
    /// connection with drivers that don't touch a disk.
    public init(connection: NSXPCConnection, gate: RunGate, dependencies: MactoydDependencies = .live) {
        self.connection = connection
        self.gate = gate
        self.dependencies = dependencies
    }

    public func ping(reply: @escaping (String) -> Void) {
        reply(mactoydVersion)
    }

    public func probeVentoy(_ bsdName: String, reply: @escaping (Data?, String?) -> Void) {
        // Ventoy probe is read-only and synchronous (a few sector reads
        // off `/dev/rdisk*`). We still hop to a detached task so we
        // don't tie up the XPC delivery queue if the disk is slow to
        // respond. The reply closure isn't Sendable, so wrap it in an
        // unchecked-Sendable shim like `executePlan` does.
        let replyBox = ProbeReplyBox(reply)
        let probe = dependencies.probe
        Task.detached {
            serviceLog.info("probeVentoy: bsd=\(bsdName, privacy: .public)")
            let result = probe(bsdName)
            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(result)
                serviceLog.info("probeVentoy: bsd=\(bsdName, privacy: .public) isVentoy=\(result.isVentoyDisk, privacy: .public) version=\(result.detectedVersion ?? "n/a", privacy: .public)")
                replyBox.call(data, nil)
            } catch {
                serviceLog.error("probeVentoy: encode failed: \(error.localizedDescription, privacy: .private)")
                replyBox.call(nil, "encoding failed: \(error)")
            }
        }
    }

    public func cancelCurrentRun(reply: @escaping (Bool) -> Void) {
        let accepted = gate.cancelAll()
        serviceLog.info("cancelCurrentRun: accepted=\(accepted, privacy: .public)")
        reply(accepted)
    }

    public func clearDownloads(reply: @escaping (UInt64, String?) -> Void) {
        do {
            guard let freed = try gate.whenIdle({ try dependencies.clearCache() }) else {
                serviceLog.info("clearDownloads: refused, an install is running")
                reply(0, "Mactoy is writing a drive. Try again when it's finished.")
                return
            }
            serviceLog.info("clearDownloads: freed \(freed, privacy: .public) bytes")
            reply(freed, nil)
        } catch {
            serviceLog.error("clearDownloads failed: \(error.localizedDescription, privacy: .private)")
            reply(0, "\(error)")
        }
    }

    public func executePlan(_ planData: Data, image: FileHandle?, reply: @escaping (Bool, String?) -> Void) {
        let imageBox = FileHandleBox(image)
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

        let control = RunControl()
        let gate = gate
        let makeDriver = dependencies.makeDriver
        gate.planStarted(control)
        Task.detached {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            do {
                let plan = try decoder.decode(InstallPlan.self, from: planData)
                serviceLog.info("executePlan: driver=\(plan.driver.rawValue, privacy: .public) target=/dev/\(plan.target.bsdName, privacy: .public)")

                let driver = try makeDriver(plan, imageBox.handle, control)

                sink.report(.init(phase: .preparing, message: "mactoyd started, plan received"))
                try await driver.execute(plan: plan, progress: sink)
                serviceLog.info("executePlan: complete")
                sink.report(.init(phase: .done, message: "Install complete"))
                // Before replying: the app may clear downloads as soon as it hears back.
                gate.planEnded(control)
                replyBox.call(true, nil)
            } catch {
                // .private — error descriptions can include filesystem
                // paths or other user-identifiable detail. Visible to
                // the local user; redacted in shared `log show` output.
                serviceLog.error("executePlan failed: \(error.localizedDescription, privacy: .private)")
                sink.report(.init(phase: .failed, message: "\(error)"))
                gate.planEnded(control)
                replyBox.call(false, "\(error)")
            }
        }
    }
}

/// Counts running plans, so the download cache is never cleared while an install uses it.
/// `whenIdle` holds the lock while it runs, so no plan can start until the clearing is done.
public final class RunGate: @unchecked Sendable {
    /// The helper's one gate: every connection's service shares it.
    public static let shared = RunGate()

    public init() {}

    private let lock = NSLock()
    private var running = 0

    private var controls: [ObjectIdentifier: RunControl] = [:]

    func planStarted(_ control: RunControl) {
        lock.lock(); running += 1; controls[ObjectIdentifier(control)] = control; lock.unlock()
    }
    func planEnded(_ control: RunControl) {
        lock.lock(); running = max(0, running - 1); controls[ObjectIdentifier(control)] = nil; lock.unlock()
    }

    /// Asks every running plan to stop (there's normally one). True if any accepted.
    public func cancelAll() -> Bool {
        lock.lock()
        let current = Array(controls.values)
        lock.unlock()
        return current.map { $0.requestCancel() }.contains(true)
    }

    /// Runs `body` only when no plan is running; nil when one is.
    func whenIdle<T>(_ body: () throws -> T) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard running == 0 else { return nil }
        return try body()
    }
}


/// Carries the image's file handle into the detached task. The task is its only user.
final class FileHandleBox: @unchecked Sendable {
    let handle: FileHandle?
    init(_ handle: FileHandle?) { self.handle = handle }
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
            serviceLog.error("progress delivery failed: \(String(describing: err), privacy: .private)")
        } as? MactoyClientProtocol
        proxy?.receiveProgress(data)
    }
}

