import Foundation
import MactoyKit

/// Runs the bundled `mactoyd` helper binary with admin privileges via osascript.
/// Pipes the JSON-encoded plan to stdin; parses NDJSON progress from stdout.
enum HelperInvoker {

    enum HelperError: Error, CustomStringConvertible {
        case helperNotFound
        case scriptFailed(Int32, String)
        case cancelledByUser

        var description: String {
            switch self {
            case .helperNotFound:
                return "mactoyd helper binary not found next to Mactoy app. Reinstall Mactoy or see docs/INSTALL.md."
            case .scriptFailed(let code, let msg):
                return "Helper exited with code \(code): \(msg)"
            case .cancelledByUser:
                return "Authentication cancelled"
            }
        }
    }

    /// Locate the bundled mactoyd binary.
    /// Search order:
    ///   1. Mactoy.app/Contents/Resources/mactoyd       (bundled in .app)
    ///   2. Mactoy.app/Contents/MacOS/mactoyd           (alternate)
    ///   3. Same directory as current executable        (SPM `swift run`)
    static func locateHelper() -> URL? {
        // 1) Inside .app bundle resources
        if let res = Bundle.main.url(forResource: "mactoyd", withExtension: nil) {
            if FileManager.default.isExecutableFile(atPath: res.path) {
                return res
            }
        }
        // 2) Alongside main executable
        if let exe = Bundle.main.executableURL {
            let sibling = exe.deletingLastPathComponent().appendingPathComponent("mactoyd")
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        }
        // 3) CWD (development)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/mactoyd")
        if FileManager.default.isExecutableFile(atPath: cwd.path) {
            return cwd
        }
        return nil
    }

    static func run(
        plan: InstallPlan,
        onUpdate: @escaping @MainActor (ProgressUpdate) -> Void
    ) async throws {
        guard let helper = locateHelper() else {
            throw HelperError.helperNotFound
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let planData = try encoder.encode(plan)

        // Write plan to a temp file. Our osascript admin call invokes:
        //   /bin/sh -c 'cat /tmp/plan.json | /path/to/mactoyd'
        // which lets us pipe stdin via admin shell while capturing stdout.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-plan-\(UUID().uuidString.prefix(8)).json")
        try planData.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-stdout-\(UUID().uuidString.prefix(8)).ndjson")
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outFile) }

        // The osascript 'do shell script' with admin privs runs a single shell command.
        // We shell-quote each path.
        let shellCmd =
        "/bin/cat \(shellQuote(tmp.path)) | \(shellQuote(helper.path)) > \(shellQuote(outFile.path)) 2>&1"

        let appleScript = """
        do shell script "\(shellCmd.replacingOccurrences(of: "\"", with: "\\\""))" with administrator privileges
        """

        // Tail the output file for progress updates while osascript runs.
        let tailTask = Task<Void, Never> {
            let tailer = NDJSONTailer(path: outFile.path)
            await tailer.tail { update in
                Task { @MainActor in onUpdate(update) }
            }
        }

        do {
            try await runOsascript(source: appleScript)
        } catch {
            tailTask.cancel()
            throw error
        }

        // give the tailer a moment to flush
        try? await Task.sleep(nanoseconds: 300_000_000)
        tailTask.cancel()
    }

    private static func runOsascript(source: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    if err.contains("User canceled") || err.contains("(-128)") {
                        cont.resume(throwing: HelperError.cancelledByUser)
                    } else {
                        cont.resume(throwing: HelperError.scriptFailed(proc.terminationStatus, err))
                    }
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Tails an NDJSON file, decoding each line into a ProgressUpdate and invoking
/// the callback. Polls the file size; exits on Task cancellation.
actor NDJSONTailer {
    let path: String
    private var offset: UInt64 = 0
    private var buffer = Data()
    private let decoder: JSONDecoder

    init(path: String) {
        self.path = path
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
    }

    func tail(onUpdate: @escaping (ProgressUpdate) -> Void) async {
        while !Task.isCancelled {
            await readChunk(onUpdate: onUpdate)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func readChunk(onUpdate: @escaping (ProgressUpdate) -> Void) async {
        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: offset)
        if let data = try? fh.readToEnd(), !data.isEmpty {
            offset += UInt64(data.count)
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !line.isEmpty else { continue }
                if let update = try? decoder.decode(ProgressUpdate.self, from: line) {
                    onUpdate(update)
                }
            }
        }
    }
}
