import Foundation

/// Shared, multi-person notebook. Source of truth is a JSON file in the app container.
/// Merge is conflict-free for new entries (union by id) and last-writer-wins per entry
/// by Lamport clock + author tiebreak; deletes are tombstones.
@MainActor
final class WorkbookStore: ObservableObject {
    /// Live (non-deleted) entries, newest first — drives the UI.
    @Published private(set) var entries: [WorkbookEntry] = []
    @Published var lastSynced: Date?

    let localAuthor: String

    private var all: [UUID: WorkbookEntry] = [:]
    private var lamport = 0
    private let fileURL: URL

    init() {
        localAuthor = CryptoService.fingerprint(of: CryptoService.identitySigningKey().publicKey.rawRepresentation)
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true))
        let dir = (support ?? FileManager.default.temporaryDirectory).appendingPathComponent("NetCatch/Workbook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("entries.json")
        load()
    }

    // MARK: Local edits

    func add(text: String) {
        let now = Date()
        lamport += 1
        let entry = WorkbookEntry(id: UUID(), author: localAuthor, createdAt: now, updatedAt: now,
                                  lamport: lamport, text: text, photos: [], deleted: false)
        all[entry.id] = entry
        rebuild(); save()
    }

    func update(_ id: UUID, text: String) {
        guard var e = all[id] else { return }
        lamport += 1
        e.text = text; e.updatedAt = Date(); e.lamport = lamport; e.author = localAuthor
        all[id] = e
        rebuild(); save()
    }

    func delete(_ id: UUID) {
        guard var e = all[id] else { return }
        lamport += 1
        e.deleted = true; e.updatedAt = Date(); e.lamport = lamport; e.author = localAuthor
        all[id] = e
        rebuild(); save()
    }

    func isLocal(_ entry: WorkbookEntry) -> Bool { entry.author == localAuthor }

    // MARK: Sync

    func manifest() -> WorkbookManifest {
        var versions: [String: EntryVersion] = [:]
        for (id, e) in all { versions[id.uuidString] = e.version }
        return WorkbookManifest(versions: versions)
    }

    /// Entries the peer lacks or holds an older version of.
    func entriesNewer(than peer: WorkbookManifest) -> [WorkbookEntry] {
        all.values.filter { e in
            guard let pv = peer.versions[e.id.uuidString] else { return true }
            return e.version.isNewer(than: pv)
        }
    }

    /// Merge a received batch (union + per-entry LWW). Keeps our Lamport clock ahead.
    func merge(_ incoming: [WorkbookEntry]) {
        var changed = false
        for e in incoming {
            lamport = max(lamport, e.lamport)
            if let local = all[e.id], !e.version.isNewer(than: local.version) { continue }
            all[e.id] = e
            changed = true
        }
        if changed { rebuild(); save() }
        lastSynced = Date()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([WorkbookEntry].self, from: data) else { return }
        for e in list { all[e.id] = e; lamport = max(lamport, e.lamport) }
        rebuild()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Array(all.values)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func rebuild() {
        entries = all.values.filter { !$0.deleted }.sorted { $0.createdAt > $1.createdAt }
    }
}
