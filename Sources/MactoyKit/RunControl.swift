import Foundation

/// Lets the user stop a run while it's safe to (#21).
///
/// A driver calls `check` at points where stopping is fine, and `commit` just before work that
/// mustn't be interrupted. After `commit`, `requestCancel` is refused: stopping a Ventoy
/// install between its partition writes would leave a drive that neither boots nor mounts.
/// Flash image never commits, since a partly flashed drive is no worse than any other to
/// flash again, and the app asks the user before stopping it.
///
/// A flag rather than Swift task cancellation: `Task.sleep` and other awaits inside the
/// drivers would throw at unsafe points if the task itself were cancelled.
public final class RunControl: @unchecked Sendable {
    /// What a stopped run says, by where it stopped. The app tells a cancelled run from a failed
    /// one by these, not by whether Cancel was pressed: a real failure can arrive while a
    /// cancel is still on its way to the helper.
    public static let stoppedBeforeWriting = "Cancelled. Nothing was written to the drive."
    public static let stoppedWhileWriting = "Stopped while writing. The drive is only partly written and won't start until you flash it or install Ventoy on it again."
    public static let stoppedWhileChecking = "Stopped while checking. The image was written in full, but Mactoy didn't finish reading it back."
    public static let stopMessages = [stoppedBeforeWriting, stoppedWhileWriting, stoppedWhileChecking]

    private let lock = NSLock()
    private var cancelled = false
    private var committed = false

    public init() {}

    /// Asks the run to stop. Returns false when it has passed the point where that's safe.
    @discardableResult
    public func requestCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !committed else { return false }
        cancelled = true
        return true
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Throws `DriverError.stopped(message)` if the user asked to stop.
    public func check(_ message: @autoclosure () -> String) throws {
        if isCancelled { throw DriverError.stopped(message()) }
    }

    /// From here on the run can't be stopped. Throws if the user asked to stop before this.
    public func commit(_ message: @autoclosure () -> String) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw DriverError.stopped(message()) }
        committed = true
    }
}
