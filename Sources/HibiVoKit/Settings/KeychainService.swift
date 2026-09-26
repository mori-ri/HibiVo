import Foundation
import Security

/// Stores secrets (API keys) in the login Keychain. Never in UserDefaults.
public protocol SecretStore: Sendable {
    func secret(for account: String) -> String?
    func setSecret(_ value: String?, for account: String) throws
}

public struct KeychainService: SecretStore {
    public struct Failure: Error { public let status: OSStatus }

    private let service: String

    public init(service: String = "io.github.mori-ri.hibivo.api-keys") {
        self.service = service
    }

    public func secret(for account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String?, for account: String) throws {
        let query = baseQuery(account)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Failure(status: addStatus) }
        } else if status != errSecSuccess {
            throw Failure(status: status)
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
