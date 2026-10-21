import Foundation
import Security

/// Stores the Mistral API key in the user's login Keychain (generic password item).
/// The key is never written to UserDefaults, files or logs.
public struct KeychainStore: Sendable {
    public static let service = "local.leblab.LeBlab"
    public static let apiKeyAccount = "mistral-api-key"
    /// Service name used before the app was renamed to Le Blab.
    public static let legacyService = "local.murmur.Murmur"

    public let service: String
    public let account: String

    public init(service: String = KeychainStore.service, account: String = KeychainStore.apiKeyAccount) {
        self.service = service
        self.account = account
    }

    public enum KeychainError: Error, Equatable, CustomStringConvertible {
        case unexpectedStatus(OSStatus)
        case accessDenied
        public var description: String {
            switch self {
            case .accessDenied: return "Keychain access was denied."
            case .unexpectedStatus(let s):
                let message = SecCopyErrorMessageString(s, nil) as String? ?? "OSStatus \(s)"
                return "Keychain error: \(message)"
            }
        }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// May show a system "allow access" prompt the first time — call off the main thread.
    public func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : key
        case errSecItemNotFound: return nil
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed: throw KeychainError.accessDenied
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    public func save(_ value: String) throws {
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Le Blab — Mistral API key"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Reads the key; if it only exists under the pre-rename service name, copies it over once.
    public func readMigratingLegacy() throws -> String? {
        if let key = try read() { return key }
        guard service == Self.service,
              let legacy = try KeychainStore(service: Self.legacyService, account: account).read() else { return nil }
        try save(legacy)
        return legacy
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
    }
}
