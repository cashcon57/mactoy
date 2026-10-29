import Foundation

/// The network session every Mactoy download goes through (issue #22).
///
/// Ephemeral, with no cache, cookies or credential store, so macOS keeps nothing on disk for it:
/// no `~/Library/Caches/com.mactoy.Mactoy/Cache.db`, no `fsCachedData`, no
/// `~/Library/HTTPStorages/com.mactoy.Mactoy`. Mactoy keeps what it wants to reuse itself:
/// SHA-256-checked Ventoy downloads and theme files, each in its own cache folder.
public enum MactoyHTTP {
    public static let session = URLSession(configuration: configuration())

    /// For sessions that need their own delegate (download progress).
    public static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        return config
    }

    /// What the shared session left behind before v0.8.0, relative to a Library folder, for each
    /// name macOS may have filed it under. The app is `com.mactoy.Mactoy`; the helper, which sits
    /// inside the app and runs as root, used root's Library under the app's name or its own.
    /// Nothing in Mactoy uses these any more.
    static func staleSharedSessionItems(names: [String]) -> [String] {
        names.flatMap { name in [
            "Caches/\(name)/Cache.db",
            "Caches/\(name)/Cache.db-shm",
            "Caches/\(name)/Cache.db-wal",
            "Caches/\(name)/fsCachedData",
            "HTTPStorages/\(name)",
            "HTTPStorages/\(name).binarycookies",
        ] }
    }

    /// Deletes what the shared session left behind before v0.8.0 in the current user's Library
    /// (root's, for the helper). Safe to call on every launch.
    ///
    /// `removeEmptyCacheFolders` then removes each `Caches/<name>` folder if it's empty. Only the
    /// helper asks for that: the app keeps its own theme and Ventoy caches in that folder and may
    /// be creating them at the same moment.
    public static func removeStaleSharedSessionFiles(
        library: URL? = nil,
        names: [String] = ["com.mactoy.Mactoy", "com.mactoy.mactoyd", "mactoyd"],
        removeEmptyCacheFolders: Bool = false
    ) {
        let fm = FileManager.default
        guard let library = library ?? fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        for item in staleSharedSessionItems(names: names) {
            try? fm.removeItem(at: library.appendingPathComponent(item))
        }
        guard removeEmptyCacheFolders else { return }
        for name in names {
            _ = rmdir(library.appendingPathComponent("Caches/\(name)").path)
        }
    }
}
