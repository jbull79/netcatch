import Foundation

enum TransferDirection {
    case send
    case receive
}

enum TransferState: Equatable {
    case queued
    case connecting
    case awaitingApproval      // receiver is deciding
    case transferring
    case verifying
    case completed
    case rejected
    case cancelled
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .completed, .rejected, .cancelled, .failed: return true
        default: return false
        }
    }

    /// True while the transfer is live and can still be cancelled.
    var isActive: Bool { !isTerminal }
}

struct ThroughputSample: Identifiable {
    let id = UUID()
    let time: Date
    let bytesPerSecond: Double
}

/// Observable per-transfer state that drives a row in the UI.
@MainActor
final class Transfer: ObservableObject, Identifiable {
    let id = UUID()
    let direction: TransferDirection
    let startedAt = Date()

    @Published var peerName: String
    @Published var peerFingerprint: String?
    @Published var items: [TransferItem]
    @Published var state: TransferState = .queued
    @Published var bytesTransferred: Int64 = 0
    @Published var totalBytes: Int64
    @Published var throughput: Double = 0          // bytes/sec (current)
    @Published var peakThroughput: Double = 0      // bytes/sec (max seen)
    @Published var samples: [ThroughputSample] = []
    @Published var savedLocation: URL?

    private var lastSampleBytes: Int64 = 0
    private var lastSampleTime = Date()
    private var transferStart: Date?
    private var transferEnd: Date?

    init(direction: TransferDirection, peerName: String, items: [TransferItem], totalBytes: Int64) {
        self.direction = direction
        self.peerName = peerName
        self.items = items
        self.totalBytes = totalBytes
    }

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytesTransferred) / Double(totalBytes))
    }

    var primaryName: String {
        if items.count == 1 { return items[0].name }
        return "\(items.count) items"
    }

    /// Average rate over the whole transfer (bytes/sec), for the post-transfer summary.
    var averageThroughput: Double {
        guard let start = transferStart else { return 0 }
        let end = transferEnd ?? Date()
        let elapsed = end.timeIntervalSince(start)
        guard elapsed > 0 else { return 0 }
        return Double(bytesTransferred) / elapsed
    }

    /// Record newly moved bytes and refresh the throughput sample if enough time elapsed.
    func advance(by delta: Int64) {
        if transferStart == nil { transferStart = Date() }
        bytesTransferred += delta
        let now = Date()
        let interval = now.timeIntervalSince(lastSampleTime)
        if interval >= 0.25 {
            let rate = Double(bytesTransferred - lastSampleBytes) / interval
            throughput = rate
            peakThroughput = max(peakThroughput, rate)
            samples.append(ThroughputSample(time: now, bytesPerSecond: rate))
            if samples.count > 120 { samples.removeFirst(samples.count - 120) }
            lastSampleBytes = bytesTransferred
            lastSampleTime = now
        }
    }

    /// Freeze the elapsed window when the transfer stops, so the average stays accurate.
    func finishTiming() {
        if transferEnd == nil { transferEnd = Date() }
        throughput = 0
    }
}
