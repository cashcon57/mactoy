import Testing
import Foundation
@testable import Mactoy
import MactoyKit

/// What the Manage Disk theme section learns from a drive.
@Suite("Drive theme reader")
struct DriveThemeReaderTests {

    private func volume(json: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mactoy-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ventoy"), withIntermediateDirectories: true)
        if let json { try Data(json.utf8).write(to: root.appendingPathComponent("ventoy/ventoy.json")) }
        return root
    }

    @Test("no ventoy.json means the Ventoy default")
    func noConfig() throws {
        let snapshot = DriveThemeReader.read(try volume())
        #expect(snapshot.current == .ventoyDefault)
        #expect(snapshot.error == nil)
        #expect(!snapshot.readOnly)
    }

    @Test("a theme the user set up is reported as theirs, with its path")
    func ownTheme() throws {
        let snapshot = DriveThemeReader.read(try volume(json: #"{ "theme": { "file": "/ventoy/themes/mine/theme.txt" } }"#))
        #expect(snapshot.current == .other(file: "/ventoy/themes/mine/theme.txt"))
    }

    @Test("a damaged ventoy.json is an error, not the Ventoy default")
    func damagedConfig() throws {
        let snapshot = DriveThemeReader.read(try volume(json: #"{ "theme": "#))
        #expect(snapshot.current == nil)
        #expect(snapshot.error != nil)
    }
}
