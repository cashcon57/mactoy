import Testing
@testable import MactoyKit

@Suite("RunControl (#21)")
struct RunControlTests {
    @Test("a cancel before the point of no return stops the run there")
    func cancelBeforeCommit() {
        let c = RunControl()
        #expect(c.requestCancel())
        #expect(throws: DriverError.self) { try c.check("stopped") }
        do {
            try c.commit("Cancelled. Nothing was written.")
            Issue.record("commit should throw after a cancel")
        } catch {
            #expect("\(error)" == "Cancelled. Nothing was written.")
        }
    }

    @Test("after the point of no return, a cancel is refused and the run goes on")
    func cancelAfterCommit() throws {
        let c = RunControl()
        try c.commit("x")
        #expect(!c.requestCancel())
        try c.check("never")
        #expect(!c.isCancelled)
    }

    @Test("nothing happens without a cancel")
    func noCancel() throws {
        let c = RunControl()
        try c.check("never")
        try c.commit("never")
    }
}
