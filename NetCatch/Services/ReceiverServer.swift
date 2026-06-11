import Foundation
import Network
import Darwin

/// Always-on listener that advertises this device over Bonjour and hands off each
/// incoming connection. It accepts over a raw POSIX socket (kernel routing, so replies
/// go out the physical LAN interface even when a VPN is up — like `nc`), and advertises
/// the service with `NetService`. If the POSIX socket can't bind, it falls back to an
/// `NWListener`.
@MainActor
final class ReceiverServer: ObservableObject {
    @Published var isRunning = false
    @Published var lastError: String?

    private let serviceType = "_netcatch._tcp"

    // POSIX path
    private var listenFD: Int32 = -1
    private var acceptQueue = DispatchQueue(label: "netcatch.accept")
    private var advertiser: NetService?

    // NWListener fallback
    private var nwListener: NWListener?

    /// Called (on the main actor) for every new inbound connection.
    var onIncoming: ((PeerLink) -> Void)?

    func start(serviceName: String, port: UInt16) {
        stop()
        if startPOSIX(serviceName: serviceName, port: port) { return }
        DebugLog.log("listener: POSIX bind failed, falling back to NWListener", .warn)
        startNW(serviceName: serviceName, port: port)
    }

    func stop() {
        if listenFD >= 0 { shutdown(listenFD, SHUT_RDWR); Darwin.close(listenFD); listenFD = -1 }
        advertiser?.stop(); advertiser = nil
        nwListener?.cancel(); nwListener = nil
        isRunning = false
    }

    // MARK: - POSIX listener (primary)

    private func startPOSIX(serviceName: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0, Darwin.listen(fd, 16) == 0 else {
            DebugLog.log("listener: POSIX bind/listen errno=\(errno)", .warn)
            Darwin.close(fd); return false
        }
        // Read back the actual port (covers port 0 = any).
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let actualPort: UInt16 = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        } == 0 ? bound.sin_port.bigEndian : port

        listenFD = fd
        isRunning = true
        lastError = nil
        DebugLog.log("listener: POSIX ready on port \(actualPort) as '\(serviceName)'")

        // Accept loop on a background queue. Capture the fd by value — never touch
        // main-actor state (e.g. listenFD) from this thread, or Swift's exclusivity
        // enforcement traps and the app crashes. The loop ends when stop() closes the
        // socket and accept() returns an error.
        acceptQueue.async { [weak self] in
            while true {
                let clientFD = accept(fd, nil, nil)
                if clientFD < 0 { break }
                let stream = POSIXByteStream(fd: clientFD)
                Task { @MainActor in
                    guard let self else { stream.close(); return }
                    DebugLog.log("listener: incoming POSIX connection")
                    self.onIncoming?(PeerLink(stream: stream))
                }
            }
        }

        // Advertise over Bonjour (NetService just publishes the record; it doesn't own the socket).
        let service = NetService(domain: "", type: "\(serviceType).", name: serviceName, port: Int32(actualPort))
        service.publish()
        advertiser = service
        return true
    }

    // MARK: - NWListener (fallback)

    private func startNW(serviceName: String, port: UInt16) {
        do {
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
                case .ready: DebugLog.log("listener: NW ready on port \(port) as '\(serviceName)'")
                case .failed(let error): DebugLog.log("listener: NW failed — \(error)", .error)
                default: break
                }
                Task { @MainActor in
                    switch state {
                    case .ready: self?.isRunning = true
                    case .failed(let error): self?.isRunning = false; self?.lastError = error.localizedDescription
                    case .cancelled: self?.isRunning = false
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                DebugLog.log("listener: incoming NW connection from \(connection.endpoint)")
                Task { @MainActor in self?.onIncoming?(PeerLink(connection: connection)) }
            }
            listener.start(queue: .main)
            nwListener = listener
        } catch {
            lastError = error.localizedDescription
            isRunning = false
        }
    }
}
