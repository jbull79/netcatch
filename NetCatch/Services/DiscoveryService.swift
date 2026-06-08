import Foundation
import Network

/// Browses the LAN for other NetCatch receivers via Bonjour.
@MainActor
final class DiscoveryService: ObservableObject {
    @Published var peers: [Peer] = []

    private var browser: NWBrowser?
    private let serviceType = "_netcatch._tcp"

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
                let discovered: [Peer] = endpoints.compactMap { endpoint in
                    guard case let .service(name, _, _, _) = endpoint else { return nil }
                    if name == own { return nil }
                    return Peer.bonjour(endpoint: endpoint)
                }
                self.peers = discovered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
