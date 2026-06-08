import Foundation

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        return bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func eta(remaining: Int64, rate: Double) -> String {
        guard rate > 1 else { return "—" }
        let seconds = Double(remaining) / rate
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int(seconds / 60)
        let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
        return "\(minutes)m \(secs)s"
    }
}
