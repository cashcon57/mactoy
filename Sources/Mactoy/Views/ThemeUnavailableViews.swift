import AppKit
import SwiftUI
import MactoyKit
import UniformTypeIdentifiers

/// What the three ways forward for an unavailable theme do. Shared by the
/// Manage Disk alert and the picker, so both do exactly the same.
@MainActor
enum ThemeUnavailableActions {
    static func report(_ entry: ThemeEntry, _ problem: ThemeUnavailable) {
        NSWorkspace.shared.open(ThemeIssueReport.url(for: entry, problem: problem))
    }

    static func openPage(of entry: ThemeEntry) {
        NSWorkspace.shared.open(entry.homepage)
    }

    /// What the file panel lets through. Plain text is only there for a theme's `theme.txt`;
    /// the importer turns any other text file away with a message that says what to pick.
    static let themeSourceTypes: [UTType] = [.zip, .folder, .plainText]

    /// Asks for a theme's ZIP file, folder or theme.txt. Nil when the user cancels.
    static func chooseThemeFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = themeSourceTypes
        panel.message = "Choose a theme's folder, its .zip file, or its theme.txt."
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// The picker's note on a theme that is unavailable, with the ways forward.
struct UnavailableThemeNotice: View {
    let entry: ThemeEntry
    let problem: ThemeUnavailable
    /// True while a file is being added.
    let isBusy: Bool
    let onAddFromFile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(ThemeUnavailableCopy.chip, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.bold()).foregroundStyle(.orange)
            Text(ThemeUnavailableCopy.pickerNote(for: problem))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Button(ThemeUnavailableCopy.reportButton) { ThemeUnavailableActions.report(entry, problem) }
                Button(ThemeUnavailableCopy.pageButton) { ThemeUnavailableActions.openPage(of: entry) }
                Button(ThemeUnavailableCopy.fileButton, action: onAddFromFile).disabled(isBusy)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
