import Foundation

/// One file or folder within a transfer. The `sha256` is computed over the
/// *transmitted blob* (post-compression / post-archive), so the receiver can
/// verify transit integrity before reversing the pipeline.
struct TransferItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var originalSize: Int64
    var transmittedSize: Int64
    var isDirectory: Bool
    var compressed: Bool
    var sha256: String

    /// Compression ratio saved, 0...1 (e.g. 0.38 == "saved 38%").
    var ratioSaved: Double {
        guard originalSize > 0, compressed else { return 0 }
        return max(0, 1 - Double(transmittedSize) / Double(originalSize))
    }
}
