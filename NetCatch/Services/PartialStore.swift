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

    /// True only for a well-formed sha256 (exactly 64 lowercase hex chars). Used to
    /// reject an attacker-supplied `sha256` before it is ever used as a filename
    /// component (the value arrives in the untrusted transfer header).
    static func isValidSHA256(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Path for a given transmitted-blob sha256. Callers must pass a value that has
    /// already passed `isValidSHA256` (so it cannot contain path separators or `..`).
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
