import Foundation

/// Version of an entry for conflict resolution: a Lamport clock with the author
/// fingerprint as a deterministic tiebreak (multi-person last-writer-wins).
struct EntryVersion: Codable, Equatable {
    var lamport: Int
    var author: String

    /// True if `self` should win over `other`.
    func isNewer(than other: EntryVersion) -> Bool {
        if lamport != other.lamport { return lamport > other.lamport }
        return author > other.author
    }
}

/// One workbook item. Deletes are tombstones (kept + synced) so a delete on one device
/// doesn't get resurrected by another that still has the entry.
struct WorkbookEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var author: String        // fingerprint of the last editor
    var createdAt: Date
    var updatedAt: Date
    var lamport: Int
    var text: String
    var photos: [String]      // content-addressed sha256s (Phase 2)
    var deleted: Bool

    var version: EntryVersion { EntryVersion(lamport: lamport, author: author) }
}

/// id → version map exchanged at the start of a sync so each side knows what the other
/// is missing or has older.
struct WorkbookManifest: Codable { var versions: [String: EntryVersion] }

/// A set of entries pushed during sync.
struct WorkbookBatch: Codable { var entries: [WorkbookEntry] }
