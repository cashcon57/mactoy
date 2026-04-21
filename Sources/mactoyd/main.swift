import Foundation
import MactoyKit

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

final class DaemonListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard authorize(connection: newConnection) else {
            fputs("mactoyd: rejected unauthorized XPC client\n", stderr)
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: MactoydProtocol.self)
        newConnection.exportedObject = MactoydService(connection: newConnection)
        newConnection.remoteObjectInterface = NSXPCInterface(with: MactoyClientProtocol.self)

        // When the client disconnects, schedule process exit so launchd
        // re-spawns us fresh on the next connection. Without this, a
        // long-lived RunLoop keeps an old mactoyd binary live across
        // rebuilds / upgrades — the user ends up talking to stale code.
        newConnection.invalidationHandler = {
            fputs("mactoyd: XPC connection closed, exiting for clean re-spawn\n", stderr)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
        }
        newConnection.interruptionHandler = {
            fputs("mactoyd: XPC connection interrupted, exiting\n", stderr)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
        }

        newConnection.resume()
        return true
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

                let driver: any InstallDriver
                switch plan.driver {
                case .ventoy:   driver = VentoyDriver()
                case .rawImage: driver = RawImageDriver()
                }

                sink.report(.init(phase: .preparing, message: "mactoyd started, plan received"))
                try await driver.execute(plan: plan, progress: sink)
                sink.report(.init(phase: .done, message: "Install complete"))
                replyBox.call(true, nil)
            } catch {
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
    fputs("mactoyd: must be run as root (EUID 0)\n", stderr)
    exit(77)
}

let listener = NSXPCListener(machServiceName: mactoydMachServiceName)
let delegate = DaemonListenerDelegate()
listener.delegate = delegate
listener.resume()

RunLoop.main.run()
