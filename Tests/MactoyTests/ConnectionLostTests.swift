import Testing
@testable import Mactoy

/// #39: a connection that breaks after the plan was sent is never retried by itself.
@MainActor
@Suite("Connection lost mid-run")
struct ConnectionLostTests {
    @Test("a lost connection after sending isn't treated as a missing helper")
    func notALookupFailure() {
        let s = AppState()
        s.timeMachineLookup = { [] }
        let lost = HelperInvoker.HelperError.connectionLost("Error Domain=NSCocoaErrorDomain Code=4099 \"connection invalidated\"")
        #expect(!s.isLookupFailure(lost))
        // Before sending, the same error still means launchd lost the helper.
        #expect(s.isLookupFailure(.xpcUnreachable("Error Domain=NSCocoaErrorDomain Code=4099")))
    }

    @Test("the message says the drive may be partly written and offers Retry")
    func message() {
        let text = HelperInvoker.HelperError.connectionLost("x").localizedDescription
        #expect(text.contains("may be partly written"))
        #expect(text.contains("Retry"))
    }
}
