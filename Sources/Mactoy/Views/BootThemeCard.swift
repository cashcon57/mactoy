import SwiftUI
import MactoyKit

/// The boot menu theme a fresh install will get. Mactoy picks Catppuccin Mocha
/// unless the user chooses otherwise, so the card says that, and how to opt out.
struct BootThemeCard: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var themes: ThemeStore
    @State private var showPicker = false

    var body: some View {
        HStack(spacing: 12) {
            preview
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text("Boot menu theme").font(.headline)
                Text(themes.displayName(for: state.installTheme)).font(.callout).foregroundStyle(.secondary)
                if let note = ThemeUnavailableCopy.installNote(for: state.installTheme, unavailable: themes.unavailableThemes) {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state.installTheme == AppState.defaultInstallTheme {
                    Text("Mactoy uses Catppuccin Mocha by default because Ventoy's built-in menu looks dated. Prefer the original? Choose Ventoy default.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button("Choose…") { showPicker = true }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .mactoyCard(cornerRadius: 14)
        // The picture is fetched when a tile scrolls into view in the picker, and
        // this card may be on screen long before the picker is opened. It is asked
        // for again when the catalog arrives, since the choice can be named before then.
        .task(id: chosenEntry?.id) {
            if let entry = chosenEntry { await themes.loadPreview(for: entry) }
        }
        .task { await themes.loadVentoyDefaultPreview() }
        .sheet(isPresented: $showPicker) {
            ThemePickerSheet(initial: state.installTheme, confirmTitle: "Use Theme") { choice in
                state.installTheme = choice
                themes.prefetch(choice)
            }
            .environmentObject(themes)
        }
    }

    private var chosenEntry: ThemeEntry? {
        guard case .catalog(let id) = state.installTheme else { return nil }
        return themes.catalog.first { $0.id == id }
    }

    @ViewBuilder private var preview: some View {
        switch state.installTheme {
        case .catalog(let id):
            if let image = themes.previews[id] { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else { Color.black.opacity(0.85) }
        case .custom(let id):
            // A saved theme's picture comes from My Themes, not from the catalog's previews.
            if let image = themes.customPreviews[id] { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else { Color.black.opacity(0.85) }
        case .ventoyDefault:
            if let image = themes.ventoyDefaultPreview { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else { ZStack { Color.black.opacity(0.85); Image(systemName: "paintpalette").foregroundStyle(.white.opacity(0.6)) } }
        }
    }
}
