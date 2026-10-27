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

    var errorDescription: String? {
        switch self {
        case .busy: return "Mactoy is already changing this drive's theme."
        }
    }
}

@MainActor
final class ThemeStore: ObservableObject {
    @Published private(set) var catalog: [ThemeEntry] = []
    @Published private(set) var catalogSource: ThemeCatalogLoader.Source = .none
    /// Catalog previews by theme id. Custom themes have their own table:
    /// a catalog id may legitimately look like `custom-…`.
    @Published private(set) var previews: [String: NSImage] = [:]
    @Published private(set) var customPreviews: [String: NSImage] = [:]
    @Published private(set) var customThemes: [CustomThemeImporter.Imported] = []
    @Published private(set) var isLoading = false

    let loader: ThemeCatalogLoader
    let fetcher: ThemeFetcher

    private var previewsInFlight = Set<String>()
    /// Volumes with an apply or remove running. `apply` rejects a second
    /// change to the same drive (see `ThemeStoreError.busy`) instead of
    /// queueing it: two installs racing on one drive could each sweep the
    /// other's half-written folder.
    private var busyVolumes = Set<String>()

    init(loader: ThemeCatalogLoader = ThemeCatalogLoader(), fetcher: ThemeFetcher = ThemeFetcher()) {
        self.loader = loader
        self.fetcher = fetcher
    }

    /// Shows the copy already on this Mac at once, then swaps in the online
    /// list if it arrives. The online request can take a minute on a bad
    /// connection; the picker is usable meanwhile.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

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
        case .custom(let id): return customThemes.first { $0.id == id }?.name ?? id
        }
    }

    /// Importing runs `zipinfo` and `ditto` and can take a minute, so it
    /// stays off the main actor.
    func importCustom(from url: URL) async throws -> ThemeChoice {
        let (imported, previewData) = try await Task.detached(priority: .userInitiated) { () throws -> (CustomThemeImporter.Imported, Data?) in
            let imported = try CustomThemeImporter.importTheme(from: url)
            return (imported, imported.previewImage.flatMap { try? Data(contentsOf: $0) })
        }.value
        // Same name and different files give the same id: the new import replaces the old.
        customThemes.removeAll { $0.id == imported.id }
        customThemes.append(imported)
        // No picture in the new import must not leave the old one showing.
        customPreviews[imported.id] = previewData.flatMap { NSImage(data: $0) }
        return .custom(id: imported.id)
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
            guard let imported = customThemes.first(where: { $0.id == id }) else { throw ThemeError.unknownTheme(id) }
            return try await Task.detached {
                try ThemeInstaller.apply(themeDirectory: imported.directory, id: imported.id, name: imported.name, settings: imported.settings, to: volume).warnings
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
