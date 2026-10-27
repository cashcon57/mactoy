import AppKit
import Foundation
import MactoyKit

/// What the user picked for a drive's boot menu.
enum ThemeChoice: Hashable, Sendable {
    case ventoyDefault
    case catalog(id: String)
    case custom(id: String)
}

enum ThemeStoreError: Error, Equatable, LocalizedError {
    /// Another theme change is still running on the same drive.
    case busy
    /// The drive has no theme Mactoy can keep (it may have changed since it was read).
    case nothingToSave

    var errorDescription: String? {
        switch self {
        case .busy: return "Mactoy is already changing this drive's theme."
        case .nothingToSave: return "Mactoy couldn't find a theme on this drive that it can save."
        }
    }
}

@MainActor
final class ThemeStore: ObservableObject {
    @Published private(set) var catalog: [ThemeEntry] = []
    @Published private(set) var catalogSource: ThemeCatalogLoader.Source = .none
    /// Catalog previews by theme id. Saved themes have their own table:
    /// a catalog id may legitimately look like `custom-…`.
    @Published private(set) var previews: [String: NSImage] = [:]
    @Published private(set) var customPreviews: [String: NSImage] = [:]
    /// "My Themes": kept on this Mac, so they outlive the session and the drive they came from.
    @Published private(set) var savedThemes: [SavedTheme] = []
    /// Files a file import left out, by saved id. Not stored with the theme, so only
    /// the session that imported it can say so.
    @Published private(set) var importSkipped: [String: [String]] = [:]
    @Published private(set) var isLoading = false

    let loader: ThemeCatalogLoader
    let fetcher: ThemeFetcher
    let library: ThemeLibrary

    private var previewsInFlight = Set<String>()
    /// A listing that finishes after a newer one started is dropped, so a slow
    /// first read can't bring back a theme that was just removed.
    private var savedGeneration = 0
    /// Volumes with an apply or remove running. `apply` rejects a second
    /// change to the same drive (see `ThemeStoreError.busy`) instead of
    /// queueing it: two installs racing on one drive could each sweep the
    /// other's half-written folder.
    private var busyVolumes = Set<String>()

    init(loader: ThemeCatalogLoader = ThemeCatalogLoader(), fetcher: ThemeFetcher = ThemeFetcher(),
         library: ThemeLibrary = ThemeLibrary()) {
        self.loader = loader
        self.fetcher = fetcher
        self.library = library
    }

    /// Shows the copy already on this Mac at once, then swaps in the online
    /// list if it arrives. The online request can take a minute on a bad
    /// connection; the picker is usable meanwhile.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        await loadSavedThemes()
        let loader = self.loader
        // Only before anything is shown: once an online list is in, falling
        // back to the cached copy of it would make the picker flicker.
        if catalog.isEmpty {
            let local = await Task.detached(priority: .userInitiated) { loader.loadLocal() }.value
            catalog = local.catalog.usableThemes
            catalogSource = local.source
        }
        let remote = await loader.load()
        // Anything but `.remote` is the local copy again, which is already showing.
        let themes = remote.catalog.usableThemes
        guard remote.source == .remote, !themes.isEmpty else { return }
        catalog = themes
        catalogSource = .remote
    }

    func loadPreview(for entry: ThemeEntry) async {
        // Tiles ask again each time they scroll into view.
        guard previews[entry.id] == nil, previewsInFlight.insert(entry.id).inserted else { return }
        defer { previewsInFlight.remove(entry.id) }
        if let data = await loader.previewData(for: entry), let image = NSImage(data: data) {
            previews[entry.id] = image
        }
    }

    func displayName(for choice: ThemeChoice) -> String {
        switch choice {
        case .ventoyDefault: return "Ventoy default"
        case .catalog(let id): return catalog.first { $0.id == id }?.name ?? id
        case .custom(let id): return savedThemes.first { $0.id == id }?.name ?? id
        }
    }

    // MARK: My Themes

    /// Reads the library again. The file reads stay off the main actor.
    func loadSavedThemes() async {
        savedGeneration += 1
        let mine = savedGeneration
        let library = self.library
        let saved = await Task.detached(priority: .userInitiated) { library.list() }.value
        guard mine == savedGeneration else { return }
        savedThemes = saved
        await loadSavedPreviews(for: saved)
    }

    /// Pictures are read off the main actor; only the (lazy) image is made here.
    private func loadSavedPreviews(for themes: [SavedTheme]) async {
        let library = self.library
        let wanted = themes.compactMap { theme -> (String, URL)? in
            guard customPreviews[theme.id] == nil, let file = theme.previewFile else { return nil }
            return (theme.id, library.directory(for: theme).appendingPathComponent(file))
        }
        guard !wanted.isEmpty else { return }
        let loaded = await Task.detached(priority: .utility) { () -> [(String, Data)] in
            wanted.compactMap { id, url in
                // A tile needs a picture, not a 40 MB file.
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
                guard size <= ThemeStore.maxPreviewBytes, let data = try? Data(contentsOf: url) else { return nil }
                return (id, data)
            }
        }.value
        for (id, data) in loaded where customPreviews[id] == nil {
            if let image = NSImage(data: data) { customPreviews[id] = image }
        }
    }

    nonisolated static let maxPreviewBytes = 20 * 1024 * 1024

    /// Adds a ZIP file or folder to My Themes. Importing runs `zipinfo` and
    /// `ditto` and can take a minute, so it stays off the main actor.
    func importCustom(from url: URL) async throws -> ThemeChoice {
        let library = self.library
        let (saved, skipped) = try await Task.detached(priority: .userInitiated) { () throws -> (SavedTheme, [String]) in
            // The importer's working copy lives in a folder of its own, deleted when done:
            // the library now holds the theme, and Caches would only collect copies.
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-import-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let imported = try CustomThemeImporter.importTheme(from: url, cacheRoot: work)
            let saved = try library.save(folder: imported.directory, name: imported.name, settings: imported.settings,
                                         origin: "Added from a file")
            return (saved, imported.skippedFiles)
        }.value
        importSkipped[saved.id] = skipped.isEmpty ? nil : skipped
        await loadSavedThemes()
        return .custom(id: saved.id)
    }

    /// Keeps the theme the drive is set to use. Nil when the drive has nothing
    /// Mactoy can safely keep. Reads the drive only; never changes it.
    /// Throws `ThemeStoreError.busy` while the drive's theme is being changed.
    func saveDriveTheme(on volume: URL) async throws -> SavedTheme? {
        let volumeKey = volume.standardizedFileURL.path
        guard busyVolumes.insert(volumeKey).inserted else { throw ThemeStoreError.busy }
        defer { busyVolumes.remove(volumeKey) }

        let library = self.library
        let origin = "Saved from the drive “\(volume.lastPathComponent)”"
        let saved = try await Task.detached(priority: .userInitiated) { () throws -> SavedTheme? in
            guard let theme = try ThemeInstaller.driveTheme(on: volume) else { return nil }
            return try library.save(folder: theme.folder, name: theme.name, settings: theme.settings, origin: origin)
        }.value
        if saved != nil { await loadSavedThemes() }
        return saved
    }

    /// Drives that already use the theme keep their copy.
    func removeSaved(id: String) async throws {
        let library = self.library
        try await Task.detached(priority: .userInitiated) { try library.remove(id: id) }.value
        customPreviews[id] = nil
        importSkipped[id] = nil
        await loadSavedThemes()
    }

    /// Whether a drive's theme is worth offering to keep: any theme Mactoy can't
    /// download again. Catalog themes can always be fetched, and one already in
    /// My Themes is kept. Before the catalog has loaded a managed theme can't be
    /// told apart from a catalog one, so none is offered.
    func isSavable(_ driveTheme: DriveTheme?) -> Bool {
        guard let driveTheme else { return false }
        guard let managed = driveTheme.managedID else { return true }
        return catalogSource != .none
            && !catalog.contains { $0.id == managed }
            && !savedThemes.contains { $0.id == managed }
    }

    /// Download early so a later apply doesn't wait (catalog themes only).
    func prefetch(_ choice: ThemeChoice) {
        guard case .catalog(let id) = choice, let entry = catalog.first(where: { $0.id == id }) else { return }
        let fetcher = self.fetcher
        Task.detached(priority: .utility) { _ = try? await fetcher.themeDirectory(for: entry) }
    }

    /// Puts the choice on a mounted Ventoy volume. Returns warnings to show.
    /// Throws `ThemeStoreError.busy` if this drive is already being changed.
    func apply(_ choice: ThemeChoice, to volume: URL) async throws -> [String] {
        // A path string only: no file system call on the main actor, where a
        // drive mid-eject could stall it.
        let volumeKey = volume.standardizedFileURL.path
        guard busyVolumes.insert(volumeKey).inserted else { throw ThemeStoreError.busy }
        // Held across the download too, so two changes to a drive finish in the order they began.
        defer { busyVolumes.remove(volumeKey) }

        switch choice {
        case .ventoyDefault:
            return try await Task.detached { try ThemeInstaller.removeTheme(from: volume).warnings }.value
        case .catalog(let id):
            guard let entry = catalog.first(where: { $0.id == id }) else { throw ThemeError.unknownTheme(id) }
            let dir = try await fetcher.themeDirectory(for: entry)
            return try await Task.detached {
                try ThemeInstaller.apply(themeDirectory: dir, id: entry.id, name: entry.name, settings: entry.settings, to: volume).warnings
            }.value
        case .custom(let id):
            guard let saved = savedThemes.first(where: { $0.id == id }) else { throw ThemeError.unknownTheme(id) }
            let directory = library.directory(for: saved)
            return try await Task.detached {
                try ThemeInstaller.apply(themeDirectory: directory, id: saved.id, name: saved.name, settings: saved.settings, to: volume).warnings
            }.value
        }
    }

    /// For a fresh install: wait for macOS to mount the new volume, then
    /// apply. Returns a problem to report, or nil when it worked cleanly.
    func applyAfterInstall(_ choice: ThemeChoice, disk: DiskTarget) async -> String? {
        guard let volume = await VentoyVolumeLocator.waitForVolume(onDisk: disk.bsdName) else {
            return "the new Ventoy volume didn't appear."
        }
        do {
            let warnings = try await apply(choice, to: volume)
            return warnings.isEmpty ? nil : warnings.joined(separator: " ")
        } catch {
            return error.localizedDescription
        }
    }
}
