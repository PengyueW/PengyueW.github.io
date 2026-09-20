import Foundation
import CryptoKit
import Security

/// AES-256-GCM at-rest encryption for the data Continuum persists locally
/// (scan results, history, block rules, automations). The symmetric key is
/// generated on first use and kept in the login Keychain — so the ciphertext
/// written to disk or `UserDefaults` is meaningless to anyone who copies the
/// files without the user's unlocked keychain.
///
/// `seal` returns `nil` if the key is unavailable; callers must treat that as
/// "do not persist" rather than falling back to plaintext. `open` transparently
/// passes through any legacy plaintext written before encryption existed, so
/// upgrades don't lose data.
enum SecureStore {
    /// Shared across every Continuum module so they all use the same key.
    private static let service = "local.continuum.app"
    private static let account = "datastore-key-v1"

    /// Tags our ciphertext so `open` can distinguish it from legacy plaintext.
    private static let magic = Data("CTNM01".utf8)

    // MARK: Seal / open

    static func seal(_ plaintext: Data) -> Data? {
        guard let key = key(),
              let box = try? AES.GCM.seal(plaintext, using: key),
              let combined = box.combined
        else { return nil }
        return magic + combined
    }

    static func open(_ blob: Data) -> Data? {
        guard blob.count >= magic.count,
              blob.prefix(magic.count) == magic
        else { return blob }            // legacy plaintext — pass through
        guard let key = key() else { return nil }
        let body = blob.suffix(from: blob.startIndex + magic.count)
        guard let box = try? AES.GCM.SealedBox(combined: Data(body)),
              let clear = try? AES.GCM.open(box, using: key)
        else { return nil }
        return clear
    }

    // MARK: Keychain-backed key

    private static func key() -> SymmetricKey? {
        if let existing = loadKey() { return existing }
        let fresh = SymmetricKey(size: .bits256)
        return storeKey(fresh) ? fresh : nil
    }

    private static func loadKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, data.count == 32
        else { return nil }
        return SymmetricKey(data: data)
    }

    private static func storeKey(_ key: SymmetricKey) -> Bool {
        let data = key.withUnsafeBytes { Data($0) }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(attrs as CFDictionary)
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }
}
