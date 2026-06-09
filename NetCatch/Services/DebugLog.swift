import Foundation

/// Lightweight in-app diagnostic log. Call `DebugLog.log(...)` from anywhere (any
/// thread/actor); it hops to the main actor to update the observable buffer and also
/// mirrors to the unified log. Surfaced in the app's "Logs" view with a Copy button so
/// users can share a transcript when a transfer fails.
@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    enum Level: String { case info, warn, error }

    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let level: Level
        let message: String
    }

    @Published private(set) var entries: [Entry] = []

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Safe to call from any context.
    nonisolated static func log(_ message: String, _ level: Level = .info) {
        NSLog("NetCatch [%@] %@", level.rawValue, message)
        Task { @MainActor in shared.append(message, level) }
    }

    private func append(_ message: String, _ level: Level) {
        entries.append(Entry(time: Date(), level: level, message: message))
        if entries.count > 1000 { entries.removeFirst(entries.count - 1000) }
    }

    func clear() { entries = [] }

    func transcript() -> String {
        entries.map { "\(Self.stamp.string(from: $0.time))  [\($0.level.rawValue.uppercased())]  \($0.message)" }
            .joined(separator: "\n")
    }
}
