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
    private func makeStore(bundledIDs: [String], loaderTransport: any ThemeTransport,
                           fetcherTransport: any ThemeTransport) throws -> ThemeStore {
        let dir = try tempDir()
        let bundled = dir.appendingPathComponent("bundled.json")
        try catalogData(bundledIDs).write(to: bundled)
        let loader = ThemeCatalogLoader(transport: loaderTransport, cacheDirectory: dir.appendingPathComponent("cache"),
                                        bundledCatalog: bundled, bundledPreviews: nil)
        let fetcher = ThemeFetcher(transport: fetcherTransport, cacheRoot: dir.appendingPathComponent("themes"), bundledRoot: nil)
        return ThemeStore(loader: loader, fetcher: fetcher)
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
}
