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
            // Bonjour over the shared network; no AWDL/peer-to-peer.
            let params = NWParameters.tcp
            let listener: NWListener
            if let nwPort = NWEndpoint.Port(rawValue: port) {
                listener = try NWListener(using: params, on: nwPort)
            } else {
                listener = try NWListener(using: params)
            }
            listener.service = NWListener.Service(name: serviceName, type: serviceType)

            listener.stateUpdateHandler = { [weak self] state in
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
