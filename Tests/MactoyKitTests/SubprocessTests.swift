import Testing
import Foundation
@testable import MactoyKit

@Suite("Subprocess")
struct SubprocessTests {
    /// Before v0.6.0, run() waited for exit before reading, so any output
    /// over the 64 KiB pipe buffer deadlocked forever.
    @Test("output larger than the pipe buffer is read in full")
    func largeOutput() throws {
        let r = try Subprocess.run("/usr/bin/jot", ["-b", "x", "100000"], timeout: 20)   // 200,000 bytes
        #expect(r.status == 0)
        #expect(r.stdout.utf8.count == 200_000)
    }

    @Test("a command that runs too long is stopped and reported")
    func timeout() {
        let start = Date()
        #expect(throws: DriverError.self) { try Subprocess.run("/bin/sleep", ["30"], timeout: 0.5) }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("stderr and the exit status come through")
    func stderrAndStatus() throws {
        let r = try Subprocess.run("/bin/ls", ["/nonexistent-mactoy-path"], timeout: 10)
        #expect(r.status != 0)
        #expect(!r.stderr.isEmpty)
    }

    // MARK: many callers blocked at once

    /// What one `run` call came back with, collected from many threads.
    private struct Outcome: Sendable {
        let status: Int32?
        let stdoutBytes: Int
        let error: String?
    }

    private final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Outcome] = []
        func add(_ o: Outcome) { lock.lock(); items.append(o); lock.unlock() }
        var all: [Outcome] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// One call that prints 80,000 bytes, well over the 64 KiB pipe buffer, so
    /// the child blocks on write until a reader drains the pipe. The timeout
    /// is only a backstop so a starved reader fails the test instead of
    /// hanging it.
    private static func printBigOutput() -> Outcome {
        do {
            let r = try Subprocess.run("/usr/bin/jot", ["-b", "x", "40000"], timeout: 50)
            return Outcome(status: r.status, stdoutBytes: r.stdout.utf8.count, error: nil)
        } catch {
            return Outcome(status: nil, stdoutBytes: 0, error: "\(error)")
        }
    }

    private static func expectAllComplete(_ outcomes: [Outcome], expected: Int, elapsed: TimeInterval) {
        #expect(outcomes.count == expected)
        let errors = outcomes.compactMap(\.error)
        #expect(errors.isEmpty, "\(errors.count) failed, first: \(errors.first ?? "")")
        #expect(outcomes.allSatisfy { $0.status == 0 && $0.stdoutBytes == 80_000 })
        #expect(elapsed < 60)
    }

    /// Callers block their own thread in run(). If the pipe readers needed a
    /// pool thread too, as many blocked callers as the pool has threads would
    /// leave none for them: the child never exits, or run() gives up with
    /// "output not closed 10s after exit".
    @Test("48 concurrent calls from dispatch threads all finish with their full output")
    func concurrentPerform() {
        let outcomes = Outcomes()
        let start = Date()
        DispatchQueue.concurrentPerform(iterations: 48) { _ in
            outcomes.add(Self.printBigOutput())
        }
        Self.expectAllComplete(outcomes.all, expected: 48, elapsed: Date().timeIntervalSince(start))
    }

    @Test("48 concurrent calls from async tasks all finish with their full output")
    func taskGroup() async {
        let start = Date()
        let outcomes = await withTaskGroup(of: Outcome.self) { group in
            for _ in 0..<48 { group.addTask { Self.printBigOutput() } }
            var all: [Outcome] = []
            for await o in group { all.append(o) }
            return all
        }
        Self.expectAllComplete(outcomes, expected: 48, elapsed: Date().timeIntervalSince(start))
    }
}
