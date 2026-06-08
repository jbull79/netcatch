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

/// Plaintext handshake exchanged before any encrypted frames. `signature` is the
/// identity key's signature over `ephemeralPub || nonce`, proving the sender holds
/// the private key behind the advertised identity and binding the ephemeral key to
/// it (authenticates the fingerprint, defeats key-replay impersonation and MITM).
struct Handshake: Codable {
    var identityPub: Data    // Curve25519 signing public key (raw)
    var ephemeralPub: Data   // Curve25519 key-agreement public key (raw)
    var nonce: Data          // per-handshake random freshness
    var name: String
    var signature: Data      // sign(ephemeralPub || nonce) with the identity key
}

/// Receiver's reply to the header: accept or reject.
struct TransferDecision: Codable {
    var accepted: Bool
}
