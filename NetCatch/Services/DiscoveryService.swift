import Foundation
import Network

/// Browses the LAN for other NetCatch receivers via Bonjour.
@MainActor
final class DiscoveryService: ObservableObject {
    @Published var peers: [Peer] = []

    private var browser: NWBrowser?
    private let serviceType = "_netcatch._tcp"
    private var addressCache: [String: String] = [:]   // peer.id -> "host:port"

    /// The local Bonjour service name to exclude from results (so we don't list ourselves).
    var ownServiceName: String = ""

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints = results.map(\.endpoint)
            Task { @MainActor in
                guard let self else { return }
                let own = self.ownServiceName
                var discovered: [Peer] = endpoints.compactMap { endpoint in
                    guard case let .service(name, _, _, _) = endpoint else { return nil }
                    if name == own { return nil }
                    var peer = Peer.bonjour(endpoint: endpoint)
                    peer.address = self.addressCache[peer.id]   // show cached IP immediately
                    return peer
                }
                discovered.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.peers = discovered
                // Resolve the IP for any peer we haven't resolved yet, then fill it in.
                for peer in discovered where self.addressCache[peer.id] == nil {
                    Task { @MainActor in
                        guard let addr = await TransportConnector.shared.resolveAddress(of: peer) else { return }
                        self.addressCache[peer.id] = addr
                        if let idx = self.peers.firstIndex(where: { $0.id == peer.id }) {
                            self.peers[idx].address = addr
                        }
                    }
                }
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        peers = []
    }
}
