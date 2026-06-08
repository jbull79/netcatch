import Foundation

/// A send request produced by an external trigger (the `netcatch://` URL scheme or
/// the Shortcuts action), to be carried out by `AppModel.sendViaAutomation`.
struct SendRequest: Equatable {
    var urls: [URL]
    var peerName: String?       // nil/empty → let the user pick in the app
    var compress: Bool?         // nil → use the app default
}

/// Parses external entry points into a `SendRequest`. Pure and side-effect free so it
/// can be unit-tested without the app runtime.
enum AutomationRouter {
    /// Handles two URL shapes:
    ///   - `netcatch://send?peer=Studio-Mac&compress=1&path=/a/b.pdf&path=/a/c.zip`
    ///   - a plain `file://` URL (queued for the user to pick a peer)
    static func parse(_ url: URL) -> SendRequest? {
        if url.isFileURL {
            return SendRequest(urls: [url], peerName: nil, compress: nil)
        }
        guard url.scheme?.lowercased() == "netcatch" else { return nil }
        // Accept netcatch://send?… and netcatch:///send?… alike.
        let action = (url.host ?? url.pathComponents.first { $0 != "/" }) ?? ""
        guard action.lowercased() == "send" else { return nil }

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []

        let paths = items.filter { $0.name == "path" || $0.name == "file" }
            .compactMap { $0.value }
            .filter { !$0.isEmpty }
        let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        guard !urls.isEmpty else { return nil }

        let peer = items.first { $0.name == "peer" || $0.name == "to" }?.value
        let compress = items.first { $0.name == "compress" }?.value.map(parseBool)

        return SendRequest(urls: urls,
                           peerName: (peer?.isEmpty == false) ? peer : nil,
                           compress: compress)
    }

    static func parseBool(_ s: String) -> Bool {
        ["1", "true", "yes", "on"].contains(s.lowercased())
    }
}
