import Foundation

public struct SubprocessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum Subprocess {
    @discardableResult
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval? = nil) throws -> SubprocessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
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
