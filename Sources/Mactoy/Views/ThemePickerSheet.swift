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
    @State private var importError: String?
    @State private var isImporting = false

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
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                        ThemeTile(title: "Ventoy default", subtitle: "Ventoy's own theme", image: nil,
                                  chips: [], isSelected: selection == .ventoyDefault) { selection = .ventoyDefault }
                        ForEach(themes.catalog) { entry in
                            ThemeTile(title: entry.name, subtitle: "by \(entry.author)", image: themes.previews[entry.id],
                                      chips: [entry.license, entry.showsVentoyHotkeys ? "F1–F6 key bar" : "No key bar"],
                                      isSelected: selection == .catalog(id: entry.id)) { selection = .catalog(id: entry.id) }
                                .task { await themes.loadPreview(for: entry) }
                        }
                        ForEach(themes.customThemes) { custom in
                            ThemeTile(title: custom.name, subtitle: "Added from file", image: themes.customPreviews[custom.id],
                                      chips: ["Custom"], isSelected: selection == .custom(id: custom.id)) { selection = .custom(id: custom.id) }
                        }
                    }
                    .padding(2)
                }
                .frame(minWidth: 420)
                ThemeDetail(selection: selection).frame(width: 340)
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
        .alert("Couldn't add that theme", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
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
            catch { importError = error.localizedDescription }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch selection {
                case .ventoyDefault:
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
                    if let custom = themes.customThemes.first(where: { $0.id == id }) {
                        preview(themes.customPreviews[id])
                        Text(custom.name).font(.headline)
                        if !custom.skippedFiles.isEmpty {
                            Text("Not copied (only images, fonts and theme files are): \(custom.skippedFiles.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
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
    return ThemeStore(loader: loader, fetcher: ThemeFetcher(transport: NoNetwork(), cacheRoot: dir.appendingPathComponent("themes"), bundledRoot: nil))
}

#Preview {
    ThemePickerSheet(initial: .ventoyDefault, confirmTitle: "Use This Theme") { _ in }
        .environmentObject(previewStore())
}
