import Foundation
import Network

/// Always-on TCP listener that advertises this device over Bonjour and hands off
/// each incoming connection.
@MainActor
final class ReceiverServer: ObservableObject {
    @Published var isRunning = false
    @Published var lastError: String?

    private var listener: NWListener?
    private let serviceType = "_netcatch._tcp"

    /// Called (on the main actor) for every new inbound connection.
    var onIncoming: ((NWConnection) -> Void)?

    func start(serviceName: String, port: UInt16) {
        stop()
        do {
            // Listen over plain infrastructure TCP (like netcat). Still advertised via
            // Bonjour over the shared network; no AWDL/peer-to-peer, and avoid VPN/
            // virtual interfaces (.other) so replies aren't routed into a VPN tunnel.
            let params = NWParameters.tcp
            params.prohibitedInterfaceTypes = [.other]
            let listener: NWListener
            if let nwPort = NWEndpoint.Port(rawValue: port) {
                listener = try NWListener(using: params, on: nwPort)
            } else {
                listener = try NWListener(using: params)
            }
            listener.service = NWListener.Service(name: serviceName, type: serviceType)

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: DebugLog.log("listener: ready on port \(port) as '\(serviceName)'")
                case .failed(let error): DebugLog.log("listener: failed — \(error)", .error)
                case .cancelled: DebugLog.log("listener: cancelled", .warn)
                default: break
                }
                Task { @MainActor in
                    switch state {
                    case .ready: self?.isRunning = true
                    case .failed(let error):
                        self?.isRunning = false
                        self?.lastError = error.localizedDescription
                    case .cancelled:
                        self?.isRunning = false
                    default: break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                DebugLog.log("listener: incoming connection from \(connection.endpoint)")
                Task { @MainActor in
                    self?.onIncoming?(connection)
                }
            }

            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }
}
