import AppKit
import CryptoKit
import Testing
import Foundation
@testable import Mactoy
import MactoyKit

/// Catalog loading order and the one-change-per-drive rule.
@MainActor
@Suite("ThemeStore")
struct ThemeStoreTests {

    /// Holds every request until `open()`, so a test can look at the store
    /// while the network is still "busy".
    actor GatedTransport: ThemeTransport {
        private let responses: [URL: Data]
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private(set) var requestCount = 0

        init(responses: [URL: Data] = [:]) { self.responses = responses }

        func data(from url: URL, maxBytes: Int) async throws -> Data {
            requestCount += 1
            if !isOpen { await withCheckedContinuation { waiting.append($0) } }
            guard let data = responses[url] else { throw DriverError.network("offline") }
            return data
        }

        func open() {
            isOpen = true
            for w in waiting { w.resume() }
            waiting = []
        }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func entry(_ id: String) -> ThemeEntry {
        ThemeEntry(id: id, name: id, author: "a", homepage: URL(string: "https://github.com/a/b")!,
                   license: "MIT", showsVentoyHotkeys: true, notes: nil,
                   download: .init(url: URL(string: "https://github.com/a/b/releases/download/v1/x.zip")!,
                                   sha256: String(repeating: "b", count: 64), root: ""),
                   files: nil, settings: .init(file: "theme.txt"))
    }

    private func catalogData(_ ids: [String]) throws -> Data {
        try JSONEncoder().encode(ThemeCatalog(schema: ThemeCatalog.supportedSchema, themes: ids.map(entry)))
    }

    /// A store whose bundled catalog holds `bundledIDs`, with `loaderTransport`
    /// and `fetcherTransport` standing in for the network.
    /// `libraryRoot` is where My Themes lives; tests never touch the real one.
    private func makeStore(bundledIDs: [String], loaderTransport: any ThemeTransport,
                           fetcherTransport: any ThemeTransport, libraryRoot: URL? = nil) throws -> ThemeStore {
        let dir = try tempDir()
        let bundled = dir.appendingPathComponent("bundled.json")
        try catalogData(bundledIDs).write(to: bundled)
        let loader = ThemeCatalogLoader(transport: loaderTransport, cacheDirectory: dir.appendingPathComponent("cache"),
                                        bundledCatalog: bundled, bundledPreviews: nil)
        let fetcher = ThemeFetcher(transport: fetcherTransport, cacheRoot: dir.appendingPathComponent("themes"), bundledRoot: nil)
        return ThemeStore(loader: loader, fetcher: fetcher, library: ThemeLibrary(root: libraryRoot ?? dir.appendingPathComponent("My Themes")))
    }

    /// A store with no network at all and its own empty library.
    private func offlineStore(bundledIDs: [String] = [], libraryRoot: URL? = nil) async throws -> ThemeStore {
        let offline = GatedTransport()
        await offline.open()
        return try makeStore(bundledIDs: bundledIDs, loaderTransport: offline, fetcherTransport: offline, libraryRoot: libraryRoot)
    }

    /// A theme folder like one a user picks: a theme file that names a picture, the picture, a font, and files that mustn't be kept.
    private func themeFolder(name: String = "Night Sky", background: Data? = nil) throws -> URL {
        let dir = try tempDir().appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("desktop-image: \"bg.png\"\n".utf8).write(to: dir.appendingPathComponent("theme.txt"))
        try (background ?? Data([1])).write(to: dir.appendingPathComponent("bg.png"))
        try Data([2]).write(to: dir.appendingPathComponent("font.pf2"))
        try Data("echo".utf8).write(to: dir.appendingPathComponent("grub.cfg"))
        return dir
    }

    private func pngData() throws -> Data {
        let image = NSImage(size: NSSize(width: 16, height: 9), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        let tiff = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    }

    /// A mounted-looking volume whose ventoy.json points at a theme the user made.
    private func volumeWithHandTheme(named folder: String = "mytheme") throws -> URL {
        let v = try tempDir().appendingPathComponent("Ventoy")
        let themeDir = v.appendingPathComponent("ventoy/\(folder)")
        try FileManager.default.createDirectory(at: themeDir, withIntermediateDirectories: true)
        try Data("desktop-image: \"bg.png\"\n".utf8).write(to: themeDir.appendingPathComponent("theme.txt"))
        try Data([1]).write(to: themeDir.appendingPathComponent("bg.png"))
        try Data([2]).write(to: themeDir.appendingPathComponent("f.pf2"))
        try Data(#"{"control":[],"theme":{"file":"/ventoy/\#(folder)/theme.txt","fonts":["/ventoy/\#(folder)/f.pf2"],"gfxmode":"1280x720"}}"#.utf8)
            .write(to: v.appendingPathComponent("ventoy/ventoy.json"))
        return v
    }

    private func driveTheme(managedID: String?) -> DriveTheme {
        DriveTheme(folder: URL(fileURLWithPath: "/Volumes/Ventoy/ventoy/x"), name: "X", settings: .init(file: "theme.txt"), managedID: managedID)
    }

    @Test("load shows the local copy while the online one is pending, then swaps it in")
    func localThenRemote() async throws {
        let transport = GatedTransport(responses: [ThemeCatalogLoader.remoteCatalogURL: try catalogData(["from-remote"])])
        let store = try makeStore(bundledIDs: ["from-bundle"], loaderTransport: transport, fetcherTransport: transport)
        let loading = Task { await store.load() }

        // Wait for the local copy to appear (the transport is still closed).
        for _ in 0..<500 where store.catalog.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(store.catalog.map(\.id) == ["from-bundle"])
        #expect(store.catalogSource == .bundled)
        #expect(store.isLoading)

        await transport.open()
        await loading.value
        #expect(store.catalog.map(\.id) == ["from-remote"])
        #expect(store.catalogSource == .remote)
        #expect(!store.isLoading)
    }

    @Test("an online list that can't be fetched leaves the local copy in place")
    func remoteFails() async throws {
        let transport = GatedTransport()   // answers nothing: every request fails once opened
        await transport.open()
        let store = try makeStore(bundledIDs: ["from-bundle"], loaderTransport: transport, fetcherTransport: transport)
        await store.load()
        #expect(store.catalog.map(\.id) == ["from-bundle"])
        #expect(store.catalogSource == .bundled)
        #expect(!store.isLoading)
    }

    @Test("a second change to a drive that is already being changed is refused; other drives and later changes are not")
    func busyVolume() async throws {
        let gate = GatedTransport()   // the theme download waits here
        let offline = GatedTransport()
        await offline.open()
        let store = try makeStore(bundledIDs: ["busy-one"], loaderTransport: offline, fetcherTransport: gate)
        await store.load()
        let volume = try tempDir()
        let otherVolume = try tempDir()

        let first = Task { try await store.apply(.catalog(id: "busy-one"), to: volume) }
        for _ in 0..<500 where await gate.requestCount == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(await gate.requestCount == 1)

        await #expect(throws: ThemeStoreError.busy) { _ = try await store.apply(.ventoyDefault, to: volume) }
        #expect(ThemeStoreError.busy.errorDescription == "Mactoy is already changing this drive's theme.")
        // A different drive is its own queue.
        #expect(try await store.apply(.ventoyDefault, to: otherVolume).isEmpty)

        // The first change fails (the download has no answer); the drive is free again afterwards.
        await gate.open()
        await #expect(throws: DriverError.self) { _ = try await first.value }
        #expect(try await store.apply(.ventoyDefault, to: volume).isEmpty)
    }

    // MARK: My Themes

    @Test("a theme added from a file is still there for a store started later")
    func importPersists() async throws {
        let libraryRoot = try tempDir().appendingPathComponent("My Themes")
        let store = try await offlineStore(libraryRoot: libraryRoot)
        let choice = try await store.importCustom(from: themeFolder())
        guard case .custom(let id) = choice else { Issue.record("expected a saved theme, got \(choice)"); return }
        #expect(store.savedThemes.map(\.id) == [id])
        #expect(store.savedThemes[0].name == "Night Sky")
        #expect(store.savedThemes[0].origin == "Added from a file")
        #expect(store.displayName(for: choice) == "Night Sky")

        // The app starts again: nothing in memory, the same folder on disk.
        let later = try await offlineStore(libraryRoot: libraryRoot)
        #expect(later.savedThemes.isEmpty)
        await later.load()
        #expect(later.savedThemes == store.savedThemes)
        #expect(later.displayName(for: choice) == "Night Sky")
    }

    @Test("importing the same theme twice keeps one entry; an import leaves only the library behind")
    func importTwice() async throws {
        let libraryRoot = try tempDir().appendingPathComponent("My Themes")
        let store = try await offlineStore(libraryRoot: libraryRoot)
        let first = try await store.importCustom(from: themeFolder())
        let second = try await store.importCustom(from: themeFolder())
        #expect(first == second)
        #expect(store.savedThemes.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: libraryRoot.path).count == 1, "no staging or working copy is left in the library")
    }

    @Test("files the import didn't keep are reported for the session")
    func importReportsSkipped() async throws {
        let store = try await offlineStore()
        guard case .custom(let id) = try await store.importCustom(from: themeFolder()) else { Issue.record("not a saved theme"); return }
        #expect(store.importSkipped[id] == ["grub.cfg"])
        try await store.removeSaved(id: id)
        #expect(store.importSkipped[id] == nil)
    }

    @Test("a saved theme's picture is read from its folder")
    func savedPreview() async throws {
        let store = try await offlineStore()
        guard case .custom(let id) = try await store.importCustom(from: themeFolder(background: pngData())) else { Issue.record("not a saved theme"); return }
        #expect(store.customPreviews[id] != nil)
        // Not a picture at all: the tile just has no preview.
        guard case .custom(let other) = try await store.importCustom(from: themeFolder(name: "Plain", background: Data([1, 2, 3]))) else { Issue.record("not a saved theme"); return }
        #expect(store.customPreviews[other] == nil)
    }

    @Test("applying a saved theme puts the library's copy on the drive")
    func applySaved() async throws {
        let store = try await offlineStore()
        let choice = try await store.importCustom(from: themeFolder())
        guard case .custom(let id) = choice else { Issue.record("not a saved theme"); return }
        let volume = try tempDir()
        #expect(try await store.apply(choice, to: volume).isEmpty)
        #expect(try ThemeInstaller.current(on: volume) == .managed(id: id, name: "Night Sky"))
        let installed = volume.appendingPathComponent("ventoy/themes/mactoy-\(id)")
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("bg.png").path))
        #expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent("grub.cfg").path))
        await #expect(throws: ThemeError.unknownTheme("custom-gone-12345678")) {
            _ = try await store.apply(.custom(id: "custom-gone-12345678"), to: volume)
        }
    }

    @Test("a theme found on a drive is saved to My Themes, and the drive is not touched")
    func saveDriveThemeKeepsCopy() async throws {
        let store = try await offlineStore()
        let volume = try volumeWithHandTheme()
        let before = try Data(contentsOf: volume.appendingPathComponent("ventoy/ventoy.json"))
        let saved = try #require(try await store.saveDriveTheme(on: volume))
        #expect(saved.name == "mytheme")
        #expect(saved.origin == "Saved from the drive “Ventoy”")
        #expect(saved.settings == .init(file: "theme.txt", fonts: ["f.pf2"], gfxmode: "1280x720"))
        #expect(store.savedThemes == [saved])
        #expect(try Data(contentsOf: volume.appendingPathComponent("ventoy/ventoy.json")) == before)
        #expect(try ThemeInstaller.current(on: volume) == .other(file: "/ventoy/mytheme/theme.txt"))
        #expect(!FileManager.default.fileExists(atPath: volume.appendingPathComponent("ventoy/themes").path))
        // Saving it again changes nothing.
        #expect(try await store.saveDriveTheme(on: volume) == saved)
        #expect(store.savedThemes.count == 1)

        // It can be put back later.
        let other = try tempDir()
        _ = try await store.apply(.custom(id: saved.id), to: other)
        #expect(try ThemeInstaller.current(on: other) == .managed(id: saved.id, name: "mytheme"))
    }

    @Test("a drive with nothing to keep saves nothing")
    func saveDriveThemeNothing() async throws {
        let store = try await offlineStore()
        let volume = try tempDir()
        #expect(try await store.saveDriveTheme(on: volume) == nil)
        try FileManager.default.createDirectory(at: volume.appendingPathComponent("ventoy"), withIntermediateDirectories: true)
        try Data(#"{"theme":{"gfxmode":"1280x720"}}"#.utf8).write(to: volume.appendingPathComponent("ventoy/ventoy.json"))
        #expect(try await store.saveDriveTheme(on: volume) == nil)
        #expect(store.savedThemes.isEmpty)
        #expect(ThemeStoreError.nothingToSave.errorDescription?.isEmpty == false)
    }

    @Test("a drive whose theme is being changed can't be read for saving at the same time")
    func saveDriveThemeBusy() async throws {
        let gate = GatedTransport()
        let offline = GatedTransport()
        await offline.open()
        let store = try makeStore(bundledIDs: ["busy-two"], loaderTransport: offline, fetcherTransport: gate)
        await store.load()
        let volume = try volumeWithHandTheme()

        let applying = Task { try await store.apply(.catalog(id: "busy-two"), to: volume) }
        for _ in 0..<500 where await gate.requestCount == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        await #expect(throws: ThemeStoreError.busy) { _ = try await store.saveDriveTheme(on: volume) }

        await gate.open()
        await #expect(throws: DriverError.self) { _ = try await applying.value }
        #expect(try await store.saveDriveTheme(on: volume) != nil, "free again once the change is over")
    }

    @Test("a theme is removed from My Themes and stays removed")
    func removeSaved() async throws {
        let libraryRoot = try tempDir().appendingPathComponent("My Themes")
        let store = try await offlineStore(libraryRoot: libraryRoot)
        guard case .custom(let keep) = try await store.importCustom(from: themeFolder(name: "Keep", background: pngData())),
              case .custom(let drop) = try await store.importCustom(from: themeFolder(name: "Drop", background: pngData()))
        else { Issue.record("not saved themes"); return }
        #expect(store.savedThemes.count == 2)
        try await store.removeSaved(id: drop)
        #expect(store.savedThemes.map(\.id) == [keep])
        #expect(store.customPreviews[drop] == nil && store.customPreviews[keep] != nil)
        let later = try await offlineStore(libraryRoot: libraryRoot)
        await later.load()
        #expect(later.savedThemes.map(\.id) == [keep])
        await #expect(throws: ThemeLibraryError.notInLibrary("../keep")) { try await store.removeSaved(id: "../keep") }
    }

    @Test("before the catalog has loaded, a Mactoy-installed theme is offered, so an older custom theme is never replaced unsaved")
    func savableBeforeCatalogLoads() async throws {
        let store = try await offlineStore(bundledIDs: ["from-catalog"])
        #expect(store.catalogSource == .none && store.catalog.isEmpty)
        #expect(store.isSavable(driveTheme(managedID: "custom-x-12345678")))
        // Needlessly offering a catalog theme is harmless; the decision then asks.
        #expect(store.isSavable(driveTheme(managedID: "from-catalog")))
        let managed = ThemeInstaller.Current.managed(id: "custom-x-12345678", name: "X")
        let theme = driveTheme(managedID: "custom-x-12345678")
        #expect(ThemeReplacement.step(current: managed, driveTheme: theme, isSavable: store.isSavable(theme)) == .offerSave(theme))
        // Once the catalog is known the catalog theme is exempt again.
        await store.load()
        #expect(!store.isSavable(driveTheme(managedID: "from-catalog")))
        #expect(store.isSavable(driveTheme(managedID: "custom-x-12345678")))
    }

    @Test("a drive's theme is worth keeping unless Mactoy can get it back")
    func savable() async throws {
        let store = try await offlineStore(bundledIDs: ["from-catalog"])
        #expect(!store.isSavable(nil))
        #expect(store.isSavable(driveTheme(managedID: nil)), "a theme the user set up themselves")
        await store.load()
        #expect(!store.isSavable(driveTheme(managedID: "from-catalog")))
        #expect(store.isSavable(driveTheme(managedID: "removed-from-catalog")))
        #expect(store.isSavable(driveTheme(managedID: "custom-x-12345678")))
        let choice = try await store.importCustom(from: themeFolder())
        guard case .custom(let id) = choice else { Issue.record("not a saved theme"); return }
        #expect(!store.isSavable(driveTheme(managedID: id)), "already in My Themes")
        try await store.removeSaved(id: id)
        #expect(store.isSavable(driveTheme(managedID: id)))
    }

    // MARK: Ventoy default picture

    private func jpegData() throws -> Data {
        let image = NSImage(size: NSSize(width: 16, height: 9), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill(); return true
        }
        let tiff = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:]))
    }

    private func storeWithBundledPreviews(_ previews: URL?) async throws -> ThemeStore {
        let offline = GatedTransport()
        await offline.open()
        let dir = try tempDir()
        let loader = ThemeCatalogLoader(transport: offline, cacheDirectory: dir.appendingPathComponent("cache"),
                                        bundledCatalog: nil, bundledPreviews: previews)
        return ThemeStore(loader: loader, fetcher: ThemeFetcher(transport: offline, cacheRoot: dir.appendingPathComponent("themes"), bundledRoot: nil),
                          library: ThemeLibrary(root: dir.appendingPathComponent("My Themes")))
    }

    @Test("the Ventoy default tile gets the bundled picture, once, with no network")
    func ventoyDefaultPicture() async throws {
        let previews = try tempDir()
        try jpegData().write(to: previews.appendingPathComponent("ventoy-default.jpg"))
        let store = try await storeWithBundledPreviews(previews)
        #expect(store.ventoyDefaultPreview == nil)
        await store.loadVentoyDefaultPreview()
        let first = try #require(store.ventoyDefaultPreview)
        #expect(first.size.width > 0)
        await store.loadVentoyDefaultPreview()
        #expect(store.ventoyDefaultPreview === first, "asked for again, nothing is read again")
    }

    @Test("load() brings the Ventoy default picture in with the rest")
    func loadFetchesTheVentoyDefaultPicture() async throws {
        let previews = try tempDir()
        try jpegData().write(to: previews.appendingPathComponent("ventoy-default.jpg"))
        let store = try await storeWithBundledPreviews(previews)
        await store.load()
        #expect(store.ventoyDefaultPreview != nil)
    }

    @Test("without a usable bundled picture the tile keeps its placeholder")
    func ventoyDefaultPictureMissing() async throws {
        let store = try await storeWithBundledPreviews(nil)
        await store.loadVentoyDefaultPreview()
        #expect(store.ventoyDefaultPreview == nil)
        let previews = try tempDir()
        try Data("<html></html>".utf8).write(to: previews.appendingPathComponent("ventoy-default.jpg"))
        let junk = try await storeWithBundledPreviews(previews)
        await junk.loadVentoyDefaultPreview()
        #expect(junk.ventoyDefaultPreview == nil)
    }

    // MARK: Theme after an install

    private func installedDisk(_ bsd: String = "disk97") -> DiskTarget {
        DiskTarget(bsdName: bsd, sizeInBytes: 32_000_000_000, isExternal: true, isRemovable: true, mediaName: "Stick", volumes: [])
    }

    /// What `diskutil` says about the volume when it really is on the installed disk (`installedDisk()`).
    private let onInstalledDisk: @Sendable (URL) -> String? = { _ in "disk97s2" }

    private let notTheNewDrive = "the drive in that slot doesn't look like the one Mactoy just set up."

    /// Added with nothing to say about it.
    private let addedCleanly = PostInstallThemeResult.applied(warnings: [])

    /// Every file and folder under `root` with its bytes, so "unchanged" means unchanged.
    private func snapshot(_ root: URL) throws -> [String: Data?] {
        let fm = FileManager.default
        var out: [String: Data?] = [:]
        for case let url as URL in fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])! {
            let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            out[String(url.path.dropFirst(root.path.count))] = isDirectory ? .some(nil) : .some(try Data(contentsOf: url))
        }
        return out
    }

    @Test("after an install, a volume that looks freshly set up gets the theme")
    func afterInstallFresh() async throws {
        let store = try await offlineStore()
        guard case .custom(let id) = try await store.importCustom(from: themeFolder()) else { Issue.record("not a saved theme"); return }
        let volume = try tempDir()
        let problem = await store.applyAfterInstall(.custom(id: id), disk: installedDisk(), findVolume: { _ in volume },
                                                   deviceIdentifier: onInstalledDisk)
        #expect(problem == addedCleanly)
        #expect(try ThemeInstaller.current(on: volume) == .managed(id: id, name: "Night Sky"))
    }

    @Test("warnings from a theme that was written come back with it: the theme is on the drive, so it isn't a failure")
    func afterInstallWarnings() async throws {
        let store = try await offlineStore()
        guard case .custom(let id) = try await store.importCustom(from: themeFolder()) else { Issue.record("not a saved theme"); return }
        // The new drive's ventoy.json sets a separate theme for UEFI boot, which Ventoy prefers in that mode.
        let volume = try tempDir()
        let settingsFolder = volume.appendingPathComponent("ventoy")
        try FileManager.default.createDirectory(at: settingsFolder, withIntermediateDirectories: true)
        try Data(#"{"theme_uefi":{"file":"/ventoy/u/theme.txt"}}"#.utf8).write(to: settingsFolder.appendingPathComponent("ventoy.json"))
        let result = await store.applyAfterInstall(.custom(id: id), disk: installedDisk(), findVolume: { _ in volume },
                                                  looksFresh: { _ in true }, deviceIdentifier: onInstalledDisk)
        guard case .applied(let warnings) = result else { Issue.record("not applied: \(result)"); return }
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("theme_uefi") == true)
        #expect(try ThemeInstaller.current(on: volume) == .managed(id: id, name: "Night Sky"), "the theme was written")
    }

    @Test("the volume is looked up on the installed disk")
    func afterInstallAsksForTheInstalledDisk() async throws {
        let store = try await offlineStore()
        let asked = Box()
        let problem = await store.applyAfterInstall(.ventoyDefault, disk: installedDisk("disk42"),
                                                   findVolume: { asked.add($0); return nil })
        #expect(asked.values == ["disk42"])
        #expect(problem == .notApplied(problem: "the new Ventoy volume didn't appear."))
    }

    @Test("a drive that already has a ventoy.json is left exactly as it was")
    func afterInstallExistingConfig() async throws {
        let store = try await offlineStore()
        guard case .custom(let id) = try await store.importCustom(from: themeFolder()) else { Issue.record("not a saved theme"); return }
        // Another stick took the disk number: it has a theme of the user's own.
        let volume = try volumeWithHandTheme()
        let before = try snapshot(volume)
        let problem = await store.applyAfterInstall(.custom(id: id), disk: installedDisk(), findVolume: { _ in volume },
                                                   deviceIdentifier: onInstalledDisk)
        #expect(problem == .notApplied(problem: notTheNewDrive))
        #expect(try snapshot(volume) == before, "not a byte of the drive changed")
        #expect(try ThemeInstaller.current(on: volume) == .other(file: "/ventoy/mytheme/theme.txt"))
    }

    @Test("a drive that already has a Mactoy theme folder is left exactly as it was")
    func afterInstallExistingThemeFolder() async throws {
        let store = try await offlineStore()
        guard case .custom(let id) = try await store.importCustom(from: themeFolder()) else { Issue.record("not a saved theme"); return }
        let volume = try tempDir()
        let old = volume.appendingPathComponent("ventoy/themes/mactoy-x")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data(#"{"id":"x","name":"X"}"#.utf8).write(to: old.appendingPathComponent(ThemeInstaller.markerName))
        try Data("title-text: \"x\"\n".utf8).write(to: old.appendingPathComponent("theme.txt"))
        let before = try snapshot(volume)
        let problem = await store.applyAfterInstall(.custom(id: id), disk: installedDisk(), findVolume: { _ in volume },
                                                   deviceIdentifier: onInstalledDisk)
        #expect(problem == .notApplied(problem: notTheNewDrive))
        #expect(try snapshot(volume) == before, "mactoy-x is still there, and nothing was added")
    }

    @Test("the freshness check is what decides, and a catalog theme is downloaded before it")
    func afterInstallUsesTheCheck() async throws {
        let store = try await offlineStore()
        guard case .custom(let id) = try await store.importCustom(from: themeFolder()) else { Issue.record("not a saved theme"); return }
        let volume = try tempDir()
        let looked = Box()
        let no = await store.applyAfterInstall(.custom(id: id), disk: installedDisk(), findVolume: { _ in volume },
                                              looksFresh: { looked.add($0.path); return false }, deviceIdentifier: onInstalledDisk)
        #expect(no == .notApplied(problem: notTheNewDrive))
        #expect(looked.values == [volume.path])
        #expect(!FileManager.default.fileExists(atPath: volume.appendingPathComponent("ventoy").path))
        let yes = await store.applyAfterInstall(.custom(id: id), disk: installedDisk(), findVolume: { _ in volume },
                                               looksFresh: { _ in true }, deviceIdentifier: onInstalledDisk)
        #expect(yes == addedCleanly)
        #expect(FileManager.default.fileExists(atPath: volume.appendingPathComponent("ventoy/ventoy.json").path))
    }

    @Test("a catalog theme's download finishes before the drive is looked at")
    func afterInstallDownloadsFirst() async throws {
        let archive = try themeZip()
        let url = entry("fetched-theme").download.url
        let gate = GatedTransport(responses: [url: archive])   // the download waits here
        let (store, _) = try await storeWithDownloadableTheme(archive: archive, fetcherTransport: gate)
        let volume = try tempDir()
        let order = Box()
        let identify = onInstalledDisk
        let running = Task {
            await store.applyAfterInstall(.catalog(id: "fetched-theme"), disk: installedDisk(), findVolume: { _ in volume },
                                          looksFresh: { _ in order.add("looked"); return false }, deviceIdentifier: identify)
        }
        for _ in 0..<500 where await gate.requestCount == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(await gate.requestCount == 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(order.values.isEmpty, "the drive is checked right before it is written, not before a slow download")
        await gate.open()
        _ = await running.value
        #expect(order.values == ["looked"])
    }

    @Test("a volume with an ISO on it is not the one Mactoy just set up, even with no settings on it")
    func afterInstallIsoAtTheRoot() async throws {
        let store = try await offlineStore()
        guard case .custom(let id) = try await store.importCustom(from: themeFolder()) else { Issue.record("not a saved theme"); return }
        let volume = try tempDir()
        try Data([1, 2, 3]).write(to: volume.appendingPathComponent("ubuntu.iso"))
        let before = try snapshot(volume)
        let problem = await store.applyAfterInstall(.custom(id: id), disk: installedDisk(), findVolume: { _ in volume },
                                                   deviceIdentifier: onInstalledDisk)
        #expect(problem == .notApplied(problem: notTheNewDrive))
        #expect(try snapshot(volume) == before, "no ventoy folder was made")
    }

    @Test("a volume that is not on the installed disk any more gets nothing, however fresh it looks")
    func afterInstallDeviceMismatch() async throws {
        let store = try await offlineStore()
        guard case .custom(let id) = try await store.importCustom(from: themeFolder()) else { Issue.record("not a saved theme"); return }
        // Another disk, a number that only starts the same, no answer from diskutil, and a different slice of the same number.
        let answers: [String?] = ["disk3s2", "disk970s2", "disk9s2", "disk97", nil, ""]
        for answer in answers {
            let volume = try tempDir()
            let asked = Box()
            let problem = await store.applyAfterInstall(.custom(id: id), disk: installedDisk("disk97"), findVolume: { _ in volume },
                                                       looksFresh: { _ in true },
                                                       deviceIdentifier: { asked.add($0.path); return answer })
            #expect(problem == .notApplied(problem: notTheNewDrive), "\(String(describing: answer))")
            #expect(asked.values == [volume.path])
            #expect(try snapshot(volume).isEmpty, "nothing was written for \(String(describing: answer))")
        }
        // The same disk, any slice, is fine.
        let volume = try tempDir()
        let ok = await store.applyAfterInstall(.custom(id: id), disk: installedDisk("disk97"), findVolume: { _ in volume },
                                              looksFresh: { _ in true }, deviceIdentifier: { _ in "disk97s1" })
        #expect(ok == addedCleanly)
        #expect(try ThemeInstaller.current(on: volume) == .managed(id: id, name: "Night Sky"))
    }

    @Test("the disk is asked about after the drive is checked, right before the write")
    func afterInstallChecksTheDiskLast() async throws {
        let store = try await offlineStore()
        guard case .custom(let id) = try await store.importCustom(from: themeFolder()) else { Issue.record("not a saved theme"); return }
        let volume = try tempDir()
        let order = Box()
        let problem = await store.applyAfterInstall(.custom(id: id), disk: installedDisk(), findVolume: { _ in order.add("found"); return volume },
                                                   looksFresh: { _ in order.add("fresh"); return true },
                                                   deviceIdentifier: { _ in order.add("device"); return "disk97s2" })
        #expect(problem == addedCleanly)
        #expect(order.values == ["found", "fresh", "device"])
    }

    @Test("a download that fails is the problem reported, with no check and no second try")
    func afterInstallFailedDownload() async throws {
        let offline = GatedTransport()
        await offline.open()
        let fetching = GatedTransport()   // answers nothing: every download fails
        await fetching.open()
        let store = try makeStore(bundledIDs: ["slow-theme"], loaderTransport: offline, fetcherTransport: fetching)
        await store.load()
        let volume = try tempDir()
        let looked = Box()
        let problem = await store.applyAfterInstall(.catalog(id: "slow-theme"), disk: installedDisk(), findVolume: { _ in volume },
                                                   looksFresh: { looked.add($0.path); return true }, deviceIdentifier: onInstalledDisk)
        #expect(problem == .notApplied(problem: DriverError.network("offline").localizedDescription))
        #expect(await fetching.requestCount == 1, "downloaded once, before the check, and not again to apply")
        #expect(looked.values.isEmpty)
        #expect(try snapshot(volume).isEmpty, "nothing was applied")
        // The drive is free again afterwards.
        #expect(try await store.apply(.ventoyDefault, to: volume).isEmpty)
    }

    @Test("a theme that isn't in the catalog or My Themes is reported before the drive is looked at")
    func afterInstallUnknownTheme() async throws {
        let store = try await offlineStore(bundledIDs: ["there"])
        await store.load()
        let volume = try tempDir()
        let looked = Box()
        for choice in [ThemeChoice.catalog(id: "gone"), .custom(id: "custom-gone-12345678")] {
            let id: String
            switch choice { case .catalog(let x), .custom(let x): id = x; case .ventoyDefault: id = "" }
            let problem = await store.applyAfterInstall(choice, disk: installedDisk(), findVolume: { _ in volume },
                                                       looksFresh: { looked.add($0.path); return true }, deviceIdentifier: onInstalledDisk)
            // Not in the list, so the id is all there is to call it by.
            #expect(problem == .themeUnavailable(problem: "“\(id)” is no longer in Mactoy's theme list."))
        }
        #expect(looked.values.isEmpty)
        #expect(try snapshot(volume).isEmpty)
    }

    /// A ZIP with a theme file in it, made with zip(1).
    private func themeZip() throws -> Data {
        let source = try tempDir()
        try Data("title-text: \"x\"\n".utf8).write(to: source.appendingPathComponent("theme.txt"))
        let archive = try tempDir().appendingPathComponent("theme.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", archive.path, "theme.txt"]
        zip.currentDirectoryURL = source
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)
        return try Data(contentsOf: archive)
    }

    /// A store whose catalog holds one theme, "fetched-theme" (named "Fetched"), that downloads as `archive`
    /// through `fetcherTransport`. Also returns the folder the fetcher keeps its downloads in.
    private func storeWithDownloadableTheme(archive: Data, fetcherTransport: any ThemeTransport) async throws -> (ThemeStore, URL) {
        let sha = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        let dir = try tempDir()
        let base = entry("fetched-theme")
        let theme = ThemeEntry(id: base.id, name: "Fetched", author: base.author, homepage: base.homepage, license: base.license,
                               showsVentoyHotkeys: true, notes: nil,
                               download: .init(url: base.download.url, sha256: sha, root: ""), files: nil, settings: .init(file: "theme.txt"))
        let bundled = dir.appendingPathComponent("bundled.json")
        try JSONEncoder().encode(ThemeCatalog(schema: ThemeCatalog.supportedSchema, themes: [theme])).write(to: bundled)
        let offline = GatedTransport()
        await offline.open()
        let cache = dir.appendingPathComponent("themes")
        let store = ThemeStore(loader: ThemeCatalogLoader(transport: offline, cacheDirectory: dir.appendingPathComponent("cache"),
                                                          bundledCatalog: bundled, bundledPreviews: nil),
                               fetcher: ThemeFetcher(transport: fetcherTransport, cacheRoot: cache, bundledRoot: nil),
                               library: ThemeLibrary(root: dir.appendingPathComponent("My Themes")))
        await store.load()
        #expect(store.catalog.map(\.id) == ["fetched-theme"])
        return (store, cache)
    }

    /// Hands out one archive and notes every request.
    private struct RecordingTransport: ThemeTransport {
        let archive: Data
        let log: Box
        func data(from url: URL, maxBytes: Int) async throws -> Data { log.add("download"); return archive }
    }

    @Test("a catalog theme is downloaded once, before the check, and the write uses that download")
    func afterInstallDownloadsOnlyBeforeTheCheck() async throws {
        let archive = try themeZip()
        let log = Box()
        let (store, cache) = try await storeWithDownloadableTheme(archive: archive, fetcherTransport: RecordingTransport(archive: archive, log: log))

        let volume = try tempDir()
        let problem = await store.applyAfterInstall(.catalog(id: "fetched-theme"), disk: installedDisk(), findVolume: { _ in volume },
                                                   looksFresh: { _ in
            log.add("looked")
            // Spoil the cached copy's "complete" marker: asking the fetcher for the theme again would now download it again.
            let files = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            for file in files where file.lastPathComponent == ".complete" { try? FileManager.default.removeItem(at: file) }
            return true
        }, deviceIdentifier: { _ in log.add("device"); return "disk97s2" })
        #expect(problem == addedCleanly)
        #expect(log.values == ["download", "looked", "device"], "nothing is fetched after the drive is looked at")
        #expect(try ThemeInstaller.current(on: volume) == .managed(id: "fetched-theme", name: "Fetched"))
        #expect(FileManager.default.fileExists(atPath: volume.appendingPathComponent("ventoy/themes/mactoy-fetched-theme/theme.txt").path))
    }

    @Test("a second change to the drive is refused while a fresh install's theme is being added")
    func afterInstallHoldsTheDrive() async throws {
        let gate = GatedTransport()
        let offline = GatedTransport()
        await offline.open()
        let store = try makeStore(bundledIDs: ["held-theme"], loaderTransport: offline, fetcherTransport: gate)
        await store.load()
        let volume = try tempDir()
        let identify = onInstalledDisk
        let running = Task {
            await store.applyAfterInstall(.catalog(id: "held-theme"), disk: installedDisk(), findVolume: { _ in volume },
                                          looksFresh: { _ in true }, deviceIdentifier: identify)
        }
        for _ in 0..<500 where await gate.requestCount == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        await #expect(throws: ThemeStoreError.busy) { _ = try await store.apply(.ventoyDefault, to: volume) }
        await gate.open()
        #expect(await running.value == .notApplied(problem: DriverError.network("offline").localizedDescription),
                "the download has no answer, so this one fails")
        #expect(try await store.apply(.ventoyDefault, to: volume).isEmpty, "and the drive is free again")
    }

    // MARK: Themes whose download is gone or changed

    private let tela = "tela"
    private var telaURL: URL { entry(tela).download.url }

    /// A catalog of `ids` whose downloads all have the checksum made of `digit`, so a later list can change it.
    private func catalogData(_ ids: [String], digit: Character) throws -> Data {
        let themes = ids.map { id -> ThemeEntry in
            var e = entry(id)
            e.download.sha256 = String(repeating: digit, count: 64)
            return e
        }
        return try JSONEncoder().encode(ThemeCatalog(schema: ThemeCatalog.supportedSchema, themes: themes))
    }

    /// A store whose bundled list has "tela" (checksum "b…"), with the online list and the downloads both in the test's hands.
    private func scriptedStore(bundledIDs: [String] = ["tela"]) throws -> (store: ThemeStore, list: ScriptedTransport, downloads: ScriptedTransport) {
        let list = ScriptedTransport()
        let downloads = ScriptedTransport()
        return (try makeStore(bundledIDs: bundledIDs, loaderTransport: list, fetcherTransport: downloads), list, downloads)
    }

    private let gone404 = ThemeError.downloadGone(host: "github.com", status: 404)

    private func problem(_ reason: ThemeUnavailable.Reason, digit: Character = "b") -> ThemeUnavailable {
        ThemeUnavailable(reason: reason, downloadURL: telaURL, sha256: String(repeating: digit, count: 64))
    }

    @Test("an apply whose download is gone marks the theme unavailable, with the status")
    func applyGoneMarks() async throws {
        let (store, _, downloads) = try scriptedStore()
        await store.load()
        downloads.answerEverything(.failure(gone404))
        await #expect(throws: gone404) { _ = try await store.apply(.catalog(id: "tela"), to: try tempDir()) }
        #expect(store.unavailableThemes == ["tela": problem(.gone(status: 404))])
        // A 410 says the same, with its own number for the report.
        downloads.answerEverything(.failure(ThemeError.downloadGone(host: "github.com", status: 410)))
        await #expect(throws: ThemeError.self) { _ = try await store.apply(.catalog(id: "tela"), to: try tempDir()) }
        #expect(store.unavailableThemes == ["tela": problem(.gone(status: 410))])
    }

    @Test("a download that doesn't match the list's checksum marks the theme changed")
    func applyChangedMarks() async throws {
        let (store, _, downloads) = try scriptedStore()
        await store.load()
        downloads.answerEverything(.success(Data("not the file the list was written for".utf8)))
        await #expect(throws: ThemeError.self) { _ = try await store.apply(.catalog(id: "tela"), to: try tempDir()) }
        #expect(store.unavailableThemes == ["tela": problem(.changed)])
    }

    @Test("a download that can't be reached marks nothing: that is the connection, not the theme")
    func unreachableDoesNotMark() async throws {
        let (store, _, downloads) = try scriptedStore()
        await store.load()
        let failures: [any Error] = [ThemeError.serverUnreachable(host: "github.com"), DriverError.network("offline"),
                                     URLError(.notConnectedToInternet), ThemeError.downloadTooLarge(70 << 20), ThemeError.missingFile("theme.txt")]
        for failure in failures {
            downloads.answerEverything(.failure(failure))
            await #expect(throws: (any Error).self) { _ = try await store.apply(.catalog(id: "tela"), to: try tempDir()) }
            await store.prefetch(.catalog(id: "tela"))?.value
            let volume = try tempDir()
            let after = await store.applyAfterInstall(.catalog(id: "tela"), disk: installedDisk(), findVolume: { _ in volume },
                                                      looksFresh: { _ in true }, deviceIdentifier: onInstalledDisk)
            guard case .notApplied = after else { Issue.record("\(failure): \(after)"); continue }
            #expect(store.unavailableThemes.isEmpty, "\(failure)")
        }
    }

    @Test("a prefetch whose download is gone marks the theme, so the picker can say so before anything is applied")
    func prefetchMarks() async throws {
        let (store, _, downloads) = try scriptedStore()
        await store.load()
        downloads.answerEverything(.failure(gone404))
        await store.prefetch(.catalog(id: "tela"))?.value
        #expect(store.unavailableThemes == ["tela": problem(.gone(status: 404))])
        // Ventoy's own theme, a saved one, and a theme the list doesn't have download nothing.
        #expect(store.prefetch(.ventoyDefault) == nil)
        #expect(store.prefetch(.custom(id: "custom-x-12345678")) == nil)
        #expect(store.prefetch(.catalog(id: "nope")) == nil)
    }

    @Test("a fresh install's download that is gone or changed marks the theme too")
    func afterInstallMarks() async throws {
        let (store, _, downloads) = try scriptedStore()
        await store.load()
        downloads.answerEverything(.failure(gone404))
        let volume = try tempDir()
        let result = await store.applyAfterInstall(.catalog(id: "tela"), disk: installedDisk(), findVolume: { _ in volume },
                                                   looksFresh: { _ in true }, deviceIdentifier: onInstalledDisk)
        #expect(result == .themeUnavailable(problem: "Mactoy couldn't find “tela” where its theme list says it should be."))
        #expect(store.unavailableThemes == ["tela": problem(.gone(status: 404))])
        #expect(try snapshot(volume).isEmpty, "nothing was written")
    }

    @Test("a later download that works clears the mark: from a prefetch or from an apply")
    func successClears() async throws {
        let archive = try themeZip()
        let gate = ScriptedTransport()
        let (store, cache) = try await storeWithDownloadableTheme(archive: archive, fetcherTransport: gate)
        gate.answerEverything(.failure(gone404))
        await store.prefetch(.catalog(id: "fetched-theme"))?.value
        #expect(store.unavailableThemes.keys.sorted() == ["fetched-theme"])

        gate.answerEverything(.success(archive))
        await store.prefetch(.catalog(id: "fetched-theme"))?.value
        #expect(store.unavailableThemes.isEmpty, "the prefetch worked")

        // The good download is kept on this Mac; clear it so the next one has to go to the server.
        try FileManager.default.removeItem(at: cache)
        gate.answerEverything(.failure(gone404))
        await #expect(throws: gone404) { _ = try await store.apply(.catalog(id: "fetched-theme"), to: try tempDir()) }
        #expect(store.unavailableThemes.keys.sorted() == ["fetched-theme"])
        gate.answerEverything(.success(archive))
        let volume = try tempDir()
        _ = try await store.apply(.catalog(id: "fetched-theme"), to: volume)
        #expect(store.unavailableThemes.isEmpty, "the apply worked")
        #expect(try ThemeInstaller.current(on: volume) == .managed(id: "fetched-theme", name: "Fetched"))
    }

    @Test("a download that works doesn't clear the mark of another theme")
    func successIsPerTheme() async throws {
        let (store, _, downloads) = try scriptedStore(bundledIDs: ["tela", "other"])
        await store.load()
        downloads.answerEverything(.failure(gone404))
        await store.prefetch(.catalog(id: "tela"))?.value
        await store.prefetch(.catalog(id: "other"))?.value
        #expect(store.unavailableThemes.keys.sorted() == ["other", "tela"])
        // "other" still has no good download; a good one for it would leave "tela" marked.
        downloads.answerEverything(.failure(ThemeError.serverUnreachable(host: "github.com")))
        await store.prefetch(.catalog(id: "other"))?.value
        #expect(store.unavailableThemes.keys.sorted() == ["other", "tela"], "an unreachable server doesn't clear a mark either")
    }

    @Test("a list with another download for the theme clears the mark; the same download, or a list without the theme, is judged by its own rules")
    func catalogReloadClears() async throws {
        // Same download: the mark stays.
        do {
            let (store, list, downloads) = try scriptedStore()
            await store.load()
            downloads.answerEverything(.failure(gone404))
            await store.prefetch(.catalog(id: "tela"))?.value
            list.answer(ThemeCatalogLoader.remoteCatalogURL, .success(try catalogData(["tela", "new"], digit: "b")))
            await store.load()
            #expect(store.catalogSource == .remote)
            #expect(store.catalog.map(\.id) == ["tela", "new"])
            #expect(store.unavailableThemes.keys.sorted() == ["tela"], "the list still names the download that failed")
        }
        // A different checksum: the list was fixed, so the theme is worth trying again.
        do {
            let (store, list, downloads) = try scriptedStore()
            await store.load()
            downloads.answerEverything(.failure(gone404))
            await store.prefetch(.catalog(id: "tela"))?.value
            #expect(!store.unavailableThemes.isEmpty)
            list.answer(ThemeCatalogLoader.remoteCatalogURL, .success(try catalogData(["tela"], digit: "c")))
            await store.load()
            #expect(store.catalogSource == .remote)
            #expect(store.unavailableThemes.isEmpty)
            #expect(store.catalog.first?.download.sha256 == String(repeating: "c", count: 64))
        }
        // A different address with the same checksum is another download too.
        do {
            let (store, list, downloads) = try scriptedStore()
            await store.load()
            downloads.answerEverything(.failure(gone404))
            await store.prefetch(.catalog(id: "tela"))?.value
            var moved = entry("tela")
            moved.download.url = URL(string: "https://github.com/a/b/releases/download/v2/x.zip")!
            list.answer(ThemeCatalogLoader.remoteCatalogURL, .success(try JSONEncoder().encode(ThemeCatalog(schema: ThemeCatalog.supportedSchema, themes: [moved]))))
            await store.load()
            #expect(store.unavailableThemes.isEmpty)
        }
        // The theme is gone from the list: nothing left to mark.
        do {
            let (store, list, downloads) = try scriptedStore()
            await store.load()
            downloads.answerEverything(.failure(gone404))
            await store.prefetch(.catalog(id: "tela"))?.value
            list.answer(ThemeCatalogLoader.remoteCatalogURL, .success(try catalogData(["new"], digit: "b")))
            await store.load()
            #expect(store.catalog.map(\.id) == ["new"])
            #expect(store.unavailableThemes.isEmpty)
        }
    }

    @Test("a failure for a download the list has replaced since doesn't mark the new entry")
    func staleFailureIsIgnored() async throws {
        let list = ScriptedTransport()
        let gate = GatedTransport()   // holds the download until the test opens it
        let downloads = ScriptedTransport(gate: gate)
        let store = try makeStore(bundledIDs: ["tela"], loaderTransport: list, fetcherTransport: downloads)
        await store.load()
        downloads.answerEverything(.failure(gone404))
        let pending = store.prefetch(.catalog(id: "tela"))
        // The list is fixed while that download is still waiting.
        list.answer(ThemeCatalogLoader.remoteCatalogURL, .success(try catalogData(["tela"], digit: "c")))
        await store.load()
        #expect(store.catalog.first?.download.sha256 == String(repeating: "c", count: 64))
        await gate.open()
        await pending?.value
        #expect(store.unavailableThemes.isEmpty, "the failure was about the old download")
    }

    @Test("a theme that leaves the list keeps its name, so what is said about it isn't an id")
    func nameOutlivesTheList() async throws {
        let dir = try tempDir()
        var named = entry("tela")
        named.name = "Tela"
        let bundled = dir.appendingPathComponent("bundled.json")
        try JSONEncoder().encode(ThemeCatalog(schema: ThemeCatalog.supportedSchema, themes: [named])).write(to: bundled)
        let list = ScriptedTransport()
        let store = ThemeStore(loader: ThemeCatalogLoader(transport: list, cacheDirectory: dir.appendingPathComponent("cache"),
                                                          bundledCatalog: bundled, bundledPreviews: nil),
                               fetcher: ThemeFetcher(transport: ScriptedTransport(), cacheRoot: dir.appendingPathComponent("themes"), bundledRoot: nil),
                               library: ThemeLibrary(root: dir.appendingPathComponent("My Themes")))
        await store.load()
        #expect(store.displayName(for: .catalog(id: "tela")) == "Tela")
        // The online list arrives without it.
        list.answer(ThemeCatalogLoader.remoteCatalogURL, .success(try catalogData(["other"], digit: "b")))
        await store.load()
        #expect(store.catalog.map(\.id) == ["other"])
        #expect(store.displayName(for: .catalog(id: "tela")) == "Tela", "known from the list it came from")
        #expect(store.displayName(for: .catalog(id: "never-seen")) == "never-seen", "an id nobody named is all there is")
        #expect(store.message(for: ThemeError.unknownTheme("tela"), choice: .catalog(id: "tela"))
            == "“Tela” is no longer in Mactoy's theme list. Choose another theme.")
        // And after an install:
        let volume = try tempDir()
        let result = await store.applyAfterInstall(.catalog(id: "tela"), disk: installedDisk(), findVolume: { _ in volume },
                                                   looksFresh: { _ in true }, deviceIdentifier: onInstalledDisk)
        #expect(result == .themeUnavailable(problem: "“Tela” is no longer in Mactoy's theme list."))
        #expect(store.unavailableThemes.isEmpty, "a theme that left the list is not a download that failed")
    }

    @Test("after an install, a theme whose download changed is named in the problem")
    func afterInstallChanged() async throws {
        let archive = try themeZip()
        let (store, _) = try await storeWithDownloadableTheme(archive: archive, fetcherTransport: ScriptedTransport(.success(Data("changed".utf8))))
        let volume = try tempDir()
        let result = await store.applyAfterInstall(.catalog(id: "fetched-theme"), disk: installedDisk(), findVolume: { _ in volume },
                                                   looksFresh: { _ in true }, deviceIdentifier: onInstalledDisk)
        #expect(result == .themeUnavailable(problem: "“Fetched” has changed since it was added to Mactoy's theme list, so Mactoy didn't use it."))
        #expect(store.unavailableThemes.keys.sorted() == ["fetched-theme"])
        #expect(try snapshot(volume).isEmpty, "nothing was written")
    }

    @Test("after an install, a server that can't be reached is told as it is, and the theme can be added later")
    func afterInstallUnreachable() async throws {
        let (store, _, downloads) = try scriptedStore()
        await store.load()
        downloads.answerEverything(.failure(ThemeError.serverUnreachable(host: "github.com")))
        let volume = try tempDir()
        let result = await store.applyAfterInstall(.catalog(id: "tela"), disk: installedDisk(), findVolume: { _ in volume },
                                                   looksFresh: { _ in true }, deviceIdentifier: onInstalledDisk)
        #expect(result == .notApplied(problem: "Couldn't reach github.com. Check your internet connection and try again."))
        #expect(store.unavailableThemes.isEmpty)
    }

}

/// A thread-safe list for closures that must be `@Sendable`.
fileprivate final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ value: String) { lock.lock(); items.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Answers each request with whatever the test last said. Unknown addresses fail like an offline network.
fileprivate final class ScriptedTransport: ThemeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [URL: Result<Data, any Error>] = [:]
    private var everything: Result<Data, any Error> = .failure(DriverError.network("offline"))
    private let gate: ThemeStoreTests.GatedTransport?

    /// `gate` holds each request until the test opens it, as `GatedTransport` does.
    init(_ everything: Result<Data, any Error>? = nil, gate: ThemeStoreTests.GatedTransport? = nil) {
        if let everything { self.everything = everything }
        self.gate = gate
    }

    func answer(_ url: URL, _ result: Result<Data, any Error>) { lock.lock(); answers[url] = result; lock.unlock() }
    func answerEverything(_ result: Result<Data, any Error>) { lock.lock(); everything = result; lock.unlock() }

    private func answer(for url: URL) -> Result<Data, any Error> {
        lock.lock(); defer { lock.unlock() }
        return answers[url] ?? everything
    }

    func data(from url: URL, maxBytes: Int) async throws -> Data {
        // The answer is read when the request is made, so a held request keeps the answer it started with.
        let result = answer(for: url)
        if let gate { _ = try? await gate.data(from: url, maxBytes: maxBytes) }
        return try result.get()
    }
}
