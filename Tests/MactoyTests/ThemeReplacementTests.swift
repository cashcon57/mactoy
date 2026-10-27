import Testing
import Foundation
@testable import Mactoy
import MactoyKit

/// What happens to a drive's theme when another one is chosen: the decision
/// the dialog follows, and the save-then-replace order behind its buttons.
@MainActor
@Suite("Theme replacement")
struct ThemeReplacementTests {

    private let theme = DriveTheme(folder: URL(fileURLWithPath: "/Volumes/Ventoy/ventoy/mine"), name: "Mine",
                                   settings: .init(file: "theme.txt"), managedID: nil)

    // MARK: the decision

    @Test("a drive on Ventoy's own theme, or one Mactoy can download again, is changed without asking")
    func appliesDirectly() {
        #expect(ThemeReplacement.step(current: .ventoyDefault, driveTheme: nil, isSavable: false) == .applyNow)
        #expect(ThemeReplacement.step(current: .managed(id: "catppuccin-mocha", name: "Catppuccin Mocha"), driveTheme: theme, isSavable: false) == .applyNow)
        // Nothing read from the drive at all.
        #expect(ThemeReplacement.step(current: nil, driveTheme: nil, isSavable: false) == .applyNow)
    }

    @Test("a theme that can be kept is offered a copy first, whether the user made it or Mactoy installed it")
    func offersToSave() {
        #expect(ThemeReplacement.step(current: .other(file: "/ventoy/mine/theme.txt"), driveTheme: theme, isSavable: true) == .offerSave(theme))
        #expect(ThemeReplacement.step(current: .managed(id: "custom-old-12345678", name: "Old"), driveTheme: theme, isSavable: true) == .offerSave(theme))
    }

    @Test("the user's own settings with nothing to keep still get a question")
    func confirmsSettingsOnly() {
        #expect(ThemeReplacement.step(current: .other(file: ""), driveTheme: nil, isSavable: false) == .confirm(file: ""))
        // A theme file Mactoy can't read safely (a link, or outside the drive) can't be kept either.
        #expect(ThemeReplacement.step(current: .other(file: "/ventoy/link/theme.txt"), driveTheme: nil, isSavable: false)
                == .confirm(file: "/ventoy/link/theme.txt"))
    }

    // MARK: the order

    private struct Boom: Error, Equatable {}

    /// Records what ran, in order.
    private final class Calls {
        var log: [String] = []
    }

    @Test("Save and Replace keeps the copy, then changes the drive")
    func savesThenApplies() async throws {
        let calls = Calls()
        try await ThemeReplacement.perform(.saveAndReplace, save: { calls.log.append("save") }, apply: { calls.log.append("apply") })
        #expect(calls.log == ["save", "apply"])
    }

    @Test("a copy that can't be saved stops the change, and says which step failed")
    func failedSaveDoesNotApply() async {
        let calls = Calls()
        do {
            try await ThemeReplacement.perform(.saveAndReplace, save: { calls.log.append("save"); throw Boom() }, apply: { calls.log.append("apply") })
            Issue.record("expected the save failure to be thrown")
        } catch let failure as ThemeReplacement.SaveFailed {
            #expect(failure.underlying as? Boom == Boom())
        } catch {
            Issue.record("expected SaveFailed, got \(error)")
        }
        #expect(calls.log == ["save"], "the drive was not changed")
    }

    @Test("Replace Without Saving changes the drive and never saves")
    func replacesWithoutSaving() async throws {
        let calls = Calls()
        try await ThemeReplacement.perform(.replaceWithoutSaving, save: { calls.log.append("save") }, apply: { calls.log.append("apply") })
        #expect(calls.log == ["apply"])
    }

    @Test("a change that fails after the copy was saved is reported as the change failing, not the save")
    func failedApplyAfterSave() async {
        let calls = Calls()
        do {
            try await ThemeReplacement.perform(.saveAndReplace, save: { calls.log.append("save") }, apply: { calls.log.append("apply"); throw Boom() })
            Issue.record("expected the change failure to be thrown")
        } catch let error as Boom {
            #expect(error == Boom())
        } catch {
            Issue.record("expected Boom, got \(error)")
        }
        #expect(calls.log == ["save", "apply"])
    }

    @Test("a failed change without saving surfaces its own error")
    func failedApplyWithoutSave() async {
        let calls = Calls()
        await #expect(throws: Boom.self) {
            try await ThemeReplacement.perform(.replaceWithoutSaving, save: { calls.log.append("save") }, apply: { throw Boom() })
        }
        #expect(calls.log.isEmpty)
    }
}
