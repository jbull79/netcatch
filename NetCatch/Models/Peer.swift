import Foundation
import Network

/// A discovered (Bonjour) or manually entered destination.
struct Peer: Identifiable, Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    var isManual: Bool = false
    /// Resolved "host:port" for display (Bonjour peers resolve asynchronously).
    var address: String? = nil

    static func bonjour(endpoint: NWEndpoint) -> Peer {
        let name: String
        if case let .service(serviceName, _, _, _) = endpoint {
            name = serviceName
        } else {
            name = "\(endpoint)"
        }
        return Peer(id: "\(endpoint)", name: name, endpoint: endpoint)
    }

    static func manual(host: String, port: UInt16) -> Peer? {
        guard let p = NWEndpoint.Port(rawValue: port) else { return nil }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: p)
        return Peer(id: "manual:\(host):\(port)", name: "\(host):\(port)", endpoint: endpoint, isManual: true)
    }
}
