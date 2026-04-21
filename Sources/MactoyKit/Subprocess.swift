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

        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() > deadline {
                    process.terminate()
                    throw DriverError.subprocess(path, -1, "timeout after \(timeout)s")
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        } else {
            process.waitUntilExit()
        }

        let outData = try outPipe.fileHandleForReading.readToEnd() ?? Data()
        let errData = try errPipe.fileHandleForReading.readToEnd() ?? Data()
        return SubprocessResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
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
