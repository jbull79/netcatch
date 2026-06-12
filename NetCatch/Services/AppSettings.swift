import Foundation

/// User-configurable settings, persisted in UserDefaults. The default save folder is
/// stored as an app-scoped security-scoped bookmark so it survives relaunch inside
/// the sandbox; it falls back to the Downloads folder.
@MainActor
final class AppSettings: ObservableObject {
    @Published var deviceName: String { didSet { defaults.set(deviceName, forKey: Keys.deviceName) } }
    @Published var port: UInt16 { didSet { defaults.set(Int(port), forKey: Keys.port) } }
    @Published var autoAcceptTrusted: Bool { didSet { defaults.set(autoAcceptTrusted, forKey: Keys.autoAccept) } }
    @Published var compressByDefault: Bool { didSet { defaults.set(compressByDefault, forKey: Keys.compress) } }
    /// Experimental keyboard/mouse control (KVM). Off by default; gates both accepting
    /// inbound control and offering to control a peer.
    @Published var controlEnabled: Bool { didSet { defaults.set(controlEnabled, forKey: Keys.control) } }
    /// Which transport methods the connector may use, by raw value. All enabled by
    /// default; can be turned off individually for testing. Shared by every connection
    /// (file transfer today, workbook sync later), so it's protocol-agnostic.
    @Published var enabledTransports: Set<String> {
        didSet { defaults.set(Array(enabledTransports), forKey: Keys.transports) }
    }
    @Published private(set) var saveDirectoryBookmark: Data?

    private let defaults = UserDefaults.standard

    enum Keys {
        static let deviceName = "netcatch.deviceName"
        static let port = "netcatch.port"
        static let autoAccept = "netcatch.autoAcceptTrusted"
        static let compress = "netcatch.compressByDefault"
        static let saveBookmark = "netcatch.saveBookmark"
        static let transports = "netcatch.enabledTransports"
        static let control = "netcatch.controlEnabled"
    }

    init() {
        deviceName = defaults.string(forKey: Keys.deviceName) ?? Host.current().localizedName ?? "My Mac"
        let storedPort = defaults.integer(forKey: Keys.port)
        port = storedPort == 0 ? 51234 : UInt16(storedPort)
        autoAcceptTrusted = defaults.bool(forKey: Keys.autoAccept)
        compressByDefault = defaults.object(forKey: Keys.compress) as? Bool ?? true
        controlEnabled = defaults.bool(forKey: Keys.control)
        if let stored = defaults.array(forKey: Keys.transports) as? [String], !stored.isEmpty {
            enabledTransports = Set(stored)
        } else {
            enabledTransports = Set(TransportStrategy.allCases.map(\.rawValue))
        }
        saveDirectoryBookmark = defaults.data(forKey: Keys.saveBookmark)
    }

    /// Enabled strategies as a typed set; never empty (falls back to all) so the app
    /// can't be left unable to connect.
    var enabledTransportStrategies: Set<TransportStrategy> {
        let set = Set(enabledTransports.compactMap(TransportStrategy.init(rawValue:)))
        return set.isEmpty ? Set(TransportStrategy.allCases) : set
    }

    func isTransportEnabled(_ s: TransportStrategy) -> Bool { enabledTransports.contains(s.rawValue) }

    func setTransport(_ s: TransportStrategy, enabled: Bool) {
        if enabled { enabledTransports.insert(s.rawValue) }
        else if enabledTransports.count > 1 { enabledTransports.remove(s.rawValue) }  // keep at least one
    }

    /// Resolved default save directory (Downloads if no custom folder chosen).
    var defaultSaveDirectory: URL {
        if let bookmark = saveDirectoryBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: [.withSecurityScope],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                return url
            }
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func setSaveDirectory(_ url: URL) {
        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil) {
            saveDirectoryBookmark = bookmark
            defaults.set(bookmark, forKey: Keys.saveBookmark)
        }
    }
}
