import SwiftUI
import MactoyKit

/// What the drive says about its theme right now.
struct DriveThemeSnapshot: Equatable, Sendable {
    var current: ThemeInstaller.Current?
    var readOnly: Bool
    /// Why the drive's settings couldn't be read (a damaged ventoy.json, say).
    var error: String?
}

/// Does the file reads, so none of it happens in `body` or on the main thread.
enum DriveThemeReader {
    static func read(_ volume: URL) -> DriveThemeSnapshot {
        let readOnly = ThemeInstaller.isReadOnly(volume)
        do {
            return DriveThemeSnapshot(current: try ThemeInstaller.current(on: volume), readOnly: readOnly, error: nil)
        } catch {
            // Not "Ventoy default": that would hide a ventoy.json Mactoy can't read.
            return DriveThemeSnapshot(current: nil, readOnly: readOnly, error: error.localizedDescription)
        }
    }
}

/// The section's wording, kept out of the view so tests can read it.
enum DriveThemeCopy {
    /// `file` is empty when the drive's `theme` setting names no theme file.
    static func ownTheme(file: String) -> String {
        file.isEmpty ? "Your own theme settings" : "Your own theme (\(file))"
    }

    static func replaceMessage(file: String, toDefault: Bool) -> String {
        let first = file.isEmpty
            ? "This drive has theme settings you set up yourself."
            : "This drive uses a theme you set up yourself (\(file))."
        let action = toDefault
            ? "Mactoy will switch the drive back to Ventoy's own theme."
            : "Mactoy will point the drive at the new theme instead."
        return "\(first) \(action) Your theme's files stay on the drive."
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
    @State private var readOnly = false
    @State private var readError: String?
    @State private var showPicker = false
    /// Set by the picker; acted on once the sheet is gone, so the
    /// confirmation below never opens while the sheet is still closing.
    @State private var picked: ThemeChoice?
    @State private var pendingReplace: PendingReplace?
    @State private var working = false
    @State private var message: String?
    @State private var isError = false
    /// A read that finishes after a newer one started is dropped, so a slow
    /// first read can't bring back a theme that was just changed.
    @State private var generation = 0

    private struct PendingReplace: Identifiable {
        let id = UUID()
        let choice: ThemeChoice
        let file: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Boot menu theme").font(.headline)
                Spacer()
                if working { ProgressView().controlSize(.small); Text("Changing the theme…").font(.callout) }
                Button("Change Theme…") { showPicker = true }
                    .disabled(working || readOnly || current == nil)
            }
            Text(currentText).font(.callout).foregroundStyle(readError == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
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
            guard let choice = picked else { return }
            picked = nil
            Task { await choose(choice) }
        }) {
            ThemePickerSheet(initial: initialChoice, confirmTitle: "Apply to Drive") { picked = $0 }
                .environmentObject(themes)
        }
        .confirmationDialog(
            "Replace your own theme?",
            isPresented: Binding(get: { pendingReplace != nil }, set: { if !$0 { pendingReplace = nil } }),
            titleVisibility: .visible,
            presenting: pendingReplace
        ) { pending in
            Button("Replace") { Task { await apply(pending.choice) } }
            // Return picks Cancel, so a double Return can't replace a theme nobody read about.
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { pending in
            Text(DriveThemeCopy.replaceMessage(file: pending.file, toDefault: pending.choice == .ventoyDefault))
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
            if themes.customThemes.contains(where: { $0.id == id }) { return .custom(id: id) }
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
            readOnly = snapshot.readOnly
            readError = snapshot.error
        }
        return snapshot
    }

    /// The picker's answer. A theme the user set up themselves is only
    /// replaced after they say so.
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
        if case .other(let file) = snapshot.current {
            working = false
            pendingReplace = PendingReplace(choice: choice, file: file)
            return
        }
        await apply(choice)
    }

    private func apply(_ choice: ThemeChoice) async {
        working = true
        message = nil
        do {
            let warnings = try await themes.apply(choice, to: volumeURL)
            isError = false
            message = ([DriveThemeCopy.success(removed: choice == .ventoyDefault)] + warnings).joined(separator: " ")
        } catch {
            isError = true
            message = error.localizedDescription
        }
        await refresh()
        working = false
    }
}
