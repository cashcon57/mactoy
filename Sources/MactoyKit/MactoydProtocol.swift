import Foundation

/// XPC protocol exposed by `mactoyd` to the Mactoy app.
///
/// The daemon runs as root under `launchd` (installed via `SMAppService`),
/// so it does NOT require the user to grant Full Disk Access manually —
/// `launchd`-spawned processes get raw-disk access as part of system scope.
@objc public protocol MactoydProtocol {
    /// Execute an install plan. `planData` is a JSON-encoded `InstallPlan`.
    /// Progress updates are delivered back to the client via the
    /// `exportedInterface` on the connection (see `MactoyClientProtocol`).
    /// `reply` is called once at completion: `success=true` on success,
    /// `false` with a human-readable `errorMessage` on failure.
    func executePlan(_ planData: Data, reply: @escaping (_ success: Bool, _ errorMessage: String?) -> Void)

    /// Probe `bsdName` (e.g. `disk6`) to see whether it has a Ventoy
    /// install. Returns a JSON-encoded `VentoyProbeResult`. Cheap and
    /// read-only; safe to call frequently as the user changes their
    /// disk selection. Always succeeds (an unreadable disk returns a
    /// `VentoyProbeResult` with `isVentoyDisk == false` and a layout
    /// issue describing the failure) — the `errorMessage` reply slot
    /// is reserved for daemon-side encoding failures only.
    func probeVentoy(_ bsdName: String, reply: @escaping (_ resultData: Data?, _ errorMessage: String?) -> Void)

    /// Health-check. Returns the daemon's version string. Cheap way to
    /// confirm the daemon is reachable and the XPC contract matches.
    func ping(reply: @escaping (_ version: String) -> Void)
}

/// Callback interface the daemon uses to send progress updates back to
/// the client. The client sets itself as the `exportedObject` on the
/// connection.
@objc public protocol MactoyClientProtocol {
    /// Delivers a JSON-encoded `ProgressUpdate`.
    func receiveProgress(_ updateData: Data)
}

/// Shared mach-service name. Matches `MachServices` key in the
/// LaunchDaemon plist shipped at
/// `Contents/Library/LaunchDaemons/com.mactoy.mactoyd.plist`.
public let mactoydMachServiceName = "com.mactoy.mactoyd"

public let mactoydVersion = "0.3.0"

