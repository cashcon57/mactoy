import SwiftUI
import AppKit

struct KofiButton: View {
    private static let url = URL(string: "https://ko-fi.com/cash508287")!
    private static let image: NSImage? = NSImage(
        contentsOf: Bundle.module.url(forResource: "SupportMeOnKofi", withExtension: "png")
        ?? URL(fileURLWithPath: "/dev/null")
    )

    var body: some View {
        Button(action: open) {
            if let img = Self.image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 28)
                    .accessibilityLabel("Support me on Ko-fi")
            } else {
                Label("Support on Ko-fi", systemImage: "cup.and.saucer.fill")
                    .font(.callout)
            }
        }
        .buttonStyle(.plain)
        .help("Support Mactoy on Ko-fi (opens ko-fi.com/cash508287)")
    }

    private func open() {
        NSWorkspace.shared.open(Self.url)
    }
}
