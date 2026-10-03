import Foundation
import Security
import Testing

@testable import HibiVoKit

struct KeychainServiceTests {
    @Test func readsSharedItemOnlyOncePerService() throws {
        let data = try JSONEncoder().encode(["soniox": "speech", SecretAccount.gemini: "cleanup"])
        let storage = MemoryKeychainStorage([KeychainService.bundleAccount: String(decoding: data, as: UTF8.self)])
        let store = KeychainService(storage: storage)
        #expect(store.secret(for: "soniox") == "speech")
        #expect(store.secret(for: SecretAccount.gemini) == "cleanup")
        #expect(store.secret(for: "soniox") == "speech")
        #expect(storage.readAccounts() == [KeychainService.bundleAccount])
    }

    @Test func failedUpdatePreservesSavedAndCachedKeys() throws {
        let storage = MemoryKeychainStorage()
        let store = KeychainService(storage: storage)
        try store.setSecret("speech", for: "soniox")
        let before = storage.snapshot()
        storage.failWrite(KeychainService.bundleAccount)
        #expect(throws: KeychainService.Failure.self) { try store.setSecret("new", for: "soniox") }
        #expect(throws: KeychainService.Failure.self) { try store.setSecret(nil, for: "soniox") }
        #expect(store.secret(for: "soniox") == "speech")
        #expect(storage.snapshot() == before)
    }

    @Test func migratesAPIKeysTogetherButLeavesIAMUntouched() throws {
        let storage = MemoryKeychainStorage([
            "soniox": "speech", SecretAccount.anthropic: "cleanup",
            SecretAccount.awsSecretAccessKey: "iam-secret",
        ])
        let store = KeychainService(storage: storage)
        #expect(store.secret(for: "soniox") == "speech")
        #expect(store.secret(for: SecretAccount.anthropic) == "cleanup")
        #expect(storage.snapshot()["soniox"] == nil)
        #expect(storage.snapshot()[SecretAccount.anthropic] == nil)
        #expect(storage.snapshot()[SecretAccount.awsSecretAccessKey] == Data("iam-secret".utf8))
        let bundle = try #require(storage.snapshot()[KeychainService.bundleAccount])
        let keys = try JSONDecoder().decode([String: String].self, from: bundle)
        #expect(keys == ["soniox": "speech", SecretAccount.anthropic: "cleanup"])
        #expect(!storage.readAccounts().contains(SecretAccount.awsSecretAccessKey))
    }

    @Test func updatingAndDeletingOneKeyPreservesOthersAcrossInstances() throws {
        let storage = MemoryKeychainStorage()
        let store = KeychainService(storage: storage)
        try store.setSecret("speech", for: "soniox")
        try store.setSecret("cleanup", for: SecretAccount.gemini)
        try store.setSecret("new-speech", for: "soniox")
        try store.setSecret(nil, for: SecretAccount.gemini)
        let reopened = KeychainService(storage: storage)
        #expect(reopened.secret(for: "soniox") == "new-speech")
        #expect(reopened.secret(for: SecretAccount.gemini) == nil)
        try reopened.setSecret("", for: "soniox")
        #expect(reopened.secret(for: "soniox") == nil)
        #expect(storage.snapshot()[KeychainService.bundleAccount] != nil)
    }

    @Test func allIAMCredentialsStayInIndividualItems() throws {
        let storage = MemoryKeychainStorage()
        let store = KeychainService(storage: storage)
        for account in [SecretAccount.awsAccessKeyID, SecretAccount.awsSecretAccessKey, SecretAccount.awsSessionToken] {
            try store.setSecret("iam", for: account)
            #expect(store.secret(for: account) == "iam")
            #expect(storage.snapshot()[account] == Data("iam".utf8))
        }
        #expect(storage.snapshot()[KeychainService.bundleAccount] == nil)
        try store.setSecret(nil, for: SecretAccount.awsSessionToken)
        #expect(store.secret(for: SecretAccount.awsSessionToken) == nil)
    }

    @Test func deniedLegacyReadDoesNotCommitOrDeleteAnyKeys() {
        let storage = MemoryKeychainStorage(["soniox": "speech", SecretAccount.gemini: "cleanup"])
        storage.failRead(SecretAccount.gemini)
        let before = storage.snapshot()
        let store = KeychainService(storage: storage)
        #expect(store.secret(for: "soniox") == nil)
        #expect(throws: KeychainService.Failure.self) { try store.setSecret("new", for: "soniox") }
        #expect(storage.snapshot() == before)
    }

    @Test func failedMigrationWritePreservesOriginals() {
        let storage = MemoryKeychainStorage(["soniox": "speech"])
        storage.failWrite(KeychainService.bundleAccount)
        let before = storage.snapshot()
        #expect(KeychainService(storage: storage).secret(for: "soniox") == nil)
        #expect(storage.snapshot() == before)
    }

    @Test func failedLegacyDeletionStillLeavesUsableBundle() {
        let storage = MemoryKeychainStorage(["soniox": "speech"])
        storage.failWrite("soniox")
        #expect(KeychainService(storage: storage).secret(for: "soniox") == "speech")
        #expect(storage.snapshot()[KeychainService.bundleAccount] != nil)
        #expect(storage.snapshot()["soniox"] == Data("speech".utf8))
    }

    @Test func corruptOrDeniedBundleIsNeverOverwritten() {
        for denied in [false, true] {
            let storage = MemoryKeychainStorage([KeychainService.bundleAccount: "invalid-json", "soniox": "old"])
            if denied { storage.failRead(KeychainService.bundleAccount) }
            let before = storage.snapshot()
            let store = KeychainService(storage: storage)
            #expect(store.secret(for: "soniox") == nil)
            #expect(throws: (any Error).self) { try store.setSecret("new", for: "soniox") }
            #expect(storage.snapshot() == before)
            #expect(!storage.readAccounts().contains("soniox"))
        }
    }

    @Test func concurrentUpdatesThroughCopiesDoNotLoseKeys() async {
        let storage = MemoryKeychainStorage()
        let store = KeychainService(storage: storage)
        await withTaskGroup(of: Void.self) { group in
            for account in KeychainService.bundledAccounts {
                group.addTask { try? store.setSecret(account, for: account) }
            }
        }
        for account in KeychainService.bundledAccounts {
            #expect(store.secret(for: account) == account)
        }
    }
}

private final class MemoryKeychainStorage: KeychainItemStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data]
    private var deniedReads: Set<String> = []
    private var deniedWrites: Set<String> = []
    private var reads: [String] = []

    init(_ values: [String: String] = [:]) { self.values = values.mapValues { Data($0.utf8) } }

    func read(_ account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        reads.append(account)
        if deniedReads.contains(account) { throw KeychainService.Failure(status: errSecAuthFailed) }
        return values[account]
    }

    func write(_ data: Data?, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if deniedWrites.contains(account) { throw KeychainService.Failure(status: errSecAuthFailed) }
        values[account] = data
    }

    func failRead(_ account: String) {
        lock.lock()
        defer { lock.unlock() }
        deniedReads.insert(account)
    }

    func failWrite(_ account: String) {
        lock.lock()
        defer { lock.unlock() }
        deniedWrites.insert(account)
    }

    func snapshot() -> [String: Data] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func readAccounts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }
}
