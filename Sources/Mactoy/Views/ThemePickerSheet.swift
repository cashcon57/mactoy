import AppKit
import SwiftUI
import MactoyKit
import UniformTypeIdentifiers

struct ThemePickerSheet: View {
    @EnvironmentObject private var themes: ThemeStore
    @Environment(\.dismiss) private var dismiss
    let confirmTitle: String
    let onChoose: (ThemeChoice) -> Void
    @State private var selection: ThemeChoice
    @State private var problem: Problem?
    @State private var isImporting = false
    /// The saved theme the user asked to remove; removed only after they confirm.
    @State private var pendingRemoval: SavedTheme?

    private struct Problem {
        let title: String
        let message: String
    }

    init(initial: ThemeChoice, confirmTitle: String, onChoose: @escaping (ThemeChoice) -> Void) {
        self.confirmTitle = confirmTitle
        self.onChoose = onChoose
        _selection = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Boot Menu Theme").font(.title2.bold())
            catalogCaption
            HStack(alignment: .top, spacing: 16) {
                ScrollViewReader { proxy in
                    ScrollView { tiles.padding(2) }
                        // My Themes sits below the catalog, so what was just added or opened has to be brought into view.
                        .onAppear { proxy.scrollTo(selection) }
                        .onChange(of: selection) { proxy.scrollTo($0) }
                }
                .frame(minWidth: 420)
                ThemeDetail(selection: selection) { pendingRemoval = $0 }.frame(width: 340)
            }
            .confirmationDialog(
                pendingRemoval.map { "Remove “\($0.name)” from My Themes?" } ?? "",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible,
                presenting: pendingRemoval
            ) { saved in
                Button("Remove", role: .destructive) { remove(saved) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Drives that already use it keep it.")
            }
            HStack {
                Button("Add Theme from File…") { addFromFile() }
                    .disabled(isImporting)
                if isImporting {
                    ProgressView().controlSize(.small)
                    Text("Adding theme…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(confirmTitle) { onChoose(selection); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 560)
        // Also retries when the app started offline and kept a local copy.
        .task { if themes.catalogSource != .remote { await themes.load() } }
        .alert(problem?.title ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem?.message ?? "") }
    }

    private static let columns = [GridItem(.adaptive(minimum: 190), spacing: 12)]

    private var tiles: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: Self.columns, spacing: 12) {
                ThemeTile(title: "Ventoy default", subtitle: "Ventoy's own theme", image: themes.ventoyDefaultPreview,
                          chips: [], isSelected: selection == .ventoyDefault) { selection = .ventoyDefault }
                    .id(ThemeChoice.ventoyDefault)
                    .task { await themes.loadVentoyDefaultPreview() }
                ForEach(themes.catalog) { entry in
                    ThemeTile(title: entry.name, subtitle: "by \(entry.author)", image: themes.previews[entry.id],
                              chips: [entry.license, entry.showsVentoyHotkeys ? "F1–F6 key bar" : "No key bar"],
                              isSelected: selection == .catalog(id: entry.id)) { selection = .catalog(id: entry.id) }
                        .id(ThemeChoice.catalog(id: entry.id))
                        .task { await themes.loadPreview(for: entry) }
                }
            }
            if !themes.savedThemes.isEmpty {
                Text("My Themes").font(.headline)
                LazyVGrid(columns: Self.columns, spacing: 12) {
                    ForEach(themes.savedThemes) { saved in
                        ThemeTile(title: saved.name, subtitle: saved.origin, image: themes.customPreviews[saved.id],
                                  chips: [], isSelected: selection == .custom(id: saved.id)) { selection = .custom(id: saved.id) }
                            .id(ThemeChoice.custom(id: saved.id))
                            // The subtitle is cut short in a tile; the whole line is here and in the detail pane.
                            .help(saved.origin)
                            .contextMenu { Button("Remove from My Themes") { pendingRemoval = saved } }
                    }
                }
            }
        }
    }

    /// The online list can take a while to answer, so the local copy shows
    /// first; "couldn't reach" is only said once the attempt is over.
    @ViewBuilder private var catalogCaption: some View {
        if themes.isLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(themes.catalog.isEmpty ? "Loading themes…" : "Checking for newer themes…")
            }
            .font(.caption).foregroundStyle(.secondary)
        } else if themes.catalogSource == .bundled || themes.catalogSource == .cached {
            Text("Couldn't reach the online theme list; showing the copy from \(themes.catalogSource == .bundled ? "this version of Mactoy" : "last time").")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func addFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.message = "Choose a theme's .zip file or folder (it needs a theme.txt)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do { selection = try await themes.importCustom(from: url) }
            catch { problem = Problem(title: "Couldn't add that theme", message: error.localizedDescription) }
        }
    }

    private func remove(_ saved: SavedTheme) {
        Task {
            do {
                try await themes.removeSaved(id: saved.id)
                // The tile is gone, so nothing may stay selected on it.
                if selection == .custom(id: saved.id) { selection = .ventoyDefault }
            } catch {
                problem = Problem(title: "Couldn't remove that theme", message: error.localizedDescription)
            }
        }
    }
}

private struct ThemeTile: View {
    let title: String
    let subtitle: String
    let image: NSImage?
    let chips: [String]
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Rectangle().fill(.black.opacity(0.85))
                    if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
                    else { Image(systemName: "photo").font(.title2).foregroundStyle(.secondary) }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(chips, id: \.self) { chip in
                        Text(chip).font(.caption2).lineLimit(1).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            // Tiles in a row share its height, so one without chips doesn't sit lower than its neighbours.
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ThemeDetail: View {
    @EnvironmentObject private var themes: ThemeStore
    let selection: ThemeChoice
    let onRemove: (SavedTheme) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch selection {
                case .ventoyDefault:
                    preview(themes.ventoyDefaultPreview)
                    Text("Ventoy default").font(.headline)
                    Text("The theme Ventoy ships with. On a drive that already has a theme, this removes it.")
                        .font(.callout).foregroundStyle(.secondary)
                case .catalog(let id):
                    if let entry = themes.catalog.first(where: { $0.id == id }) {
                        preview(themes.previews[id])
                        Text(entry.name).font(.headline)
                        if let notes = entry.notes { Text(notes).font(.callout).foregroundStyle(.secondary) }
                        Link("\(entry.author) · \(entry.license)", destination: entry.homepage).font(.callout)
                        Text("Downloaded from the author and checked against Mactoy's theme list before use.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .custom(let id):
                    if let saved = themes.savedThemes.first(where: { $0.id == id }) {
                        preview(themes.customPreviews[id])
                        Text(saved.name).font(.headline)
                        Text(saved.origin).font(.callout).foregroundStyle(.secondary)
                        Text("Saved \(saved.savedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("Kept on this Mac, so it's here whenever you want it again.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let skipped = themes.importSkipped[id] {
                            Text("Not copied (only images, fonts and theme files are): \(skipped.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        // The tile's context menu does the same; this one can be reached without a right click.
                        Button("Remove from My Themes…") { onRemove(saved) }
                            .controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func preview(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image).resizable().aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// Offline, so opening the preview canvas never touches the network.
private struct NoNetwork: ThemeTransport {
    func data(from url: URL, maxBytes: Int) async throws -> Data { throw URLError(.notConnectedToInternet) }
}

@MainActor private func previewStore() -> ThemeStore {
    func sample(_ id: String, _ name: String, keyBar: Bool) -> ThemeEntry {
        ThemeEntry(id: id, name: name, author: "Example Author", homepage: URL(string: "https://github.com/example/\(id)")!,
                   license: "MIT", showsVentoyHotkeys: keyBar, notes: "A sample theme for the preview canvas.",
                   download: .init(url: URL(string: "https://github.com/example/\(id)/releases/download/v1/\(id).zip")!,
                                   sha256: String(repeating: "a", count: 64), root: ""),
                   files: nil, settings: .init(file: "theme.txt"))
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-preview-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let bundled = dir.appendingPathComponent("catalog.json")
    let catalog = ThemeCatalog(schema: ThemeCatalog.supportedSchema,
                               themes: [sample("sample-one", "Sample One", keyBar: true), sample("sample-two", "Sample Two", keyBar: false)])
    try? JSONEncoder().encode(catalog).write(to: bundled)
    let loader = ThemeCatalogLoader(transport: NoNetwork(), cacheDirectory: dir.appendingPathComponent("cache"),
                                    bundledCatalog: bundled, bundledPreviews: nil)
    return ThemeStore(loader: loader, fetcher: ThemeFetcher(transport: NoNetwork(), cacheRoot: dir.appendingPathComponent("themes"), bundledRoot: nil),
                      library: ThemeLibrary(root: dir.appendingPathComponent("My Themes")))
}

#Preview {
    ThemePickerSheet(initial: .ventoyDefault, confirmTitle: "Use This Theme") { _ in }
        .environmentObject(previewStore())
}
