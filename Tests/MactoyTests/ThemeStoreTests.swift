import AppKit
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

}
