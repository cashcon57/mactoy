import Foundation

public struct SubprocessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum Subprocess {
    /// Minimal environment we hand to child processes. Keeps the helper
    /// from inheriting the user's PATH/LD_*/DYLD_* when running as root.
    /// All call sites pass absolute executable paths so `PATH` only
    /// matters for anything `diskutil`/`tar`/`newfs_exfat` fork internally.
    private static let safeEnv: [String: String] = [
        "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
        "LC_ALL": "C",
        "LANG": "C",
    ]

    @discardableResult
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval? = nil) throws -> SubprocessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = safeEnv
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()

        // Read both pipes while the process runs. Waiting for exit first
        // deadlocks once a command writes more than the pipe buffer
        // (64 KiB): it blocks on write, and we block on its exit.
        // `diskutil apfs list -plist` grows by ~900 bytes per volume.
        //
        // Each pipe gets its own Thread, not a GCD or async task. The calling
        // thread blocks below, so with as many callers blocked at once as GCD
        // has pool threads, a queued reader never starts: the child fills its
        // pipe and sits there until its timeout, or run() gives up on the
        // output. A dedicated thread never waits for a pool thread.
        let outBox = DataBox(), errBox = DataBox()
        let readers = DispatchGroup()
        for (name, pipe, box) in [("stdout", outPipe, outBox), ("stderr", errPipe, errBox)] {
            readers.enter()
            let reader = Thread {
                box.set((try? pipe.fileHandleForReading.readToEnd()) ?? Data())
                readers.leave()
            }
            reader.name = "mactoy.subprocess.\(name)"
            reader.start()
        }

        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() > deadline {
                    process.terminate()
                    // SIGTERM can be ignored; give it a moment, then SIGKILL.
                    Thread.sleep(forTimeInterval: 0.5)
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    // Don't wait on the readers for long: a child the
                    // command spawned could still hold the pipe open.
                    _ = readers.wait(timeout: .now() + 2)
                    throw DriverError.subprocess(path, -1, "timeout after \(timeout)s")
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        } else {
            process.waitUntilExit()
        }
        // The process has exited; its pipes reach EOF unless a child it
        // left behind still holds them. Bounded, for the same reason.
        if readers.wait(timeout: .now() + 10) == .timedOut {
            throw DriverError.subprocess(path, -1, "output not closed 10s after exit")
        }

        return SubprocessResult(
            status: process.terminationStatus,
            stdout: String(data: outBox.get(), encoding: .utf8) ?? "",
            stderr: String(data: errBox.get(), encoding: .utf8) ?? ""
        )
    }

    @discardableResult
    public static func runChecked(_ path: String, _ args: [String], timeout: TimeInterval? = nil) throws -> SubprocessResult {
        let r = try run(path, args, timeout: timeout)
        if r.status != 0 {
            throw DriverError.subprocess("\(path) \(args.joined(separator: " "))", r.status, r.stderr)
        }
        return r
    }
}

/// Hand-off cell for pipe output read on another thread.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
