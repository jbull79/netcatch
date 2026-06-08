import Foundation
import CryptoKit
import Security

/// All cryptography: a stable identity key for fingerprints, ephemeral ECDH for
/// per-session AES-GCM keys, plus AES-GCM seal/open and SHA-256 helpers.
enum CryptoService {
    private static let identityKeyDefaultsKey = "netcatch.identitySigningKey"   // legacy (migrated to Keychain)
    private static let keychainService = "com.netcatch.identity"
    private static let keychainAccount = "identitySigningKey"
    private static let hkdfSalt = Data("NetCatch-v1-salt".utf8)
    private static let hkdfInfo = Data("NetCatch-session-key".utf8)

    // MARK: Identity

    /// Stable identity **signing** key, generated once and persisted in the
    /// Keychain. The peer must prove possession of this key during the handshake
    /// (it signs its ephemeral key), so the fingerprint shown in the accept prompt
    /// actually authenticates the sender rather than echoing a replayable value.
    static func identitySigningKey() -> Curve25519.Signing.PrivateKey {
        if let raw = keychainLoad(),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        // One-time migration from the earlier UserDefaults storage.
        if let raw = UserDefaults.standard.data(forKey: identityKeyDefaultsKey),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            keychainSave(raw)
            UserDefaults.standard.removeObject(forKey: identityKeyDefaultsKey)
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        keychainSave(key.rawRepresentation)
        return key
    }

    // MARK: Keychain (identity private key storage)

    private static func keychainBaseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    private static func keychainLoad() -> Data? {
        var query = keychainBaseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess ? result as? Data : nil
    }

    private static func keychainSave(_ data: Data) {
        SecItemDelete(keychainBaseQuery() as CFDictionary)
        var add = keychainBaseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Cryptographically-random nonce for handshake freshness.
    static func randomNonce(_ count: Int = 32) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
    }

    /// Short, human-comparable fingerprint of a raw public key, e.g. `A1B2-C3D4-E5F6-0708`.
    static func fingerprint(of publicKeyRaw: Data) -> String {
        let digest = SHA256.hash(data: publicKeyRaw)
        let hex = digest.prefix(8).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 4)
            return String(hex[start..<end])
        }.joined(separator: "-")
    }

    // MARK: Key agreement

    static func deriveSessionKey(ephemeralPrivate: Curve25519.KeyAgreement.PrivateKey,
                                 remoteEphemeralPublicRaw: Data,
                                 localEphemeralPublicRaw: Data) throws -> SymmetricKey {
        let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteEphemeralPublicRaw)
        let shared = try ephemeralPrivate.sharedSecretFromKeyAgreement(with: remote)
        // Bind the derived key to both ephemeral public keys (ordered for symmetry)
        // so the session is tied to this exact handshake transcript.
        let pair = [localEphemeralPublicRaw, remoteEphemeralPublicRaw]
            .sorted { $0.lexicographicallyPrecedes($1) }
        var salt = Data(hkdfSalt)
        salt.append(pair[0])
        salt.append(pair[1])
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                              salt: salt,
                                              sharedInfo: hkdfInfo,
                                              outputByteCount: 32)
    }

    // MARK: AES-GCM

    static func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw CryptoError.sealFailed }
        return combined
    }

    static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key)
    }

    // MARK: SHA-256

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum CryptoError: Error { case sealFailed }
}
