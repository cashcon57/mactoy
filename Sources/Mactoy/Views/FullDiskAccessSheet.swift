import SwiftUI
import AppKit

/// Shown when the helper hits EPERM on `/dev/rdisk*`. macOS TCC never
/// shows an automatic prompt for Full Disk Access — it's the one
/// permission Apple explicitly requires the user to grant manually,
/// because it unlocks every file on the system. The best we can do is
/// auto-open the exact settings pane and explain what to drop in.
struct FullDiskAccessSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    private static let fdaSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "lock.open.trianglebadge.exclamationmark")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                Text("Full Disk Access needed")
                    .font(.title2.bold())
                Spacer()
            }

            Text("macOS blocks writes to external drives until you grant **Full Disk Access** to Mactoy. Apple does not allow apps to request this permission automatically — it has to be granted in System Settings.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                step(number: "1", text: "Click **Open Full Disk Access** below. System Settings will open to the right pane.")
                step(number: "2", text: "Click the **+** button and add **Mactoy** from /Applications.")
                step(number: "3", text: "Make sure the Mactoy toggle is **on**.")
                step(number: "4", text: "Quit Mactoy (⌘Q) and reopen it, then try Install again.")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))

            Text("Why this is one-time: the grant stays in place after the first install, so you won't see this sheet again.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Reveal Mactoy in Finder") {
                    NSWorkspace.shared.selectFile("/Applications/Mactoy.app", inFileViewerRootedAtPath: "/Applications")
                }
                Spacer()
                Button("Close", role: .cancel) {
                    state.showFullDiskAccessSheet = false
                    dismiss()
                }
                Button {
                    NSWorkspace.shared.open(Self.fdaSettingsURL)
                } label: {
                    Label("Open Full Disk Access", systemImage: "arrow.up.right.square")
                        .fontWeight(.semibold)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
        }
        .padding(26)
        .frame(width: 560)
    }

    private func step(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.callout.bold())
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: .circle)
            Text(.init(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
