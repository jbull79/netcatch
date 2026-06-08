import Foundation

/// Persists partially-received transfer blobs so an interrupted transfer can resume.
/// Blobs are content-addressed by the item's sha256 (the hash of the transmitted
/// bytes), so a retry of the same content — even after an app restart, and regardless
/// of sender — matches its existing partial. Survives across launches in Application
/// Support; cleaned up once the item completes (or is found corrupt).
enum PartialStore {
    static func directory() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NetCatch/partials", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Path for a given transmitted-blob sha256 (hex — already a safe filename).
    static func url(forSHA sha: String) -> URL {
        directory().appendingPathComponent(sha + ".part")
    }

    /// Bytes already on disk for this sha (0 if none).
    static func size(forSHA sha: String) -> Int64 {
        (try? url(forSHA: sha).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    static func remove(sha: String) {
        try? FileManager.default.removeItem(at: url(forSHA: sha))
    }
}
