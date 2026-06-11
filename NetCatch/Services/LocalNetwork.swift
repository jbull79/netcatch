import Foundation
import Network

enum LocalNetwork {
    /// IPv4 candidates on real (non-virtual) interfaces, in preference order.
    private static func ipv4Candidates() -> [(name: String, ip: String)] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var candidates: [(name: String, ip: String)] = []
        var cursor = ifaddrPtr
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let sa = ptr.pointee.ifa_addr,
                  (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_LOOPBACK) == 0,
                  sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard !name.hasPrefix("awdl"), !name.hasPrefix("llw"), !name.hasPrefix("utun") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                candidates.append((name, String(cString: host)))
            }
        }
        // en0 first, then any other en* (wired/Wi-Fi), then whatever's left.
        return candidates.sorted { lhs, rhs in
            func rank(_ n: String) -> Int { n == "en0" ? 0 : (n.hasPrefix("en") ? 1 : 2) }
            return rank(lhs.name) < rank(rhs.name)
        }
    }

    /// Best-guess local IPv4 address for display, e.g. "192.168.1.42". Prefers the
    /// primary Wi-Fi/Ethernet interface (en0, then any en*), skipping loopback and
    /// virtual interfaces (awdl/llw/utun). Returns nil if offline.
    static func ipv4Address() -> String? { ipv4Candidates().first?.ip }

    /// Name of the physical LAN interface we route over (e.g. "en0"), or nil if offline.
    static func lanInterfaceName() -> String? { ipv4Candidates().first?.name }

    /// The live `NWInterface` for our LAN interface, so a connection or listener can be
    /// *pinned* to it (`requiredInterface`). This makes Network.framework route over the
    /// physical LAN like `nc` does, instead of being free to drift onto a VPN tunnel —
    /// the cause of the "stuck on connecting" / NWError 57 failures when a VPN is up.
    static func lanInterface() async -> NWInterface? {
        guard let wanted = lanInterfaceName() else { return nil }
        let monitor = NWPathMonitor()
        let path: NWPath = await withCheckedContinuation { cont in
            let resumed = Atomic(false)
            monitor.pathUpdateHandler = { p in
                if resumed.compareExchange(false, true) { cont.resume(returning: p) }
            }
            monitor.start(queue: .global(qos: .userInitiated))
        }
        monitor.cancel()
        return path.availableInterfaces.first { $0.name == wanted }
            ?? path.availableInterfaces.first { $0.type == .wifi || $0.type == .wiredEthernet }
    }
}

/// Tiny one-shot guard so the path continuation resumes exactly once.
private final class Atomic<T: Equatable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func compareExchange(_ expected: T, _ new: T) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value == expected else { return false }
        value = new
        return true
    }
}
