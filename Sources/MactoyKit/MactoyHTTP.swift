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

    /// What the shared session left behind before v0.8.0, relative to the user's Library folder.
    /// Nothing in Mactoy uses these any more.
    static let staleSharedSessionItems = [
        "Caches/com.mactoy.Mactoy/Cache.db",
        "Caches/com.mactoy.Mactoy/Cache.db-shm",
        "Caches/com.mactoy.Mactoy/Cache.db-wal",
        "Caches/com.mactoy.Mactoy/fsCachedData",
        "HTTPStorages/com.mactoy.Mactoy",
        "HTTPStorages/com.mactoy.Mactoy.binarycookies",
    ]

    /// Deletes what the shared session left behind before v0.8.0. Safe to call on every launch.
    public static func removeStaleSharedSessionFiles(library: URL? = nil) {
        let fm = FileManager.default
        guard let library = library ?? fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        for item in staleSharedSessionItems {
            try? fm.removeItem(at: library.appendingPathComponent(item))
        }
    }
}
