import Foundation
import MactoyKit

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

/// Receives progress callbacks from the daemon over XPC and forwards
/// them to the app via the @MainActor closure supplied by `run`.
final class ProgressForwarder: NSObject, MactoyClientProtocol, @unchecked Sendable {
    private let callback: (ProgressUpdate) -> Void
    private let decoder: JSONDecoder

    init(callback: @escaping (ProgressUpdate) -> Void) {
        self.callback = callback
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
    }

    func receiveProgress(_ updateData: Data) {
        guard let update = try? decoder.decode(ProgressUpdate.self, from: updateData) else { return }
        callback(update)
    }
}
