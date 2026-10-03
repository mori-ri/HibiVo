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

    /// `migratesLegacyItems: false` never writes: legacy items are read only for the requested account. Tools like
    /// HibiVoEval use it so they don't prompt for unrelated keys or create the shared item under their own ACL.
    public init(service: String = "io.github.mori-ri.hibivo.api-keys", migratesLegacyItems: Bool = true) {
        state = State(storage: SystemKeychainStorage(service: service), migratesLegacyItems: migratesLegacyItems)
    }

    init(storage: any KeychainItemStorage, migratesLegacyItems: Bool = true) {
        state = State(storage: storage, migratesLegacyItems: migratesLegacyItems)
    }

    public func secret(for account: String) -> String? {
        state.lock.lock()
        defer { state.lock.unlock() }
        do {
            if Self.bundledAccounts.contains(account) {
                if let value = try state.loadBundle()[account] { return value }
                guard !state.migratesLegacyItems else { return nil }
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
        var keys = try state.loadBundle(replacingCorrupt: true)
        keys[account] = value
        try state.storage.write(JSONEncoder().encode(keys), account: Self.bundleAccount)
        state.cachedBundle = keys
        // A legacy item left behind (e.g. once denied) would otherwise come back after this save.
        try? state.storage.write(nil, account: account)
    }

    /// Serialize read-modify-write operations, including copies of this service.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        let storage: any KeychainItemStorage
        let migratesLegacyItems: Bool
        var cachedBundle: [String: String]?

        init(storage: any KeychainItemStorage, migratesLegacyItems: Bool) {
            self.storage = storage
            self.migratesLegacyItems = migratesLegacyItems
        }

        /// `replacingCorrupt` lets an explicit save start over when the bundle can't be decoded; its contents
        /// are lost either way, and refusing would leave no way to store keys again.
        func loadBundle(replacingCorrupt: Bool = false) throws -> [String: String] {
            if let cachedBundle { return cachedBundle }
            var keys: [String: String] = [:]
            var corrupt = false
            // A denied bundle read throws, so it is never overwritten with partial keys.
            if let data = try storage.read(KeychainService.bundleAccount) {
                do {
                    keys = try JSONDecoder().decode([String: String].self, from: data)
                } catch {
                    guard replacingCorrupt else { throw error }
                    corrupt = true
                }
            }
            // Migrate legacy items not yet in the bundle. An unreadable one (e.g. access denied) is skipped and
            // left in place for a later launch, so it never blocks the other keys.
            var migrated: [String] = []
            for account in KeychainService.bundledAccounts where migratesLegacyItems && keys[account] == nil {
                guard let data = try? storage.read(account), let value = String(data: data, encoding: .utf8) else {
                    continue
                }
                keys[account] = value
                migrated.append(account)
            }
            if !migrated.isEmpty {
                // Commit all keys before removing any originals.
                try storage.write(JSONEncoder().encode(keys), account: KeychainService.bundleAccount)
                for account in migrated {
                    // A failed cleanup leaves a redundant legacy item, never loses the saved key.
                    try? storage.write(nil, account: account)
                }
            } else if corrupt {
                // The stored bundle still differs from `keys`; let the caller's write settle it.
                return keys
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
