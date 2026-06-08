import Foundation
import Network
import CryptoKit

enum LinkError: Error, LocalizedError {
    case closed
    case notReady
    case rejected
    case integrityMismatch(String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .closed: return "Connection closed."
        case .notReady: return "Connection not ready."
        case .rejected: return "The other device declined the transfer."
        case .integrityMismatch(let name): return "Integrity check failed for \(name)."
        case .malformed: return "Received malformed data."
        }
    }
}

/// Low-level async framing over an NWConnection.
extension NWConnection {
    func startAndWaitReady() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let error), .waiting(let error):
                    self?.stateUpdateHandler = nil
                    self?.cancel()
                    cont.resume(throwing: error)
                case .cancelled:
                    self?.stateUpdateHandler = nil
                    cont.resume(throwing: LinkError.closed)
                default:
                    break
                }
            }
            self.start(queue: .global(qos: .userInitiated))
        }
    }

    func sendData(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// Reads exactly `count` bytes or throws `LinkError.closed` on EOF.
    func receiveExact(_ count: Int) async throws -> Data {
        if count == 0 { return Data() }
        var buffer = Data()
        buffer.reserveCapacity(count)
        while buffer.count < count {
            let remaining = count - buffer.count
            let chunk: Data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                    if let error { cont.resume(throwing: error); return }
                    if let data, !data.isEmpty { cont.resume(returning: data); return }
                    cont.resume(throwing: LinkError.closed)
                    _ = isComplete
                }
            }
            buffer.append(chunk)
        }
        return buffer
    }

    func sendFrame(_ data: Data) async throws {
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)
        try await sendData(frame)
    }

    func receiveFrame() async throws -> Data {
        let header = try await receiveExact(4)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        return try await receiveExact(Int(length))
    }
}

/// An encrypted, framed peer connection. After `handshake()` all frames are
/// AES-GCM sealed with the negotiated session key.
final class PeerLink {
    let connection: NWConnection
    private(set) var sessionKey: SymmetricKey?
    private(set) var remoteName: String = "Unknown"
    private(set) var remoteFingerprint: String = ""

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() async throws {
        try await connection.startAndWaitReady()
    }

    func cancel() {
        connection.cancel()
    }

    /// Exchange ephemeral + identity keys and derive the session key.
    func handshake(localName: String) async throws {
        let identity = CryptoService.identityPrivateKey()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let outgoing = Handshake(identityPub: identity.publicKey.rawRepresentation,
                                 ephemeralPub: ephemeral.publicKey.rawRepresentation,
                                 name: localName)
        try await connection.sendFrame(try JSONEncoder().encode(outgoing))

        let incomingData = try await connection.receiveFrame()
        let incoming = try JSONDecoder().decode(Handshake.self, from: incomingData)
        sessionKey = try CryptoService.deriveSessionKey(ephemeralPrivate: ephemeral,
                                                        remoteEphemeralPublicRaw: incoming.ephemeralPub)
        remoteName = incoming.name
        remoteFingerprint = CryptoService.fingerprint(of: incoming.identityPub)
    }

    func sendSecure(_ data: Data) async throws {
        guard let key = sessionKey else { throw LinkError.notReady }
        try await connection.sendFrame(try CryptoService.seal(data, key: key))
    }

    func receiveSecure() async throws -> Data {
        guard let key = sessionKey else { throw LinkError.notReady }
        return try CryptoService.open(try await connection.receiveFrame(), key: key)
    }

    // MARK: Codable helpers

    func sendSecureObject<T: Encodable>(_ value: T) async throws {
        try await sendSecure(try JSONEncoder().encode(value))
    }

    func receiveSecureObject<T: Decodable>(_ type: T.Type) async throws -> T {
        try JSONDecoder().decode(type, from: try await receiveSecure())
    }
}
