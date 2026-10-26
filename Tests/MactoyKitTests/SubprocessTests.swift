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
}
