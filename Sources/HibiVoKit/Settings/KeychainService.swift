import Foundation
import Security

/// Stores secrets in the login Keychain. Never in UserDefaults.
public protocol SecretStore: Sendable {
    func secret(for account: String) -> String?
    func setSecret(_ value: String?, for account: String) throws
}

/// API keys share one access-controlled item; IAM credentials remain separate items.
public struct KeychainService: SecretStore {
    public struct Failure: Error { public let status: OSStatus }

    static let bundleAccount = "hibivo-api-key-bundle-v1"
    static let bundledAccounts = [
        "soniox", SecretAccount.gemini, SecretAccount.anthropic,
        SecretAccount.openAICompatible, SecretAccount.bedrockAPIKey,
    ]

    private let state: State

    public init(service: String = "io.github.mori-ri.hibivo.api-keys") {
        state = State(storage: SystemKeychainStorage(service: service))
    }

    init(storage: any KeychainItemStorage) {
        state = State(storage: storage)
    }

    public func secret(for account: String) -> String? {
        state.lock.lock()
        defer { state.lock.unlock() }
        do {
            if Self.bundledAccounts.contains(account) {
                return try state.loadBundle()[account]
            }
            return try state.storage.read(account).flatMap { String(data: $0, encoding: .utf8) }
        } catch {
            return nil
        }
    }

    public func setSecret(_ value: String?, for account: String) throws {
        state.lock.lock()
        defer { state.lock.unlock() }
        let value = value.flatMap { $0.isEmpty ? nil : $0 }
        guard Self.bundledAccounts.contains(account) else {
            try state.storage.write(value.map { Data($0.utf8) }, account: account)
            return
        }
        var keys = try state.loadBundle()
        keys[account] = value
        // Keep even an empty bundle: absence means legacy migration is still needed.
        try state.storage.write(JSONEncoder().encode(keys), account: Self.bundleAccount)
        state.cachedBundle = keys
    }

    /// Serialize read-modify-write operations, including copies of this service.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        let storage: any KeychainItemStorage
        var cachedBundle: [String: String]?

        init(storage: any KeychainItemStorage) { self.storage = storage }

        func loadBundle() throws -> [String: String] {
            if let cachedBundle { return cachedBundle }
            if let data = try storage.read(KeychainService.bundleAccount) {
                // Never overwrite an unreadable or corrupt bundle with an empty dictionary.
                let keys = try JSONDecoder().decode([String: String].self, from: data)
                cachedBundle = keys
                return keys
            }
            var keys: [String: String] = [:]
            for account in KeychainService.bundledAccounts {
                if let data = try storage.read(account) {
                    guard let value = String(data: data, encoding: .utf8) else {
                        throw Failure(status: errSecDecode)
                    }
                    keys[account] = value
                }
            }
            guard !keys.isEmpty else {
                cachedBundle = keys
                return keys
            }
            // Commit all keys before removing any originals. A denied read aborts migration.
            try storage.write(JSONEncoder().encode(keys), account: KeychainService.bundleAccount)
            for account in keys.keys {
                // A failed cleanup leaves a redundant legacy item, never loses the saved key.
                try? storage.write(nil, account: account)
            }
            cachedBundle = keys
            return keys
        }
    }
}

/// Throwing reads distinguish missing items from denied access and other failures.
protocol KeychainItemStorage: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data?, account: String) throws
}

private struct SystemKeychainStorage: KeychainItemStorage {
    let service: String

    func read(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainService.Failure(status: status) }
        guard let data = result as? Data else { throw KeychainService.Failure(status: errSecDecode) }
        return data
    }

    func write(_ data: Data?, account: String) throws {
        let query = baseQuery(account)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainService.Failure(status: status)
            }
            return
        }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainService.Failure(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainService.Failure(status: status)
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
