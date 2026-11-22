import Foundation
import Security

public protocol SecretStore: Sendable {
    func passphrase(for diskID: String) -> String?
    func setPassphrase(_ value: String, for diskID: String) throws
    func removePassphrase(for diskID: String)
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// Stores repository passphrases in the login keychain, available after the first unlock.
public struct KeychainSecretStore: SecretStore {
    private let service = "org.ninelives.repository-passphrase"

    public init() {}

    private func query(_ diskID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: diskID]
    }

    public func passphrase(for diskID: String) -> String? {
        var q = query(diskID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setPassphrase(_ value: String, for diskID: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(diskID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var add = query(diskID)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Nine Lives backup passphrase"
        let s = SecItemAdd(add as CFDictionary, nil)
        guard s == errSecSuccess else { throw KeychainError(status: s) }
    }

    public func removePassphrase(for diskID: String) {
        SecItemDelete(query(diskID) as CFDictionary)
    }
}

public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func passphrase(for diskID: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[diskID] }
    public func setPassphrase(_ value: String, for diskID: String) throws { lock.lock(); values[diskID] = value; lock.unlock() }
    public func removePassphrase(for diskID: String) { lock.lock(); values[diskID] = nil; lock.unlock() }
}

public enum PassphraseGenerator {
    /// Six groups of four characters from an alphabet without look-alike characters.
    public static func generate() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var rng = SystemRandomNumberGenerator()
        let groups = (0..<6).map { _ in
            String((0..<4).map { _ in alphabet.randomElement(using: &rng)! })
        }
        return groups.joined(separator: "-")
    }
}
