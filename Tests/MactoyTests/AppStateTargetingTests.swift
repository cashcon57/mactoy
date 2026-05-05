import Testing
import Foundation
@testable import Mactoy
import MactoyKit

/// Tests for the iron-clad targeting defense in `AppState`. These cover
/// the gaps the v0.3.1 post-mortem named: Layer 2 (selection freeze)
/// and Layer 6 (BSD-name guard at execution).
///
/// Layers 4 and 5 (DiskInfo.probe-based reverification) need
/// dependency injection on `DiskInfo` / `Subprocess` to be testable —
/// that's the v0.4 work item.
@MainActor
@Suite("AppState targeting (Layer 2 + Layer 6 from issue #1 fix)")
struct AppStateTargetingTests {

    private func disk(_ bsd: String, size: UInt64 = 100_000_000_000) -> DiskTarget {
        DiskTarget(
            bsdName: bsd,
            sizeInBytes: size,
            isExternal: true,
            isRemovable: true,
            mediaName: "Test Disk \(bsd)",
            volumes: []
        )
    }

    private func confirmation(for d: DiskTarget) -> EraseConfirmation {
        EraseConfirmation(
            mode: .installVentoy,
            disk: d,
            usedBytes: nil,
            totalBytes: d.sizeInBytes
        )
    }

    // MARK: Layer 2 — selection freeze

    @Test("baseline: applyDiskList DOES change selectedDiskBSD when no confirmation is pending")
    func freezeBaseline() {
        let state = AppState()
        let d5 = disk("disk5")
        let d6 = disk("disk6")
        state.disks = [d5, d6]
        state.selectedDiskBSD = "disk5"
        state.pendingEraseConfirmation = nil

        // Simulate disk5 disappearing (USB hub hiccup).
        state.applyDiskList([d6])

        // Without the freeze, snap-to-first behavior should kick in.
        #expect(state.selectedDiskBSD == "disk6")
    }

    @Test("Layer 2: applyDiskList does NOT change selectedDiskBSD while a confirmation is pending — the original wrong-disk wipe scenario")
    func freezeHoldsDuringConfirmation() {
        let state = AppState()
        let d5 = disk("disk5")
        let d6 = disk("disk6")
        state.disks = [d5, d6]
        state.selectedDiskBSD = "disk5"
        // User has clicked Install; confirmation sheet is open.
        state.pendingEraseConfirmation = confirmation(for: d5)

        // Now the disk poll fires and disk5 momentarily drops off the
        // bus. WITHOUT the freeze, applyDiskList would clear
        // selectedDiskBSD and snap to disk6 — which is the exact race
        // that caused the v0.3.0 wrong-disk wipe.
        state.applyDiskList([d6])

        #expect(state.selectedDiskBSD == "disk5",
                "Selection must NOT change while a confirmation sheet is open")
    }

    @Test("Layer 2: freeze releases after the confirmation is cleared (cancel path)")
    func freezeReleasesAfterCancel() {
        let state = AppState()
        let d5 = disk("disk5")
        let d6 = disk("disk6")
        state.disks = [d5, d6]
        state.selectedDiskBSD = "disk5"
        state.pendingEraseConfirmation = confirmation(for: d5)

        // User cancels the confirmation.
        state.cancelRun()
        #expect(state.pendingEraseConfirmation == nil)

        // Disk poll fires — selection should now be allowed to update.
        state.applyDiskList([d6])
        #expect(state.selectedDiskBSD == "disk6")
    }

    @Test("Layer 2: even the disks list still updates while frozen — only selection is held")
    func diskListStillUpdatesWhileFrozen() {
        let state = AppState()
        let d5 = disk("disk5")
        let d6 = disk("disk6")
        let d7 = disk("disk7")
        state.disks = [d5]
        state.selectedDiskBSD = "disk5"
        state.pendingEraseConfirmation = confirmation(for: d5)

        // A new disk gets plugged in mid-confirmation.
        state.applyDiskList([d5, d6, d7])

        #expect(state.selectedDiskBSD == "disk5", "Selection still held")
        #expect(state.disks.map(\.bsdName) == ["disk5", "disk6", "disk7"], "Disk list updated")
    }

    // MARK: Layer 6 — BSD-name guard at execution

    @Test("Layer 6: run() refuses when selectedDiskBSD differs from confirmedTarget.bsdName")
    func bsdNameGuardCatchesDrift() async {
        let state = AppState()
        let d5 = disk("disk5")
        // Simulate: somehow (despite Layer 2's freeze) the selection
        // has drifted to disk6 by the time run() is called. Layer 6
        // must catch this regardless of how the drift happened.
        state.disks = [d5, disk("disk6")]
        state.selectedDiskBSD = "disk6"  // drifted

        await state.run(confirmedTarget: d5, confirmedMode: .installVentoy)

        // Status should be .failed with a "selection drifted" message.
        // No DiskInfo.probe is called because the guard returns before
        // the probe step.
        if case .failed(let message) = state.status {
            #expect(message.contains("selected disk changed") || message.contains("drift"),
                    "Failure message should explain the drift")
            #expect(message.contains("disk5") && message.contains("disk6"),
                    "Failure message should name both BSD names")
        } else {
            Issue.record("Expected status to be .failed; got \(state.status)")
        }
    }

    @Test("Layer 6: run() proceeds past the BSD guard when names match (probe failure is a different layer)")
    func bsdNameGuardLetsMatchingNamesPast() async {
        // We can't go further into run() without DiskInfo mocking — at
        // some point the live DiskInfo.probe call fires for a fake
        // BSD name and throws. But the BSD guard itself is at the top
        // of run() before any probe, so this test confirms it does NOT
        // short-circuit when names match. The .failed status will come
        // from the probe layer, with a different message.
        let state = AppState()
        let d5 = disk("disk5")
        state.disks = [d5]
        state.selectedDiskBSD = "disk5"

        await state.run(confirmedTarget: d5, confirmedMode: .installVentoy)

        // Whatever the failure mode is, it should NOT be the "selection
        // changed between confirmation and execution" one — that's the
        // Layer 6 short-circuit, and we matched on BSD names so it
        // shouldn't fire.
        if case .failed(let message) = state.status {
            #expect(!message.contains("selected disk changed"),
                    "Layer 6 should not have fired with matching BSD names; message was: \(message)")
        }
        // .preparing or .failed are both acceptable here — the test is
        // only that the BSD guard wasn't the one that stopped us.
    }
}
