import CryptoKit
import Foundation

/// Makes an installable theme from whatever the user picked: a `.zip`, a
/// folder, or a theme's `theme.txt`. The theme may sit at the top of that or
/// anywhere below it. Same file rules as catalog themes (`ThemeAssembler`).
public enum CustomThemeImporter {
    public static let maxZipBytes = 64 * 1024 * 1024
    /// The most themes listed to choose from when a download holds several.
    public static let maxChoices = 20
    static let unzipTimeout: TimeInterval = 60
    static let listTimeout: TimeInterval = 20
    /// A `ventoy.json` is a few KB; this keeps a hostile one from being parsed at all.
    static let maxVentoyJSONBytes = 256 * 1024
    static let maxVentoyJSONFiles = 16
    static let maxPackFonts = 32

    public struct Imported: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let directory: URL
        public let settings: ThemeEntry.Settings
        public let previewImage: URL?
        public let skippedFiles: [String]
    }

    /// One of several themes in a source, as a list shows it.
    public struct Choice: Sendable, Equatable, Hashable, Identifiable {
        /// The theme's folder inside the source: what `importTheme(from:themeRoot:)` takes.
        public let folder: String
        /// The folder's name made readable: "catppuccin-mocha" becomes "Catppuccin Mocha".
        public let name: String
        /// The whole folder path, minus the one top folder every theme shares (a download's `grub-<sha>/`),
        /// so a pack's plain GRUB copy of a theme and its Ventoy one can be told apart.
        public let path: String
        /// Made for Ventoy: a `ventoy` folder is somewhere in its path, or a `ventoy.json` in the source points at it.
        public let isForVentoy: Bool
        public var id: String { folder }
    }

    /// A ZIP, folder or theme.txt, read once. Everything is held in memory (never more than
    /// the unpacked-size cap), so choosing between its themes doesn't read it again, and
    /// nothing is left on disk.
    public struct Opened: Sendable {
        let files: [ThemeSourceFile]
        let baseName: String
        /// The theme to use when one clearly wins; nil when the user has to choose.
        let singleRoot: String?
        /// Every theme folder in the order they were found (shallowest first), when the user has to choose; empty otherwise.
        let themeFolders: [String]
        /// Every theme folder as a list shows it, ones made for Ventoy first and then by name; empty unless the user has to choose.
        public let choices: [Choice]

        public var needsChoice: Bool { singleRoot == nil }

        /// The theme.txt of each theme folder, which is how `ThemeError.ambiguousThemes` names them.
        public var themeFilePaths: [String] { themeFolders.map { $0 + "/theme.txt" } }
    }

    // MARK: entry points

    public static func importTheme(from source: URL, cacheRoot: URL = ThemeFetcher.defaultCacheRoot()) throws -> Imported {
        try importTheme(from: source, themeRoot: nil, cacheRoot: cacheRoot, workRoot: FileManager.default.temporaryDirectory)
    }

    /// For a source with several themes: imports the one in `themeRoot`, a folder path inside
    /// the source ("" is the source's top). Any folder that holds a `theme.txt` will do, not
    /// only the ones `Opened.choices` lists.
    public static func importTheme(from source: URL, themeRoot: String, cacheRoot: URL = ThemeFetcher.defaultCacheRoot()) throws -> Imported {
        try importTheme(from: source, themeRoot: themeRoot, cacheRoot: cacheRoot, workRoot: FileManager.default.temporaryDirectory)
    }

    /// `workRoot` is where a ZIP is unpacked, so tests can see that nothing is left there.
    static func importTheme(from source: URL, themeRoot: String? = nil, cacheRoot: URL, workRoot: URL) throws -> Imported {
        try importTheme(try open(source, workRoot: workRoot, rootKnown: themeRoot != nil), themeRoot: themeRoot, cacheRoot: cacheRoot)
    }

    /// Reads the source (unpacking a ZIP) and finds its theme or themes. Throws
    /// `noThemeFile` when it has none and `tooManyThemes` when it has more than `maxChoices`.
    public static func open(_ source: URL) throws -> Opened {
        try open(source, workRoot: FileManager.default.temporaryDirectory)
    }

    /// `rootKnown`: the caller names the theme folder, so how many themes there are doesn't matter
    /// and the result is only for `importTheme(_:themeRoot:)`. `topFolders` are the folders a loose
    /// `theme.txt` is refused in (see `looseFolderName`); tests name their own, and nil means the user's.
    static func open(_ source: URL, workRoot: URL, rootKnown: Bool = false, topFolders: [TopFolder]? = nil) throws -> Opened {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let isFolder = fm.fileExists(atPath: source.path, isDirectory: &isDirectory) && isDirectory.boolValue
        let read: [ThemeSourceFile]
        let baseName: String
        if isFolder {
            // A link to a folder enumerates as empty, so read the folder it points to; the name stays what the user picked.
            read = try ThemeAssembler.files(fromFolder: source.resolvingSymlinksInPath())
            baseName = source.lastPathComponent
        } else if source.lastPathComponent == "theme.txt" {
            // The theme file itself stands for its folder. Only the folder holding it is resolved: a theme.txt
            // that is a link points somewhere else, and nothing it points to is read (as for every file in a theme).
            guard ThemeInstaller.fileType(source) == .typeRegular else { throw ThemeError.noThemeFile }
            let folder = source.deletingLastPathComponent().resolvingSymlinksInPath()
            // Its folder is all that is read, and in Downloads that is everything the user has put there.
            if let name = looseFolderName(folder, in: topFolders ?? Self.topFolders()) { throw ThemeError.looseThemeFile(folder: name) }
            read = try ThemeAssembler.files(fromFolder: folder)
            baseName = folder.lastPathComponent
        } else if source.pathExtension.lowercased() == "zip" || hasZipSignature(source) || !fm.fileExists(atPath: source.path) {
            // A missing file goes this way too, to be reported as unreadable like any other bad archive.
            read = try unpackedFiles(fromZip: source, workRoot: workRoot)
            baseName = source.deletingPathExtension().lastPathComponent
        } else {
            // Another .txt, a picture, a .7z: none of them is a theme.
            throw ThemeError.unsupportedSource
        }
        // Finder's ZIPs carry a __MACOSX copy of the tree; it must neither be a theme nor change the digest.
        var files = read.filter { !isJunk($0.path) }
        if rootKnown { return Opened(files: files, baseName: baseName, singleRoot: nil, themeFolders: [], choices: []) }
        switch try findThemes(in: files.map(\.path)) {
        case .one(let root):
            return Opened(files: files, baseName: baseName, singleRoot: root, themeFolders: [], choices: [])
        case .several(let folders):
            // What is held while the user chooses: the themes, and the ventoy.json files that describe them.
            files = files.filter { file in
                isVentoyJSON(file.path) || folders.contains { file.path.hasPrefix($0 + "/") }
            }
            return Opened(files: files, baseName: baseName, singleRoot: nil, themeFolders: folders,
                          choices: choices(for: folders, in: files))
        }
    }

    // MARK: a theme.txt picked on its own

    /// A folder of the user's own, with what to call it in a message.
    struct TopFolder {
        let name: String
        let url: URL
    }

    /// The folders a theme.txt must not sit loose in: the user's home, Downloads, Desktop and Documents, and the
    /// disk's own top level. Picking a theme.txt means "the theme in this folder", so in one of these it would
    /// mean reading (and keeping) whatever else the user has there.
    static func topFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [TopFolder] {
        [TopFolder(name: "your home folder", url: home),
         TopFolder(name: "Downloads", url: home.appendingPathComponent("Downloads", isDirectory: true)),
         TopFolder(name: "Desktop", url: home.appendingPathComponent("Desktop", isDirectory: true)),
         TopFolder(name: "Documents", url: home.appendingPathComponent("Documents", isDirectory: true)),
         TopFolder(name: "the top level of the disk", url: URL(fileURLWithPath: "/", isDirectory: true))]
    }

    /// What `folder` is called when it is one of `topFolders`, else nil. Links are resolved on both sides (a Downloads
    /// folder can be a link to another volume), and names are compared without regard to case, as on the disk.
    static func looseFolderName(_ folder: URL, in topFolders: [TopFolder]) -> String? {
        func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        let path = canonical(folder)
        return topFolders.first { canonical($0.url).caseInsensitiveCompare(path) == .orderedSame }?.name
    }

    /// Imports the theme in `themeRoot` (see `importTheme(from:themeRoot:)`), or the only theme when
    /// `themeRoot` is nil. With several themes and no `themeRoot` it throws `ambiguousThemes`.
    public static func importTheme(_ opened: Opened, themeRoot: String? = nil,
                                   cacheRoot: URL = ThemeFetcher.defaultCacheRoot()) throws -> Imported {
        let files = opened.files
        let root: String
        if let themeRoot {
            root = try checkedRoot(themeRoot, in: files)
        } else if let single = opened.singleRoot {
            root = single
        } else {
            throw ThemeError.ambiguousThemes(opened.themeFilePaths)
        }
        let fm = FileManager.default
        let name = root.isEmpty ? opened.baseName : ThemeAssembler.last(root)
        let id = "custom-" + slug(name)
        let prefix = root.isEmpty ? "" : root + "/"
        let digest = contentDigest(files.filter { $0.path.hasPrefix(prefix) }.map { ThemeSourceFile(path: String($0.path.dropFirst(prefix.count)), data: $0.data) })

        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let directory = cacheRoot.appendingPathComponent("\(id)-\(digest)", isDirectory: true)
        let staging = cacheRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        // Always assembled: that is what yields `skippedFiles`, and it is what
        // an existing folder is checked against.
        var skipped = try ThemeAssembler.assemble(files, root: root, mappings: nil, into: staging)
        // The folder name says what went in, but the folder itself may have
        // been edited or built by an older Mactoy. Keep an intact one (it may
        // be in use); replace anything else.
        // attributesOfItem doesn't follow links, so a dangling link counts as in the way.
        if (try? fm.attributesOfItem(atPath: directory.path)) != nil {
            if !sameContents(directory, staging) {
                try fm.removeItem(at: directory)
                try fm.moveItem(at: staging, to: directory)
            }
        } else {
            try fm.moveItem(at: staging, to: directory)
        }

        let fonts = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".pf2") }.sorted()
        var settings = ThemeEntry.Settings(file: "theme.txt", fonts: fonts.isEmpty ? nil : fonts)
        if let pack = packSettings(forRoot: root, in: files) {
            // The pack's own choices, held to the catalog's rules. Fonts it doesn't name (or names
            // wrongly) fall back to the ones that sit beside theme.txt.
            var wanted = pack.settings
            if wanted.fonts?.isEmpty != false { wanted.fonts = settings.fonts }
            if var checked = try? ThemeLibrary.settings(wanted, keptIn: directory) {
                if checked.fonts == nil { checked.fonts = settings.fonts }
                settings = checked
            }
            // It was read, not left out.
            if pack.source.hasPrefix(prefix) { skipped.removeAll { $0 == String(pack.source.dropFirst(prefix.count)) } }
        }
        let themeText = (try? String(contentsOf: directory.appendingPathComponent("theme.txt"), encoding: .utf8)) ?? ""
        let preview = backgroundImage(inThemeText: themeText)
            .map { directory.appendingPathComponent($0) }
            .flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
        return Imported(id: id, name: name, directory: directory, settings: settings,
                        previewImage: preview, skippedFiles: skipped)
    }

    // MARK: ZIP

    /// Whether the file starts like a ZIP, for one that isn't named .zip (a browser may add or drop an extension).
    private static func hasZipSignature(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4) else { return false }
        // A local file header, or the end record of an empty archive.
        return head.elementsEqual([0x50, 0x4B, 0x03, 0x04]) || head.elementsEqual([0x50, 0x4B, 0x05, 0x06])
    }

    /// Unpacks with `ditto` in a throwaway private folder, then reads that
    /// folder like any other. The in-process ZIP reader traps (ending the
    /// whole app) on some malformed archives, so a file the user picked never
    /// goes through it; a bad archive here only makes `ditto` exit.
    ///
    /// The archive's own file list is checked first (`checkArchive`), because
    /// `ditto` writes everything it is given and the size caps in
    /// `files(fromFolder:)` apply only after that. Past that check, `ditto`
    /// still writes nothing outside the folder it is given and won't write
    /// through a stored link; unpacking into a subfolder keeps even a stray
    /// name inside the private folder. Links it does create are skipped when
    /// the folder is read.
    private static func unpackedFiles(fromZip zip: URL, workRoot: URL) throws -> [ThemeSourceFile] {
        // Size of the file itself, not of a link to it.
        let resolved = zip.resolvingSymlinksInPath()
        let size = (try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxZipBytes else { throw ThemeError.fileTooLarge(size) }
        try checkArchive(resolved)

        let fm = FileManager.default
        let work = try makePrivateDirectory(in: workRoot)
        defer { try? fm.removeItem(at: work) }
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        do {
            // No resource forks, extended attributes or quarantine flag: only file contents are wanted.
            try Subprocess.runChecked("/usr/bin/ditto",
                                      ["-x", "-k", "--norsrc", "--noextattr", "--noqtn", resolved.path, unpacked.path],
                                      timeout: unzipTimeout)
        } catch {
            throw ThemeError.unreadableArchive(shortReason(error, hiding: [work.resolvingSymlinksInPath().path, work.path]))
        }
        return try ThemeAssembler.files(fromFolder: unpacked)
    }

    // MARK: ZIP file list

    struct ListedEntry: Equatable {
        let name: String
        let size: Int
    }

    /// Reads the archive's central directory with `zipinfo` (a separate process,
    /// like `ditto`) and refuses it before anything is written to disk if it
    /// has too many entries, declares too much data, or names a file outside
    /// the folder. An archive that lies about its sizes still gets through
    /// this; it is bounded only by `unzipTimeout` (accepted risk).
    private static func checkArchive(_ zip: URL) throws {
        let result: SubprocessResult
        do {
            result = try Subprocess.run("/usr/bin/zipinfo", ["-l", zip.path], timeout: listTimeout)
        } catch {
            throw ThemeError.unreadableArchive(shortReason(error, hiding: []))
        }
        // Status 1 is a warning (an empty archive is one) that still comes with a full list.
        guard result.status == 0 || result.status == 1 else {
            throw ThemeError.unreadableArchive("it doesn't look like a ZIP file")
        }
        let entries = try parseListing(result.stdout)
        guard !entries.isEmpty else { throw ThemeError.noThemeFile }
        try checkListing(entries)
    }

    /// Entries from `zipinfo -l` output:
    ///
    ///     Zip file size: 1706 bytes, number of entries: 2
    ///     -rw-r--r--  3.0 unx       15 tx       15 stor 26-Oct-26 19:17 pack/theme.txt
    ///     ...
    ///     2 files, 164 bytes uncompressed, 164 bytes compressed:  0.0%
    ///
    /// The mode column is 10 characters for Unix archives and 7 for Windows ones,
    /// so only its first character is checked. `zipinfo` escapes control and
    /// non-ASCII characters in names, so a name can't span lines. Anything that
    /// doesn't fit, or a line count that differs from the declared one, throws.
    static func parseListing(_ output: String) throws -> [ListedEntry] {
        let unreadable = ThemeError.unreadableArchive("its file list couldn't be read")
        let lines = output.split(whereSeparator: \.isNewline)
        guard let header = lines.firstIndex(where: { $0.hasPrefix("Zip file size:") }),
              let marker = lines[header].range(of: #"number of entries: [0-9]+$"#, options: .regularExpression),
              let declared = Int(lines[header][marker].dropFirst("number of entries: ".count))
        else { throw unreadable }
        if declared == 0 { return [] }
        var entries: [ListedEntry] = []
        for line in lines[(header + 1)...] {
            // The totals line ("12 files, ...") ends the list; entry lines start with a mode.
            if line.first?.isNumber == true { break }
            // mode, version, OS, size, flags, packed size, method, date, time, then the name.
            let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
            guard fields.count == 10, "-dlbcps?".contains(fields[0].first ?? " "),
                  let size = byteCount(fields[3]), byteCount(fields[5]) != nil
            else { throw unreadable }
            entries.append(ListedEntry(name: String(fields[9]), size: size))
        }
        guard entries.count == declared else { throw unreadable }
        return entries
    }

    /// Digits only. A number too big for an Int becomes `Int.max`, which the size limit then refuses.
    private static func byteCount(_ field: Substring) -> Int? {
        guard !field.isEmpty, field.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(field) ?? Int.max
    }

    /// The same count and size limits as `files(fromZip:)`, plus no absolute
    /// names and no `..` components (`ditto` would quietly rewrite those).
    static func checkListing(_ entries: [ListedEntry]) throws {
        guard entries.count <= ThemeAssembler.maxFiles * 2 else { throw ThemeError.tooManyFiles(entries.count) }
        try ThemeAssembler.checkDeclaredSizes(entries.map(\.size))
        let unsafe = entries.contains { $0.name.hasPrefix("/") || $0.name.split(separator: "/", omittingEmptySubsequences: false).contains("..") }
        if unsafe { throw ThemeError.unreadableArchive("it has unsafe file names") }
    }

    /// A new, empty folder only the current user can enter.
    static func makePrivateDirectory(in parent: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let dir = parent.appendingPathComponent("mactoy-unzip-\(UUID().uuidString)", isDirectory: true)
        // No intermediates, so a name that is already taken fails instead of being reused.
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// One line the user can read: the tool's complaint without our temp paths.
    static func shortReason(_ error: Error, hiding paths: [String]) -> String {
        guard case DriverError.subprocess(_, let status, let stderr) = error else { return error.localizedDescription }
        if status == -1, stderr.hasPrefix("timeout") { return "it took too long to read" }
        // ditto reports the real path (/private/var/...), so the resolved form goes first.
        var text = stderr
        for path in paths { text = text.replacingOccurrences(of: path + "/unpacked/", with: "").replacingOccurrences(of: path, with: "") }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard var reason = line else { return "unpacking failed with status \(status)" }
        if reason.hasPrefix("ditto: ") { reason.removeFirst("ditto: ".count) }
        return String(reason.prefix(120))
    }

    // MARK: cache

    /// 12 hex characters of SHA-256 over every file (path and bytes) under the
    /// theme folder, whether or not it will be kept. Lengths go in too, so a
    /// path can't swallow the start of its file's bytes.
    static func contentDigest(_ files: [ThemeSourceFile]) -> String {
        var hasher = SHA256()
        func addLength(_ n: Int) { withUnsafeBytes(of: UInt64(n).bigEndian) { hasher.update(bufferPointer: $0) } }
        for f in files.sorted(by: { $0.path < $1.path }) {
            let path = Data(f.path.utf8)
            addLength(path.count); hasher.update(data: path)
            addLength(f.data.count); hasher.update(data: f.data)
        }
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    private static func sameContents(_ a: URL, _ b: URL) -> Bool {
        guard let x = try? ThemeAssembler.files(fromFolder: a), let y = try? ThemeAssembler.files(fromFolder: b) else { return false }
        return x.sorted { $0.path < $1.path } == y.sorted { $0.path < $1.path }
    }

    // MARK: reading the theme

    /// Files that only the machine that made the archive wanted: Finder's resource-fork copy
    /// of the tree (`__MACOSX/`), AppleDouble `._*` files and `.DS_Store`.
    static func isJunk(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == "__MACOSX" || $0 == ".DS_Store" || $0.hasPrefix("._") }
    }

    enum FoundThemes: Equatable {
        /// The folder of the one theme to use ("" is the source's top).
        case one(String)
        /// Every folder that holds a theme.txt, shallowest first.
        case several([String])
    }

    /// The theme folder: the one holding the shallowest `theme.txt`. When several are equally
    /// shallow there is no telling which is meant, so every folder with a `theme.txt` is offered
    /// (a pack often has a plain GRUB copy of each theme beside its Ventoy one).
    static func findThemes(in paths: [String]) throws -> FoundThemes {
        let texts = Set(paths.filter { ($0 == "theme.txt" || $0.hasSuffix("/theme.txt")) && ThemePath.isSafeRelative($0) })
            .map { (path: $0, depth: $0.split(separator: "/").count) }
            .sorted { ($0.depth, $0.path) < ($1.depth, $1.path) }
        guard let shallowest = texts.first else { throw ThemeError.noThemeFile }
        if texts.filter({ $0.depth == shallowest.depth }).count == 1 { return .one(ThemeAssembler.parent(shallowest.path)) }
        guard texts.count <= maxChoices else { throw ThemeError.tooManyThemes(texts.count) }
        return .several(texts.map { ThemeAssembler.parent($0.path) })
    }

    /// Folder holding the shallowest `theme.txt`; throws `ambiguousThemes`, naming each
    /// `theme.txt` that could be meant, when there is no single one.
    static func themeRoot(in paths: [String]) throws -> String {
        switch try findThemes(in: paths) {
        case .one(let root): return root
        case .several(let folders): throw ThemeError.ambiguousThemes(folders.map { $0 + "/theme.txt" })
        }
    }

    /// `root` as a folder path with no slash at either end, once it is known to hold a theme.txt.
    private static func checkedRoot(_ root: String, in files: [ThemeSourceFile]) throws -> String {
        var path = root
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        if path == "." { path = "" }
        guard path.isEmpty || ThemePath.isSafeRelative(path) else { throw ThemeError.rootNotFound(root) }
        let prefix = path.isEmpty ? "" : path + "/"
        if files.contains(where: { $0.path == prefix + "theme.txt" }) { return path }
        // A folder that exists but has no theme.txt is a different problem from one that isn't there.
        throw files.contains { $0.path.hasPrefix(prefix) } ? ThemeError.noThemeFile : ThemeError.rootNotFound(root)
    }

    /// The folders as a list shows them: made for Ventoy first, then by name (a tie goes by path, so the
    /// order never depends on how the source was read). `files` is where a `ventoy.json` is looked for.
    static func choices(for folders: [String], in files: [ThemeSourceFile] = []) -> [Choice] {
        let shared = sharedTopFolder(of: folders)
        return folders.map { folder in
            let parts = folder.split(separator: "/").map(String.init)
            // Folder names come from an archive: no hidden or direction-changing characters in a list.
            let last = ThemeLibrary.cleaned(parts.last ?? folder, limit: ThemeLibrary.maxNameLength, fallback: "Theme")
            let readable = readableName(last)
            let shown = shared.map { String(folder.dropFirst($0.count + 1)) } ?? folder
            return Choice(folder: folder, name: readable.isEmpty ? last : readable,
                          path: ThemeLibrary.cleaned(shown, limit: 200, fallback: last),
                          isForVentoy: isMadeForVentoy(folder, in: files))
        }
        .sorted { a, b in
            if a.isForVentoy != b.isForVentoy { return a.isForVentoy }
            let byName = a.name.compare(b.name, options: [.caseInsensitive, .numeric])
            return byName == .orderedSame ? a.folder < b.folder : byName == .orderedAscending
        }
    }

    /// The one folder every path starts with ("grub-<sha>" in a GitHub download), when each path is
    /// somewhere below it. Only that one level: further shared folders are part of where a theme is.
    static func sharedTopFolder(of folders: [String]) -> String? {
        let tops = folders.map { $0.split(separator: "/", omittingEmptySubsequences: false) }
        guard let top = tops.first?.first, !top.isEmpty, tops.allSatisfy({ $0.count > 1 && $0.first == top }) else { return nil }
        return String(top)
    }

    /// Whether the theme in `folder` was made for Ventoy: a `ventoy` folder (in any case) is somewhere in its path,
    /// or a `ventoy.json` in `files` has a `theme` setting that points into it.
    static func isMadeForVentoy(_ folder: String, in files: [ThemeSourceFile]) -> Bool {
        if folder.split(separator: "/").contains(where: { $0.lowercased() == "ventoy" }) { return true }
        return packSettings(forRoot: folder, in: files) != nil
    }

    /// "catppuccin-mocha" becomes "Catppuccin Mocha". A name that already has capitals keeps them.
    static func readableName(_ folder: String) -> String {
        folder.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: ventoy.json beside the theme

    static func isVentoyJSON(_ path: String) -> Bool { ThemeAssembler.last(path) == "ventoy.json" }

    /// What a pack's own `ventoy.json` says about the theme in `root`, if it has a `theme`
    /// that points into that folder. `settings.file` is always `theme.txt`; the values are
    /// the pack's, and `ThemeLibrary.settings(_:keptIn:)` is what holds them to the catalog's
    /// rules. `source` is the `ventoy.json` that was read.
    ///
    /// A pack's paths are paths on a drive, where `ventoy.json` lives in `/ventoy/`. So a path
    /// in it is looked for with the folder holding the `ventoy.json` standing in for `/ventoy/`
    /// (`ventoy/ventoy.json` and `/ventoy/pop/theme.txt` give `ventoy/pop/theme.txt`), and
    /// failing that for the same folder standing in for the drive's root. Whichever way the
    /// theme file is found is the way its fonts are read. Names are matched without regard to
    /// case, as on the drive. The other keys (`control`, `menu_alias` and the rest) are ignored.
    static func packSettings(forRoot root: String, in files: [ThemeSourceFile]) -> (settings: ThemeEntry.Settings, source: String)? {
        let known = Dictionary(files.map { ($0.path.lowercased(), $0.path) }, uniquingKeysWith: { first, _ in first })
        let configs = files
            .filter { isVentoyJSON($0.path) && $0.data.count <= maxVentoyJSONBytes }
            // The deepest first: the one closest to a theme says more about it than a pack-wide one.
            .sorted { a, b in
                let (depthA, depthB) = (a.path.split(separator: "/").count, b.path.split(separator: "/").count)
                return depthA != depthB ? depthA > depthB : a.path < b.path
            }
            .prefix(maxVentoyJSONFiles)
        for config in configs {
            guard let theme = themeObject(in: config.data) else { continue }
            let folder = ThemeAssembler.parent(config.path)
            for standing in [Standing.ventoyFolder, .driveRoot] {
                func find(_ drivePath: String) -> String? {
                    sourcePath(of: drivePath, configFolder: folder, standing: standing).flatMap { known[$0.lowercased()] }
                }
                // A file in the theme's own folder, so this is the setting for that theme and not another's.
                guard stringList(theme["file"]).compactMap(find).contains(where: { ThemeAssembler.parent($0) == root }) else { continue }
                let prefix = root.isEmpty ? "" : root + "/"
                let fonts = stringList(theme["fonts"]).compactMap(find)
                    .filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
                return (ThemeEntry.Settings(file: "theme.txt", fonts: fonts.isEmpty ? nil : Array(fonts.prefix(maxPackFonts)),
                                            gfxmode: theme["gfxmode"] as? String,
                                            ventoyLeft: theme["ventoy_left"] as? String,
                                            ventoyTop: theme["ventoy_top"] as? String,
                                            ventoyColor: theme["ventoy_color"] as? String),
                        config.path)
            }
        }
        return nil
    }

    private enum Standing { case ventoyFolder, driveRoot }

    /// The `theme` object of a `ventoy.json`, if it is valid JSON of the shape Ventoy reads.
    private static func themeObject(in data: Data) -> [String: Any]? {
        // Editors on Windows like to put a byte order mark first; JSONSerialization refuses one.
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let body = data.starts(with: bom) ? Data(data.dropFirst(bom.count)) : data
        guard let top = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        return top["theme"] as? [String: Any]
    }

    /// A JSON string, or an array of them (Ventoy takes either for `file` and `fonts`).
    private static func stringList(_ value: Any?) -> [String] {
        if let one = value as? String { return [one] }
        return (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// Where a path on the drive lands in the source, or nil for a name that climbs out.
    private static func sourcePath(of drivePath: String, configFolder: String, standing: Standing) -> String? {
        var parts = drivePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains("."), !parts.contains("..") else { return nil }
        if standing == .ventoyFolder {
            guard parts.count > 1, parts[0].lowercased() == "ventoy" else { return nil }
            parts.removeFirst()
        }
        return ([configFolder].filter { !$0.isEmpty } + parts).joined(separator: "/")
    }

    /// Lowercase ASCII letters, digits and single hyphens, at most 30 long;
    /// "theme" when nothing usable is left. "custom-" + this always fits the installer's id rule.
    static func slug(_ name: String) -> String {
        let mapped = name.lowercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        let trimmed = String(collapsed.prefix(30)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "theme" : trimmed
    }

    /// The file `desktop-image` names, if it is a safe relative path. GRUB
    /// reads `#` lines as comments and lets a later setting win.
    static func backgroundImage(inThemeText text: String) -> String? {
        var found: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let range = trimmed.range(of: #"^desktop-image\s*:\s*"([^"]+)""#, options: .regularExpression) else { continue }
            let match = String(trimmed[range])
            guard let open = match.firstIndex(of: "\""), let close = match.lastIndex(of: "\""), open < close else { continue }
            found = String(match[match.index(after: open)..<close])
        }
        guard let path = found, ThemePath.isSafeRelative(path) else { return nil }
        return path
    }
}
