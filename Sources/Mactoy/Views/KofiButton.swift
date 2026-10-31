import SwiftUI
import AppKit

/// A Liquid Glass button for Ko-fi donations, sized like the main action
/// button. Ko-fi's orange tints the glass; on macOS 13 to 15 it falls back to
/// the same material card as the other buttons.
struct KofiButton: View {
    private static let url = URL(string: "https://ko-fi.com/cash508287")!

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                KofiMug()
                    .frame(height: 20)
                Text("Support on Ko-fi")
                    .foregroundStyle(.primary)
            }
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .mactoyGlass(tint: KofiMug.orange.opacity(0.18), interactive: true)
        .help("Support Mactoy on Ko-fi (opens ko-fi.com/cash508287)")
        .accessibilityLabel("Support Mactoy on Ko-fi")
    }

    private func open() {
        NSWorkspace.shared.open(Self.url)
    }
}
