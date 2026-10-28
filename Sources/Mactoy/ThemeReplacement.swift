import Foundation
import MactoyKit

/// What to do when a theme is about to take the place of what a drive uses now.
/// Kept apart from the view so the decisions can be tested.
@MainActor
enum ThemeReplacement {
    enum Step: Equatable {
        /// Nothing the user would miss: the default theme, or one Mactoy can download again.
        case applyNow
        /// The user's own theme setting, with no theme Mactoy can keep: ask before replacing it.
        case confirm(file: String)
        /// A theme Mactoy can't download again: offer to keep a copy first.
        case offerSave(DriveTheme)
    }

    /// `isSavable` is `ThemeStore.isSavable(driveTheme)`; it is passed in so
    /// the choice stays a plain function of what was read from the drive.
    nonisolated static func step(current: ThemeInstaller.Current?, driveTheme: DriveTheme?, isSavable: Bool) -> Step {
        if isSavable, let driveTheme { return .offerSave(driveTheme) }
        // A theme setting of the user's that can't be kept (settings only, or a theme
        // file that is missing or unsafe to read) still gets a question before it goes.
        if case .other(let file) = current { return .confirm(file: file) }
        return .applyNow
    }

    enum Answer: Equatable {
        case saveAndReplace
        case replaceWithoutSaving
    }

    /// Wraps the failure of the save step, so the caller can tell "the drive was
    /// left alone" from "the theme was saved but the drive couldn't be changed".
    struct SaveFailed: Error {
        let underlying: any Error
    }

    /// Saves first when asked, and changes the drive only if that worked: a
    /// theme that couldn't be kept must not be replaced.
    static func perform(_ answer: Answer, save: () async throws -> Void, apply: () async throws -> Void) async throws {
        if answer == .saveAndReplace {
            do { try await save() } catch { throw SaveFailed(underlying: error) }
        }
        try await apply()
    }
}
