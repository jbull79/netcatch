import Foundation

struct HistoryRecord: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var directionIsSend: Bool
    var peerName: String
    var summary: String        // e.g. "trip-photos" or "3 items"
    var bytes: Int64
    var succeeded: Bool
}

/// Persisted log of past transfers, stored as JSON in Application Support.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [HistoryRecord] = []

    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NetCatch", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("history.json")
        load()
    }

    func add(_ record: HistoryRecord) {
        records.insert(record, at: 0)
        if records.count > 200 { records.removeLast(records.count - 200) }
        save()
    }

    func clear() {
        records = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: fileURL)
        }
    }
}
