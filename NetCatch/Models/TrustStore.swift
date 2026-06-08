import Foundation

/// Trust-on-first-use record of known device fingerprints. Persisted in
/// UserDefaults for v1 (Keychain is a future hardening step).
@MainActor
final class TrustStore: ObservableObject {
    @Published private(set) var known: [String: String] = [:]   // fingerprint -> last name
    private let key = "netcatch.trustedDevices"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            known = decoded
        }
    }

    func isTrusted(_ fingerprint: String) -> Bool { known[fingerprint] != nil }

    func trust(_ fingerprint: String, name: String) {
        known[fingerprint] = name
        persist()
    }

    func forget(_ fingerprint: String) {
        known.removeValue(forKey: fingerprint)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(known) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
