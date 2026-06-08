import Foundation

/// Sent (encrypted) immediately after the handshake. The `transferId` and the
/// per-item layout exist now so v2 resume / batch can slot in without a protocol
/// break.
struct TransferHeader: Codable {
    var v: Int = 1
    var transferId: UUID = UUID()
    var senderName: String
    var items: [TransferItem]

    var totalTransmitted: Int64 { items.reduce(0) { $0 + $1.transmittedSize } }
    var totalOriginal: Int64 { items.reduce(0) { $0 + $1.originalSize } }
}

/// Plaintext handshake exchanged before any encrypted frames.
struct Handshake: Codable {
    var identityPub: Data
    var ephemeralPub: Data
    var name: String
}

/// Receiver's reply to the header: accept or reject.
struct TransferDecision: Codable {
    var accepted: Bool
}
