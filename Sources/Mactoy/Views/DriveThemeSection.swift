import SwiftUI
import MactoyKit

/// What the drive says about its theme right now.
struct DriveThemeSnapshot: Equatable, Sendable {
    var current: ThemeInstaller.Current?
    var readOnly: Bool
    /// Why the drive's settings couldn't be read (a damaged ventoy.json, say).
    var error: String?
    /// The theme on the drive, when there is one Mactoy can keep a copy of.
    var driveTheme: DriveTheme?
}

/// Does the file reads, so none of it happens in `body` or on the main thread.
enum DriveThemeReader {
    static func read(_ volume: URL) -> DriveThemeSnapshot {
        let readOnly = ThemeInstaller.isReadOnly(volume)
        do {
            let current = try ThemeInstaller.current(on: volume)
            // `current` just read the same ventoy.json, so a failure here is a race with
            // the drive changing; it only means there is nothing to offer to keep.
            let theme = current == .ventoyDefault ? nil : try? ThemeInstaller.driveTheme(on: volume)
            return DriveThemeSnapshot(current: current, readOnly: readOnly, error: nil, driveTheme: theme)
        } catch {
            // Not "Ventoy default": that would hide a ventoy.json Mactoy can't read.
            return DriveThemeSnapshot(current: nil, readOnly: readOnly, error: error.localizedDescription, driveTheme: nil)
        }
    }
}

/// The section's wording, kept out of the view so tests can read it.
enum DriveThemeCopy {
    /// `file` is empty when the drive's `theme` setting names no theme file.
    static func ownTheme(file: String) -> String {
        file.isEmpty ? "Your own theme settings" : "Your own theme (\(file))"
    }

    static let replaceTitle = "Replace your own theme?"

    /// For a theme of the user's that Mactoy can't keep a copy of.
    static func replaceMessage(file: String, toDefault: Bool) -> String {
        if file.isEmpty {
            return toDefault
                ? "This drive has theme settings you set up yourself. Mactoy will remove them and switch the drive back to Ventoy's own theme."
                : "This drive has theme settings you set up yourself. Mactoy will replace them with the new theme."
        }
        let action = toDefault
            ? "Mactoy will switch the drive back to Ventoy's own theme."
            : "Mactoy will point the drive at the new theme instead."
        let fate = mactoyFolder(of: file).map {
            "The theme folder Mactoy added (\($0)) will be removed. You can download or pick it again later."
        } ?? "Your theme's files stay on the drive."
        return "This drive uses a theme you set up yourself (\(file)). \(action) \(fate)"
    }

    /// The `mactoy-<id>` folder a theme file is in, when it is under `/ventoy/themes/mactoy-`.
    /// A theme setting edited by hand can still point into a folder Mactoy added, and
    /// changing the theme deletes that folder, so the user's "files stay" does not hold.
    /// (The drive is exFAT, which ignores case, so the folder names are compared that way.)
    static func mactoyFolder(of file: String) -> String? {
        let parts = file.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0].lowercased() == "ventoy", parts[1].lowercased() == "themes",
              parts[2].lowercased().hasPrefix(ThemeInstaller.managedPrefix) else { return nil }
        return String(parts[2])
    }

    static let keepCopyTitle = "Keep a copy of this drive's theme?"

    static func keepCopyMessage(name: String) -> String {
        "This drive uses “\(name)”, which isn't in Mactoy's theme list. Save it to My Themes first so you can put it back later."
    }

    static let saveButton = "Save to My Themes"
    static let saveHint = "Keeps a copy on this Mac so you can put this theme back later."

    static func saved(name: String) -> String { "Saved “\(name)” to My Themes." }

    /// The save failed, so the drive was not touched.
    static func saveFailed(_ reason: String) -> String {
        "Couldn't save this drive's theme to My Themes, so the drive was left as it was. \(reason)"
    }

    /// The copy is safe in My Themes, and the drive keeps its old theme because the new one can't be downloaded
    /// (the alert says why).
    static func savedButUnchanged(name: String) -> String {
        "\(saved(name: name)) The drive's theme wasn't changed."
    }

    /// The copy is safe in My Themes, but the drive still has its old theme.
    static func changeFailed(savedName: String?, reason: String) -> String {
        guard let savedName else { return reason }
        return "\(saved(name: savedName)) The drive's theme wasn't changed: \(reason)"
    }

    static func success(removed: Bool) -> String {
        removed
            ? "Theme removed. The drive will show Ventoy's own menu next time you boot from it."
            : "Theme updated. It will show the next time you boot from this drive."
    }
}

struct DriveThemeSection: View {
    @EnvironmentObject private var themes: ThemeStore
    let volumeURL: URL
    @State private var current: ThemeInstaller.Current?
    @State private var driveTheme: DriveTheme?
    @State private var readOnly = false
    @State private var readError: String?
    @State private var showPicker = false
    /// Set by the picker; acted on once the sheet is gone, so the
    /// confirmation below never opens while the sheet is still closing.
    @State private var picked: ThemeChoice?
    @State private var pendingReplace: PendingReplace?
    /// A catalog theme that couldn't be used: the alert that says so and offers the ways forward.
    @State private var unavailableAlert: UnavailableAlert?
    /// Where the picker opens when it isn't on the drive's current theme: on a theme just added from a file.
    @State private var pickerStart: ThemeChoice?
    /// A theme file is being added (from the alert's button).
    @State private var importing = false
    /// A file that held several themes, while the user chooses one.
    @State private var pendingChoice: PendingThemeChoice?
    @State private var working = false
    /// Keeping a copy of the drive's theme (the standalone button). The drive isn't changed.
    @State private var saving = false
    @State private var message: String?
    @State private var isError = false
    /// A read that finishes after a newer one started is dropped, so a slow
    /// first read can't bring back a theme that was just changed.
    @State private var generation = 0

    private struct UnavailableAlert {
        let entry: ThemeEntry
        let problem: ThemeUnavailable
    }

    private struct PendingReplace: Identifiable {
        enum Kind {
            /// A theme Mactoy can keep a copy of.
            case offerSave(DriveTheme)
            /// A theme setting of the user's with nothing to keep.
            case confirm(file: String)
        }
        let id = UUID()
        let choice: ThemeChoice
        let kind: Kind

        var title: String {
            switch kind {
            case .offerSave: return DriveThemeCopy.keepCopyTitle
            case .confirm: return DriveThemeCopy.replaceTitle
            }
        }

        var message: String {
            switch kind {
            case .offerSave(let theme): return DriveThemeCopy.keepCopyMessage(name: theme.name)
            case .confirm(let file): return DriveThemeCopy.replaceMessage(file: file, toDefault: choice == .ventoyDefault)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Boot menu theme").font(.headline)
                Spacer()
                if working { ProgressView().controlSize(.small); Text("Changing the theme…").font(.callout) }
                if importing { ProgressView().controlSize(.small); Text("Adding theme…").font(.callout) }
                Button("Change Theme…") { showPicker = true }
                    .disabled(working || saving || importing || readOnly || current == nil)
            }
            // A confirmation dialog, not an alert: on macOS an alert shows only three buttons, and this has four.
            // It hangs on this row so it doesn't compete with the other dialog on the section.
            .confirmationDialog(
                unavailableAlert.map { ThemeUnavailableCopy.title(name: $0.entry.name) } ?? "",
                isPresented: Binding(get: { unavailableAlert != nil }, set: { if !$0 { unavailableAlert = nil } }),
                titleVisibility: .visible,
                presenting: unavailableAlert
            ) { shown in
                Button(ThemeUnavailableCopy.reportButton) { ThemeUnavailableActions.report(shown.entry, shown.problem) }
                Button(ThemeUnavailableCopy.pageButton) { ThemeUnavailableActions.openPage(of: shown.entry) }
                Button(ThemeUnavailableCopy.fileButton) { Task { await addThemeFromFile() } }
                // Return closes the dialog; nothing it offers happens by accident.
                Button(ThemeUnavailableCopy.okButton, role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: { shown in
                Text(ThemeUnavailableCopy.message(for: shown.problem))
            }
            // On this row and not on the section, which already presents the picker's sheet.
            .sheet(item: $pendingChoice) { pending in
                ThemeChoiceSheet(pending: pending, onChoose: { choice in Task { await addChosen(choice, from: pending) } },
                                 onCancel: { pendingChoice = nil })
            }
            Text(currentText).font(.callout).foregroundStyle(readError == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
            if readError == nil, themes.isSavable(driveTheme) {
                // Reads the drive and writes to this Mac only, so it works on a read-only drive too.
                HStack(spacing: 8) {
                    Button(DriveThemeCopy.saveButton) { Task { await saveToMyThemes() } }
                        .controlSize(.small)
                        .disabled(working || saving)
                    if saving {
                        ProgressView().controlSize(.small)
                        Text("Saving…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(DriveThemeCopy.saveHint).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if readOnly {
                Text("This drive is read-only on this Mac, so its theme can't be changed here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mactoyGlass(cornerRadius: 16)
        .task(id: volumeURL) { await refresh() }
        .sheet(isPresented: $showPicker, onDismiss: {
            pickerStart = nil
            guard let choice = picked else { return }
            picked = nil
            Task { await choose(choice) }
        }) {
            ThemePickerSheet(initial: pickerStart ?? initialChoice, confirmTitle: "Apply to Drive") { picked = $0 }
                .environmentObject(themes)
        }
        .confirmationDialog(
            pendingReplace?.title ?? "",
            isPresented: Binding(get: { pendingReplace != nil }, set: { if !$0 { pendingReplace = nil } }),
            titleVisibility: .visible,
            presenting: pendingReplace
        ) { pending in
            switch pending.kind {
            case .offerSave:
                // Return keeps a copy: the safe answer is the default one.
                Button("Save to My Themes and Replace") { Task { await replace(pending.choice, answer: .saveAndReplace) } }
                    .keyboardShortcut(.defaultAction)
                Button("Replace Without Saving") { Task { await replace(pending.choice, answer: .replaceWithoutSaving) } }
                Button("Cancel", role: .cancel) {}
            case .confirm:
                Button("Replace") { Task { await replace(pending.choice, answer: .replaceWithoutSaving) } }
                // Return picks Cancel, so a double Return can't replace a theme nobody read about.
                Button("Cancel", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            }
        } message: { pending in
            Text(pending.message)
        }
    }

    private var currentText: String {
        if let readError { return "Couldn't read this drive's settings: \(readError)" }
        switch current {
        case nil: return "Reading the drive's settings…"
        case .ventoyDefault: return "Ventoy default"
        case .managed(_, let name): return name
        case .other(let file): return DriveThemeCopy.ownTheme(file: file)
        }
    }

    private var initialChoice: ThemeChoice {
        if case .managed(let id, _) = current {
            if themes.catalog.contains(where: { $0.id == id }) { return .catalog(id: id) }
            if themes.savedThemes.contains(where: { $0.id == id }) { return .custom(id: id) }
        }
        return .ventoyDefault
    }

    /// Reads the drive, shows what it found, and returns it.
    @discardableResult
    private func refresh() async -> DriveThemeSnapshot {
        generation += 1
        let mine = generation
        let volume = volumeURL
        let snapshot = await Task.detached(priority: .userInitiated) { DriveThemeReader.read(volume) }.value
        if mine == generation {
            current = snapshot.current
            driveTheme = snapshot.driveTheme
            readOnly = snapshot.readOnly
            readError = snapshot.error
        }
        return snapshot
    }

    /// The picker's answer. A theme that would be lost is only replaced after
    /// the user says so, and Mactoy offers to keep a copy of it first.
    private func choose(_ choice: ThemeChoice) async {
        working = true
        message = nil
        // Read again: the drive may have been edited since this section loaded.
        let snapshot = await refresh()
        if let error = snapshot.error {
            working = false
            isError = true
            message = "Couldn't read this drive's settings: \(error)"
            return
        }
        switch ThemeReplacement.step(current: snapshot.current, driveTheme: snapshot.driveTheme,
                                     isSavable: themes.isSavable(snapshot.driveTheme)) {
        case .applyNow:
            await replace(choice, answer: .replaceWithoutSaving)
        case .confirm(let file):
            working = false
            pendingReplace = PendingReplace(choice: choice, kind: .confirm(file: file))
        case .offerSave(let theme):
            working = false
            pendingReplace = PendingReplace(choice: choice, kind: .offerSave(theme))
        }
    }

    /// Changes the drive, after keeping a copy of its theme if that was asked
    /// for. A copy that can't be made stops the change.
    private func replace(_ choice: ThemeChoice, answer: ThemeReplacement.Answer) async {
        working = true
        message = nil
        var savedName: String?
        var warnings: [String] = []
        do {
            try await ThemeReplacement.perform(answer, save: { savedName = try await saveDriveTheme().name },
                                               apply: { warnings = try await themes.apply(choice, to: volumeURL) })
            isError = false
            let saved = savedName.map { [DriveThemeCopy.saved(name: $0)] } ?? []
            message = (saved + [DriveThemeCopy.success(removed: choice == .ventoyDefault)] + warnings).joined(separator: " ")
        } catch let failure as ThemeReplacement.SaveFailed {
            isError = true
            message = DriveThemeCopy.saveFailed(failure.underlying.localizedDescription)
        } catch {
            if case .catalog(let id) = choice, let entry = themes.catalog.first(where: { $0.id == id }),
               let problem = ThemeUnavailable(error: error, entry: entry) {
                // The alert says what happened and what to do, so there is no red text as well.
                isError = false
                message = savedName.map { DriveThemeCopy.savedButUnchanged(name: $0) }
                unavailableAlert = UnavailableAlert(entry: entry, problem: problem)
            } else {
                isError = true
                message = DriveThemeCopy.changeFailed(savedName: savedName, reason: themes.message(for: error, choice: choice))
            }
        }
        await refresh()
        working = false
    }

    /// The alert's third button: add the theme from a ZIP file or folder, then open the picker on it.
    private func addThemeFromFile() async {
        guard let url = ThemeUnavailableActions.chooseThemeFile() else { return }
        importing = true
        message = nil
        defer { importing = false }
        do {
            switch try await themes.startImport(from: url) {
            case .imported(let choice):
                pickerStart = choice
                showPicker = true
            case .needsChoice(let pending):
                pendingChoice = pending
            }
        } catch {
            isError = true
            message = "Couldn't add that theme: \(error.localizedDescription)"
        }
    }

    /// Adds the theme picked from a file that held several, then opens the picker on it.
    private func addChosen(_ choice: CustomThemeImporter.Choice, from pending: PendingThemeChoice) async {
        pendingChoice = nil
        importing = true
        message = nil
        defer { importing = false }
        do {
            pickerStart = try await themes.finishImport(pending, choosing: choice)
            showPicker = true
        } catch {
            isError = true
            message = "Couldn't add that theme: \(error.localizedDescription)"
        }
    }

    /// The standalone button. Never changes the drive.
    private func saveToMyThemes() async {
        saving = true
        message = nil
        do {
            isError = false
            message = DriveThemeCopy.saved(name: try await saveDriveTheme().name)
        } catch {
            isError = true
            message = error.localizedDescription
        }
        await refresh()
        saving = false
    }

    private func saveDriveTheme() async throws -> SavedTheme {
        guard let saved = try await themes.saveDriveTheme(on: volumeURL) else { throw ThemeStoreError.nothingToSave }
        return saved
    }
}
