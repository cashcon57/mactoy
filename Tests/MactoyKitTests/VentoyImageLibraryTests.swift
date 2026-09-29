import Foundation
import Testing
@testable import MactoyKit

@Suite("Ventoy image library")
struct VentoyImageLibraryTests {
    @Test func detectsImagesAndFiltersUnrelatedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images/linux"), withIntermediateDirectories: true)
        for path in ["images/linux/Ubuntu.ISO", "images/windows.img", "images/notes.txt", "images/._hidden.iso", "unrelated.iso"] {
            try Data().write(to: root.appendingPathComponent(path))
        }
        #expect(VentoyImageLibrary.imageDirectory(on: root).lastPathComponent == "images")
        #expect(Set(VentoyImageLibrary.images(on: root).map(\.lastPathComponent)) == ["Ubuntu.ISO", "windows.img"])
    }

    @Test func configPrecedenceAndFallbacks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["ventoy", "images", "custom"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let config = Data(#"{"control":[{"VTOY_DEFAULT_SEARCH_ROOT":"/custom"}]}"#.utf8)
        try config.write(to: root.appendingPathComponent("ventoy.json"))
        #expect(VentoyImageLibrary.imageDirectory(on: root).lastPathComponent == "custom")
        try Data(#"{"control":[{"VTOY_DEFAULT_SEARCH_ROOT":"/images"}]}"#.utf8).write(to: root.appendingPathComponent("ventoy/ventoy.json"))
        #expect(VentoyImageLibrary.imageDirectory(on: root).lastPathComponent == "images")
        try Data(#"{"control":[{"VTOY_DEFAULT_SEARCH_ROOT":"/../../"}]}"#.utf8).write(to: root.appendingPathComponent("ventoy/ventoy.json"))
        try Data("invalid".utf8).write(to: root.appendingPathComponent("ventoy.json"))
        #expect(VentoyImageLibrary.imageDirectory(on: root).lastPathComponent == "images")
        try FileManager.default.removeItem(at: root.appendingPathComponent("images"))
        #expect(VentoyImageLibrary.imageDirectory(on: root) == root.resolvingSymlinksInPath().standardizedFileURL)
    }
}
