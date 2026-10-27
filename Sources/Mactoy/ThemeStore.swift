import AppKit
import Foundation
import MactoyKit

/// What the user picked for a drive's boot menu.
enum ThemeChoice: Hashable, Sendable {
    case ventoyDefault
    case catalog(id: String)
    case custom(id: String)
}

/// What can be chosen right now, for checking a choice that was made earlier.
struct ThemeAvailability: Equatable, Sendable {
    var savedIDs: Set<String>
    var catalogIDs: Set<String>
    /// `.none` until some catalog (bundled, cached or online) has loaded.
    var catalogSource: ThemeCatalogLoader.Source

    /// `choice` when what it names still exists, else `fallback`.
    ///
    /// A saved theme can be removed from My Themes while it is the pick for the
    /// next install, and a remembered catalog theme can leave the catalog; either
    /// would be a pick that fails after the drive has been erased. A catalog pick
    /// is judged only once a catalog has loaded: before that, an empty list says
    /// nothing. Ventoy's own theme is always there.
    func validated(_ choice: ThemeChoice, fallback: ThemeChoice) -> ThemeChoice {
        switch choice {
        case .ventoyDefault:
            return choice
        case .custom(let id):
            return savedIDs.contains(id) ? choice : fallback
        case .catalog(let id):
            return catalogSource == .none || catalogIDs.contains(id) ? choice : fallback
        }
    }
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
    /// Catalog previews by theme id.
    @Published private(set) var previews: [String: NSImage] = [:]
    /// Pictures of the themes in My Themes, by saved id. A separate table because they are
    /// read from the library on this Mac, not downloaded like the catalog's, and it is
    /// dropped per theme when one is removed. A catalog entry can't take a `custom-` id
    /// (`ThemeEntry.problems()`), so the two never share a key anyway.
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

    /// The themes that can be chosen now. Changes when My Themes or the catalog does.
    var availability: ThemeAvailability {
        ThemeAvailability(savedIDs: Set(savedThemes.map(\.id)), catalogIDs: Set(catalog.map(\.id)), catalogSource: catalogSource)
    }

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

    /// For the erase sheet of an Install: the theme the Ventoy drive on `bsdName`
    /// uses now, if it is one worth keeping, with the volume it was read from.
    /// Nil when no Ventoy volume is mounted from that disk, it has no theme,
    /// the theme can't be read, or Mactoy can get it back anyway. Reads the
    /// drive only, and off the main actor: this runs while a sheet is open.
    func savableDriveTheme(onDisk bsdName: String,
                           volumesDirectory: URL = URL(fileURLWithPath: "/Volumes"),
                           deviceIdentifier: @escaping @Sendable (URL) -> String? = VentoyVolumeLocator.deviceIdentifier
    ) async -> (name: String, volume: URL)? {
        let found = await Task.detached(priority: .userInitiated) { () -> (URL, DriveTheme)? in
            guard let volume = VentoyVolumeLocator.find(onDisk: bsdName, volumesDirectory: volumesDirectory,
                                                        deviceIdentifier: deviceIdentifier),
                  let theme = try? ThemeInstaller.driveTheme(on: volume) else { return nil }
            return (volume, theme)
        }.value
        guard let (volume, theme) = found, isSavable(theme) else { return nil }
        return (theme.name, volume)
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
    /// told apart from a catalog one, and then it is offered: a needless offer to
    /// keep a catalog theme costs a click, while no offer could let the only copy
    /// of an older Mactoy's custom theme be deleted when it is replaced.
    func isSavable(_ driveTheme: DriveTheme?) -> Bool {
        guard let driveTheme else { return false }
        guard let managed = driveTheme.managedID else { return true }
        return !catalog.contains { $0.id == managed } && !savedThemes.contains { $0.id == managed }
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
    ///
    /// The volume is found by disk number, and macOS reuses numbers: if the user
    /// swapped sticks while this waited, the Ventoy volume that appears may be
    /// another drive, with a theme of its own. So nothing is applied unless the
    /// volume still looks freshly installed (`ThemeInstaller.looksFreshlyInstalled`).
    /// `findVolume` and `looksFresh` are seams for tests.
    func applyAfterInstall(
        _ choice: ThemeChoice, disk: DiskTarget,
        findVolume: @escaping @Sendable (String) async -> URL? = { await VentoyVolumeLocator.waitForVolume(onDisk: $0) },
        looksFresh: @escaping @Sendable (URL) -> Bool = ThemeInstaller.looksFreshlyInstalled
    ) async -> String? {
        guard let volume = await findVolume(disk.bsdName) else {
            return "the new Ventoy volume didn't appear."
        }
        // A catalog theme is downloaded first, so the drive is checked right before it is
        // written, not before a download that can take a while. A failure here is reported
        // by `apply` below, which asks for the same download again.
        if case .catalog(let id) = choice, let entry = catalog.first(where: { $0.id == id }) {
            _ = try? await fetcher.themeDirectory(for: entry)
        }
        // File system calls stay off the main actor: a drive mid-eject could stall it.
        guard await Task.detached(priority: .userInitiated, operation: { looksFresh(volume) }).value else {
            return "the drive in that slot doesn't look like the one Mactoy just set up, so the theme wasn't added."
        }
        do {
            let warnings = try await apply(choice, to: volume)
            return warnings.isEmpty ? nil : warnings.joined(separator: " ")
        } catch {
            return error.localizedDescription
        }
    }
}
