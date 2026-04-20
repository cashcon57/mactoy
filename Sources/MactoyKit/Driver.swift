import Foundation

public enum DriverError: Error, CustomStringConvertible {
    case validation(String)
    case diskIO(String)
    case subprocess(String, Int32, String)
    case network(String)
    case cancelled
    case unsupportedSource(String)
    case corruptPayload(String)

    public var description: String {
        switch self {
        case .validation(let m): return "Validation error: \(m)"
        case .diskIO(let m):     return "Disk I/O error: \(m)"
        case .subprocess(let cmd, let code, let err):
            return "Subprocess \(cmd) failed (exit \(code)): \(err)"
        case .network(let m):    return "Network error: \(m)"
        case .cancelled:         return "Operation cancelled"
        case .unsupportedSource(let m): return "Unsupported source: \(m)"
        case .corruptPayload(let m):    return "Corrupt payload: \(m)"
        }
    }
}

public protocol InstallDriver: Sendable {
    var id: DriverID { get }
    var displayName: String { get }
    func execute(plan: InstallPlan, progress: ProgressSink) async throws
}
