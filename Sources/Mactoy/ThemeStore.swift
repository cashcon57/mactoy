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
    /// is judged only against the online catalog: the bundled and cached copies can
    /// lag behind it, and before any list has loaded an empty one says nothing, so a
    /// theme missing from those is not yet known to be gone. Ventoy's own theme is
    /// always there.
    func validated(_ choice: ThemeChoice, fallback: ThemeChoice) -> ThemeChoice {
        isAvailable(choice) ? choice : fallback
    }

    /// Whether what `choice` names can be used now, by the rules `validated` explains.
    func isAvailable(_ choice: ThemeChoice) -> Bool {
        switch choice {
        case .ventoyDefault:
            return true
        case .custom(let id):
            return savedIDs.contains(id)
        case .catalog(let id):
            return catalogSource != .remote || catalogIDs.contains(id)
        }
    }
}

/// How adding a boot theme to a freshly installed drive ended. The install itself
/// worked either way, so neither case is a failed run.
enum PostInstallThemeResult: Equatable, Sendable {
    /// The theme is on the drive. `warnings` are things worth telling the user
    /// (a setting that overrides the theme in one boot mode, say), not problems.
    case applied(warnings: [String])
    /// Nothing was added, or the write failed: why, as the end of a sentence.
    case notApplied(problem: String)
    /// The theme can't be used as it is: its download is gone or changed, or it left the theme
    /// list. Adding it later wouldn't help, so the message points to another theme. `problem` is
    /// the end of a sentence, as in `notApplied`.
    case themeUnavailable(problem: String)
}

/// A file or folder with several themes in it, waiting for the user to choose one. It holds
/// what was read, so choosing doesn't read (or unzip) the file again and nothing is left on disk.
struct PendingThemeChoice: Identifiable, Sendable {
    let id = UUID()
    let opened: CustomThemeImporter.Opened

    var choices: [CustomThemeImporter.Choice] { opened.choices }
}

/// How adding a theme from a file began.
enum ThemeImportStart: Sendable {
    /// The file held one theme and it is in My Themes.
    case imported(ThemeChoice)
    /// The file holds several. Nothing was added yet.
    case needsChoice(PendingThemeChoice)
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
    /// Ventoy's own menu, for the "Ventoy default" tile. Bundled in the app, so no download.
    @Published private(set) var ventoyDefaultPreview: NSImage?
    /// "My Themes": kept on this Mac, so they outlive the session and the drive they came from.
    @Published private(set) var savedThemes: [SavedTheme] = []
    /// Files a file import left out, by saved id. Not stored with the theme, so only
    /// the session that imported it can say so.
    @Published private(set) var importSkipped: [String: [String]] = [:]
    @Published private(set) var isLoading = false
    /// Catalog themes whose download turned out to be gone or changed, by id. Only this
    /// session's findings. An entry goes when a download of that theme works again, or
    /// when the catalog names a different download for the id.
    @Published private(set) var unavailableThemes: [String: ThemeUnavailable] = [:]

    let loader: ThemeCatalogLoader
    let fetcher: ThemeFetcher
    let library: ThemeLibrary
    /// Where an older Mactoy kept My Themes; its themes move to `library` on `load`. Nil in tests.
    private let legacyLibraryRoot: URL?
    /// Remembers across launches that My Themes is in use. Nil remembers nothing (tests, previews).
    private let defaults: UserDefaults?
    static let libraryInUseKey = "themeLibraryInUse"

    /// The library is in Documents, and macOS can ask the user before letting Mactoy in.
    /// So it is only read once themes are in use: one was saved or moved here, or a list
    /// of it had something in it. Otherwise it waits until the user opens the picker or
    /// a drive names a saved theme (`loadSavedThemesIfNeeded`).
    private(set) var libraryInUse: Bool
    /// Whether a listing of the library has finished this session.
    private(set) var hasListedLibrary = false
    /// Themes an older Mactoy kept that couldn't be moved here, so they are still in
    /// Application Support, where uninstalling Mactoy can delete them. The picker says so.
    @Published private(set) var legacyThemesNotMoved: [String] = []
    /// The library's folder is there but macOS won't let Mactoy read it, so the empty
    /// list is not the truth. The picker says so.
    @Published private(set) var libraryUnreadable = false

    /// The themes that can be chosen now. Changes when My Themes or the catalog does.
    var availability: ThemeAvailability {
        ThemeAvailability(savedIDs: Set(savedThemes.map(\.id)), catalogIDs: Set(catalog.map(\.id)), catalogSource: catalogSource)
    }

    /// Names of catalog themes seen this session, so one the list drops later can still be called by name.
    private var catalogNames: [String: String] = [:]
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
         library: ThemeLibrary = ThemeLibrary(), legacyLibraryRoot: URL? = nil, defaults: UserDefaults? = nil) {
        self.loader = loader
        self.fetcher = fetcher
        self.library = library
        self.legacyLibraryRoot = legacyLibraryRoot
        self.defaults = defaults
        self.libraryInUse = defaults?.bool(forKey: Self.libraryInUseKey) ?? false
    }

    /// Shows the copy already on this Mac at once, then swaps in the online
    /// list if it arrives. The online request can take a minute on a bad
    /// connection; the picker is usable meanwhile.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        await loadVentoyDefaultPreview()
        let loader = self.loader
        // Only before anything is shown: once an online list is in, falling
        // back to the cached copy of it would make the picker flicker.
        if catalog.isEmpty {
            let local = await Task.detached(priority: .userInitiated) { loader.loadLocal() }.value
            setCatalog(local.catalog.usableThemes)
            catalogSource = local.source
        }
        // The online list is asked for now, and old themes moved after the local one shows:
        // the move can wait on macOS asking about Documents, and neither should wait for it.
        let online = Task { await loader.load() }
        await moveLegacyThemes()
        if libraryInUse { await loadSavedThemes() }
        let remote = await online.value
        // Anything but `.remote` is the local copy again, which is already showing.
        let themes = remote.catalog.usableThemes
        guard remote.source == .remote, !themes.isEmpty else { return }
        setCatalog(themes)
        catalogSource = .remote
    }

    private func setCatalog(_ themes: [ThemeEntry]) {
        catalog = themes
        for theme in themes { catalogNames[theme.id] = theme.name }
        // A problem belongs to one download. If the list now names another one for the
        // id (or no longer has the theme), the theme is worth trying again.
        let stillTrue = unavailableThemes.filter { id, problem in themes.first { $0.id == id }.map(problem.describes) == true }
        if stillTrue.count != unavailableThemes.count { unavailableThemes = stillTrue }
    }

    /// Reads the bundled picture off the main actor; only the image is made here. Asked for
    /// by every view that shows the default theme, and only the first call reads anything.
    func loadVentoyDefaultPreview() async {
        guard ventoyDefaultPreview == nil else { return }
        let loader = self.loader
        let data = await Task.detached(priority: .userInitiated) { loader.ventoyDefaultPreviewData() }.value
        if ventoyDefaultPreview == nil, let data, let image = NSImage(data: data) { ventoyDefaultPreview = image }
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
        case .catalog(let id): return catalog.first { $0.id == id }?.name ?? catalogNames[id] ?? id
        case .custom(let id): return savedThemes.first { $0.id == id }?.name ?? id
        }
    }

    // MARK: My Themes

    /// Reads the library again. The file reads stay off the main actor.
    func loadSavedThemes() async {
        savedGeneration += 1
        let mine = savedGeneration
        let library = self.library
        let (saved, unreadable) = await Task.detached(priority: .userInitiated) { () -> ([SavedTheme], Bool) in
            let saved = library.list()
            return (saved, saved.isEmpty && library.isUnreadable())
        }.value
        guard mine == savedGeneration else { return }
        savedThemes = saved
        libraryUnreadable = unreadable
        hasListedLibrary = true
        if !saved.isEmpty { markLibraryInUse() }
        await loadSavedPreviews(for: saved)
    }

    /// Lists the library unless this session already has. For the places that show
    /// My Themes but don't change it: the picker, and a drive that names a saved theme.
    /// Two calls at once may both list; the later listing wins, which is harmless.
    func loadSavedThemesIfNeeded() async {
        guard !hasListedLibrary else { return }
        await loadSavedThemes()
    }

    private func markLibraryInUse() {
        guard !libraryInUse else { return }
        libraryInUse = true
        defaults?.set(true, forKey: Self.libraryInUseKey)
    }

    /// v0.7.0 kept My Themes in Application Support, which removing Mactoy can delete.
    /// Moves those themes to the library, then removes Mactoy's emptied folders there.
    /// Anything that isn't a whole theme stays put (`ThemeLibrary.moveThemes`).
    private func moveLegacyThemes() async {
        guard let legacy = legacyLibraryRoot else { return }
        let library = self.library
        let result = await Task.detached(priority: .userInitiated) {
            library.moveThemes(from: legacy, thenRemoveIfEmpty: legacy.deletingLastPathComponent())
        }.value
        if !result.moved.isEmpty { markLibraryInUse() }
        legacyThemesNotMoved = result.notMoved
    }

    /// The old library's folder, for the picker's warning when themes are stuck there.
    var legacyLibraryFolder: URL? { legacyLibraryRoot }

    /// The folder My Themes is in; made when the first theme is saved.
    var libraryFolder: URL { library.root }

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

    /// The My Themes entry a drive's theme came from, when the drive's copy is still the
    /// same theme. Mactoy adds a screen size (`gfxmode`) when it applies a theme that has
    /// none, so that setting is compared as it was applied. A copy changed on the drive
    /// is a different theme, and nil sends it to be saved as one.
    nonisolated static func unchangedEntry(for theme: DriveTheme, in library: ThemeLibrary) -> SavedTheme? {
        guard let id = theme.managedID, isSavedID(id), let kept = library.savedTheme(id: id) else { return nil }
        var settings = theme.settings
        if settings.gfxmode == (kept.settings.gfxmode ?? ThemeEntry.Settings.defaultGfxmode) {
            settings.gfxmode = kept.settings.gfxmode
        }
        return (try? ThemeLibrary.id(ifSaving: theme.folder, name: kept.name, settings: settings)) == id ? kept : nil
    }

    /// Whether a theme id on a drive is one My Themes gave it.
    nonisolated static func isSavedID(_ id: String) -> Bool { id.hasPrefix(ThemeEntry.reservedIDPrefix) }

    /// Adds a ZIP file, folder or theme.txt to My Themes. Reading it runs `zipinfo` and
    /// `ditto` and can take a minute, so it stays off the main actor. A file with several
    /// themes isn't added: the answer is `.needsChoice`, and `finishImport` adds the one chosen.
    func startImport(from url: URL) async throws -> ThemeImportStart {
        let opened = try await Task.detached(priority: .userInitiated) { try CustomThemeImporter.open(url) }.value
        if opened.needsChoice { return .needsChoice(PendingThemeChoice(opened: opened)) }
        return .imported(try await saveImport(opened, themeRoot: nil, name: nil))
    }

    /// Adds the theme the user picked from a file that holds several. It is saved under the name the
    /// choice list showed, not the folder's raw name, so My Themes calls it what the user picked.
    func finishImport(_ pending: PendingThemeChoice, choosing choice: CustomThemeImporter.Choice) async throws -> ThemeChoice {
        try await saveImport(pending.opened, themeRoot: choice.folder, name: choice.name)
    }

    /// For a caller that has no way to ask which theme: a file with several is an error naming them.
    func importCustom(from url: URL) async throws -> ThemeChoice {
        switch try await startImport(from: url) {
        case .imported(let choice): return choice
        case .needsChoice(let pending): throw ThemeError.ambiguousThemes(pending.opened.themeFilePaths)
        }
    }

    /// `name` is what to save it as; nil keeps the importer's (the folder's or file's name).
    private func saveImport(_ opened: CustomThemeImporter.Opened, themeRoot: String?, name: String?) async throws -> ThemeChoice {
        let library = self.library
        let (saved, skipped) = try await Task.detached(priority: .userInitiated) { () throws -> (SavedTheme, [String]) in
            // The importer's working copy lives in a folder of its own, deleted when done:
            // the library now holds the theme, and Caches would only collect copies.
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-import-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let imported = try CustomThemeImporter.importTheme(opened, themeRoot: themeRoot, cacheRoot: work)
            let saved = try library.save(folder: imported.directory, name: name ?? imported.name, settings: imported.settings,
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
            if let kept = ThemeStore.unchangedEntry(for: theme, in: library) { return kept }
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
        guard let (volume, theme) = found, await isSavableNow(theme) else { return nil }
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
    ///
    /// This reads the list in memory, so it is for what a view shows. A decision
    /// that could lose the drive's copy uses `isSavableNow`.
    func isSavable(_ driveTheme: DriveTheme?) -> Bool {
        guard let driveTheme else { return false }
        guard let managed = driveTheme.managedID else { return true }
        return !catalog.contains { $0.id == managed } && !savedThemes.contains { $0.id == managed }
    }

    /// `isSavable`, for replacing a drive's theme or erasing the drive. A theme from
    /// My Themes is looked up on disk now, and compared with the drive's copy, not in the list: the folder is in Documents,
    /// and the user may have deleted it in Finder since the list was read. When My Themes
    /// isn't in use on this Mac the theme is almost certainly not in it, so the answer
    /// is yes and Documents isn't read (macOS could ask about access over the sheet).
    /// A needless offer costs a click; saving a theme that is already kept returns the
    /// entry it came from (`saveDriveTheme`).
    func isSavableNow(_ driveTheme: DriveTheme?) async -> Bool {
        guard let driveTheme, let managed = driveTheme.managedID, Self.isSavedID(managed) else { return isSavable(driveTheme) }
        guard libraryInUse else { return true }
        let library = self.library
        // Kept means kept as it is on the drive: a copy changed there is offered too.
        return await Task.detached(priority: .userInitiated) { ThemeStore.unchangedEntry(for: driveTheme, in: library) == nil }.value
    }

    /// Download early so a later apply doesn't wait (catalog themes only). The task is
    /// returned for tests, which wait for the download to end; callers can ignore it.
    @discardableResult
    func prefetch(_ choice: ThemeChoice) -> Task<Void, Never>? {
        guard case .catalog(let id) = choice, let entry = catalog.first(where: { $0.id == id }) else { return nil }
        let fetcher = self.fetcher
        return Task.detached(priority: .utility) { [weak self] in
            do {
                _ = try await fetcher.themeDirectory(for: entry)
                await self?.downloadSucceeded(entry)
            } catch {
                await self?.downloadFailed(entry, error)
            }
        }
    }

    /// Notes a good download of `entry`: if it was marked unavailable, it is not now.
    private func downloadSucceeded(_ entry: ThemeEntry) {
        if let problem = unavailableThemes[entry.id], problem.describes(entry) { unavailableThemes[entry.id] = nil }
    }

    /// Notes a failed download of `entry`, when the failure says the download is gone or changed.
    /// A connection problem says nothing about the theme.
    private func downloadFailed(_ entry: ThemeEntry, _ error: any Error) {
        guard let problem = ThemeUnavailable(error: error, entry: entry),
              // The list may have moved on while this was downloading; the failure is about the old entry then.
              catalog.first(where: { $0.id == entry.id }).map(problem.describes) == true else { return }
        unavailableThemes[entry.id] = problem
    }

    /// A theme found in the catalog or My Themes, with its files on this Mac: all
    /// `ThemeInstaller.apply` needs. Resolved once, so a catalog or library that
    /// changes meanwhile can't swap the entry between the lookup and the write.
    private struct ResolvedTheme: Sendable {
        let id: String
        let name: String
        let settings: ThemeEntry.Settings
        let directory: URL
    }

    /// Finds the choice and, for a catalog theme, downloads it. This is the only
    /// place a download can happen. Nil for Ventoy's own theme, which has no files.
    private func resolve(_ choice: ThemeChoice) async throws -> ResolvedTheme? {
        switch choice {
        case .ventoyDefault:
            return nil
        case .catalog(let id):
            guard let entry = catalog.first(where: { $0.id == id }) else { throw ThemeError.unknownTheme(id) }
            let directory: URL
            do { directory = try await fetcher.themeDirectory(for: entry) } catch {
                downloadFailed(entry, error)
                throw error
            }
            downloadSucceeded(entry)
            return ResolvedTheme(id: entry.id, name: entry.name, settings: entry.settings, directory: directory)
        case .custom(let id):
            guard let saved = savedThemes.first(where: { $0.id == id }) else { throw ThemeError.unknownTheme(id) }
            return ResolvedTheme(id: saved.id, name: saved.name, settings: saved.settings, directory: library.directory(for: saved))
        }
    }

    /// Writes a resolved choice to the drive, off the main actor. Never downloads.
    private func write(_ theme: ResolvedTheme?, to volume: URL) async throws -> [String] {
        guard let theme else {
            return try await Task.detached { try ThemeInstaller.removeTheme(from: volume).warnings }.value
        }
        return try await Task.detached {
            try ThemeInstaller.apply(themeDirectory: theme.directory, id: theme.id, name: theme.name,
                                     settings: theme.settings, to: volume).warnings
        }.value
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

        return try await write(try await resolve(choice), to: volume)
    }

    /// For a fresh install: wait for macOS to mount the new volume, then
    /// apply. Says whether the theme was added (with any warnings the write
    /// produced, which don't make it a failure) or why it wasn't.
    ///
    /// The volume is found by disk number, and macOS reuses numbers: if the user
    /// swapped sticks while this waited, the Ventoy volume that appears may be
    /// another drive, with files or a theme of its own. So nothing is applied unless
    /// the volume still looks freshly installed (`ThemeInstaller.looksFreshlyInstalled`)
    /// and, asked once more just before the write, is still on the installed disk.
    ///
    /// A catalog theme is downloaded before either check, and nothing is downloaded
    /// after them: a download that fails is the problem reported, and the write uses
    /// the folder that download produced. `findVolume`, `looksFresh` and `deviceIdentifier`
    /// are seams for tests.
    func applyAfterInstall(
        _ choice: ThemeChoice, disk: DiskTarget,
        findVolume: @escaping @Sendable (String) async -> URL? = { await VentoyVolumeLocator.waitForVolume(onDisk: $0) },
        looksFresh: @escaping @Sendable (URL) -> Bool = ThemeInstaller.looksFreshlyInstalled,
        deviceIdentifier: @escaping @Sendable (URL) -> String? = VentoyVolumeLocator.deviceIdentifier
    ) async -> PostInstallThemeResult {
        guard let volume = await findVolume(disk.bsdName) else {
            return .notApplied(problem: "the new Ventoy volume didn't appear.")
        }
        let volumeKey = volume.standardizedFileURL.path
        guard busyVolumes.insert(volumeKey).inserted else { return .notApplied(problem: ThemeStoreError.busy.localizedDescription) }
        defer { busyVolumes.remove(volumeKey) }

        do {
            // The checks come right before the write, not before a download that can take a while.
            let theme = try await resolve(choice)
            // "<bsd>s" and not just "<bsd>": disk1 must not match disk10s1 (as in `VentoyVolumeLocator.find`).
            let slot = disk.bsdName + "s"
            // File system calls and diskutil stay off the main actor: a drive mid-eject could stall them.
            let isTheNewDrive = await Task.detached(priority: .userInitiated) {
                looksFresh(volume) && deviceIdentifier(volume)?.hasPrefix(slot) == true
            }.value
            guard isTheNewDrive else {
                return .notApplied(problem: "the drive in that slot doesn't look like the one Mactoy just set up.")
            }
            return .applied(warnings: try await write(theme, to: volume))
        } catch {
            return ThemeUnavailableCopy.postInstallResult(for: error, choice: choice, name: displayName(for: choice))
        }
    }

    /// What to tell the user about `error`, from changing the drive's theme to `choice`.
    func message(for error: any Error, choice: ThemeChoice) -> String {
        ThemeUnavailableCopy.message(for: error, choice: choice, themeName: displayName(for: choice))
    }
}
