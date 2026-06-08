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
    @Published private(set) var saveDirectoryBookmark: Data?

    private let defaults = UserDefaults.standard

    enum Keys {
        static let deviceName = "netcatch.deviceName"
        static let port = "netcatch.port"
        static let autoAccept = "netcatch.autoAcceptTrusted"
        static let compress = "netcatch.compressByDefault"
        static let saveBookmark = "netcatch.saveBookmark"
    }

    init() {
        deviceName = defaults.string(forKey: Keys.deviceName) ?? Host.current().localizedName ?? "My Mac"
        let storedPort = defaults.integer(forKey: Keys.port)
        port = storedPort == 0 ? 51234 : UInt16(storedPort)
        autoAcceptTrusted = defaults.bool(forKey: Keys.autoAccept)
        compressByDefault = defaults.object(forKey: Keys.compress) as? Bool ?? true
        saveDirectoryBookmark = defaults.data(forKey: Keys.saveBookmark)
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
