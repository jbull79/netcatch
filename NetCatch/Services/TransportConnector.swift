import Foundation
import Network

/// Which underlying transport carried a connection. We probe these in order and remember
/// the one that actually completed a handshake to a given peer.
enum TransportStrategy: String, CaseIterable {
    case posix              // raw BSD socket, kernel routing — works through a VPN like nc
    case nwProhibitOther    // Network.framework, excluding virtual/VPN interfaces
    case nwDefault          // Network.framework, default path selection

    var label: String {
        switch self {
        case .posix: return "POSIX socket"
        case .nwProhibitOther: return "Apple (LAN-only)"
        case .nwDefault: return "Apple (default)"
        }
    }

    var detail: String {
        switch self {
        case .posix: return "Raw BSD socket with kernel routing — works through a VPN like nc."
        case .nwProhibitOther: return "Apple Network.framework, excluding virtual/VPN interfaces."
        case .nwDefault: return "Apple Network.framework with default path selection."
        }
    }
}

/// Establishes an outbound `PeerLink` by trying each transport strategy until one
/// completes the handshake, then caching the winner per peer so later transfers connect
/// straight away. This makes NetCatch resilient across environments: some peers only work
/// over raw sockets (VPN present), some only over Network.framework, etc.
@MainActor
final class TransportConnector {
    static let shared = TransportConnector()

    private var winner: [String: TransportStrategy] = [:]
    private let connectTimeout: TimeInterval = 6

    /// Connect + handshake to `peer`, returning a ready, authenticated link. `allowed`
    /// restricts which transport methods may be tried (user-toggleable for testing).
    func connect(to peer: Peer, localName: String,
                 allowed: Set<TransportStrategy> = Set(TransportStrategy.allCases)) async throws -> PeerLink {
        let resolved = await resolveHostPort(peer.endpoint)
        let key = resolved.map { "\($0.host):\($0.port)" } ?? peer.id

        var order = TransportStrategy.allCases.filter { allowed.contains($0) }
        if order.isEmpty { order = TransportStrategy.allCases }   // safety: never nothing to try
        if let preferred = winner[key], order.contains(preferred) {   // try last-known-good first
            order.removeAll { $0 == preferred }
            order.insert(preferred, at: 0)
        }

        var lastError: Error?
        for strategy in order {
            // POSIX needs a concrete host:port; skip it if Bonjour didn't resolve.
            if strategy == .posix && resolved == nil { continue }
            do {
                let link = try await attempt(strategy, peer: peer, resolved: resolved, localName: localName)
                if winner[key] != strategy {
                    winner[key] = strategy
                    DebugLog.log("connect: '\(strategy.label)' worked for \(key) — caching")
                }
                return link
            } catch {
                lastError = error
                DebugLog.log("connect: '\(strategy.label)' failed for \(key) — \(error.localizedDescription)", .warn)
            }
        }
        throw lastError ?? LinkError.closed
    }

    /// Forget a cached choice (e.g. after a network change) so probing restarts fresh.
    func resetCache() { winner.removeAll() }

    /// Resolve a peer's endpoint to a display "host:port" string (Bonjour → IP).
    func resolveAddress(of peer: Peer) async -> String? {
        guard let r = await resolveHostPort(peer.endpoint) else { return nil }
        return "\(r.host):\(r.port)"
    }

    // MARK: - One strategy attempt (connect + handshake)

    private func attempt(_ strategy: TransportStrategy, peer: Peer,
                         resolved: (host: String, port: UInt16)?, localName: String) async throws -> PeerLink {
        let stream: ByteStream
        switch strategy {
        case .posix:
            guard let r = resolved else { throw LinkError.closed }
            stream = try POSIXByteStream.connect(host: r.host, port: r.port, timeout: connectTimeout)
        case .nwProhibitOther:
            let params = NWParameters.tcp
            params.prohibitedInterfaceTypes = [.other]
            stream = NWByteStream(NWConnection(to: peer.endpoint, using: params))
        case .nwDefault:
            stream = NWByteStream(NWConnection(to: peer.endpoint, using: .tcp))
        }
        let link = PeerLink(stream: stream)
        do {
            try await link.start()
            try await link.handshake(localName: localName)   // validates the path end-to-end
            return link
        } catch {
            link.cancel()
            throw error
        }
    }

    // MARK: - Bonjour / endpoint resolution

    /// Resolve an endpoint to a concrete host:port so the POSIX transport can dial it.
    /// Manual endpoints already carry host:port; Bonjour `.service` endpoints are resolved
    /// with a short-lived NWConnection (Network.framework's discovery works fine even when
    /// its data path doesn't), reading the peer's address from the established path.
    private func resolveHostPort(_ endpoint: NWEndpoint) async -> (host: String, port: UInt16)? {
        if case let .hostPort(host, port) = endpoint {
            return (hostString(host), port.rawValue)
        }
        // Bonjour service — resolve via a throwaway connection.
        return await withCheckedContinuation { (cont: CheckedContinuation<(host: String, port: UInt16)?, Never>) in
            let conn = NWConnection(to: endpoint, using: .tcp)
            let done = ResolveOnce()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var result: (host: String, port: UInt16)?
                    if case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint {
                        result = (self.hostString(host), port.rawValue)
                    }
                    if done.fire() { conn.cancel(); cont.resume(returning: result) }
                case .failed, .cancelled:
                    if done.fire() { conn.cancel(); cont.resume(returning: nil) }
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            // Safety timeout so resolution can't hang the connect.
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                if done.fire() { conn.cancel(); cont.resume(returning: nil) }
            }
        }
    }

    private nonisolated func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let a): return "\(a)".components(separatedBy: "%").first ?? "\(a)"
        case .ipv6(let a): return "\(a)".components(separatedBy: "%").first ?? "\(a)"
        case .name(let n, _): return n
        @unknown default: return "\(host)"
        }
    }
}

/// One-shot latch so a resolve continuation resumes exactly once.
private final class ResolveOnce: @unchecked Sendable {
    private let lock = NSLock(); private var fired = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
}
