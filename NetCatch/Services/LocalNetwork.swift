import Foundation

enum LocalNetwork {
    /// Best-guess local IPv4 address for display, e.g. "192.168.1.42". Prefers the
    /// primary Wi-Fi/Ethernet interface (en0, then any en*), skipping loopback and
    /// virtual interfaces (awdl/llw/utun). Returns nil if offline.
    static func ipv4Address() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return nil }
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
        return candidates.first(where: { $0.name == "en0" })?.ip
            ?? candidates.first(where: { $0.name.hasPrefix("en") })?.ip
            ?? candidates.first?.ip
    }
}
