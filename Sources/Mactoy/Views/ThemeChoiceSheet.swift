import SwiftUI
import MactoyKit

/// Asks which theme to add when a file or folder holds several. Used by both
/// Add Theme from File flows, over whatever sheet or window they start from.
struct ThemeChoiceSheet: View {
    let pending: PendingThemeChoice
    let onChoose: (CustomThemeImporter.Choice) -> Void
    let onCancel: () -> Void
    /// Nothing is chosen at first, so Return can't add a theme nobody looked at.
    @State private var selection: String?

    private var chosen: CustomThemeImporter.Choice? { pending.choices.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a Theme").font(.title3.bold())
            Text("This holds \(pending.choices.count) themes. Pick the one to add to My Themes.")
                .font(.callout).foregroundStyle(.secondary)
            List(pending.choices, selection: $selection) { choice in
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.name).font(.headline).lineLimit(1)
                    Text(choice.location).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add Theme") { if let chosen { onChoose(chosen) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            }
        }
        .padding(20)
        // Inside the picker's 860 × 560 sheet, and so inside Mactoy's smallest window.
        .frame(width: 440, height: 400)
    }
}
