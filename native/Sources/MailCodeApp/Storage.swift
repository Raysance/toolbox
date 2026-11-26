import Foundation
import Security
import MailCodeCore

struct Preferences: Codable {
    var autoCopy = true
    var showPopup = true
    var clearClipboard = true
}
struct Configuration: Codable {
    var accounts: [MailAccount] = []
    var preferences = Preferences()
    var checkpoints: [String: MailboxCheckpoint] = [:]
    var network: IMAPNetworkSettings?
}

struct ConfigurationStore {
    let directory: URL
    var file: URL { directory.appendingPathComponent("settings.json") }
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MailCode", isDirectory: true)
    }
    func load() throws -> Configuration {
        guard FileManager.default.fileExists(atPath: file.path) else { return Configuration() }
        return try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: file))
    }
    func save(_ config: Configuration) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

enum Keychain {
    private static let store = CredentialStore(service: "local.mailcode.credentials")
    static func save(_ secret: String, id: UUID) throws { try store.save(secret, id: id) }
    static func read(_ id: UUID) throws -> String { try store.read(id) }
    static func delete(_ id: UUID) throws { try store.delete(id) }
}

/// All account passwords share one encrypted Keychain item. Legacy entries are migrated
/// one at a time, and removed only after the replacement has been written and verified.
struct CredentialStore {
    let service: String
    private let vaultAccount = "InboxCode.accounts.v1"
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    private func record(_ account: String) throws -> Data? {
        var item = query(account); item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw Failure(status: errSecDecode) }
        return data
    }
    private func write(_ data: Data, account: String) throws {
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: "InboxCode"]
        let status = SecItemUpdate(query(account) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account); values.forEach { item[$0.key] = $0.value }
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }
    private func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func vault() throws -> [String: String] {
        guard let data = try record(vaultAccount) else { return [:] }
        guard let value = try? JSONDecoder().decode([String: String].self, from: data) else { throw Failure(status: errSecDecode) }
        return value
    }
    private func writeVault(_ value: [String: String]) throws {
        try write(JSONEncoder().encode(value), account: vaultAccount)
    }
    func save(_ secret: String, id: UUID) throws {
        var value = try vault(); value[id.uuidString] = secret
        try writeVault(value)
        // A duplicate legacy entry can safely remain if its deletion is denied.
        try? remove(id.uuidString)
    }
    func read(_ id: UUID) throws -> String {
        var value = try vault()
        if let secret = value[id.uuidString] { return secret }
        guard let data = try record(id.uuidString) else { throw Failure(status: errSecItemNotFound) }
        guard let secret = String(data: data, encoding: .utf8) else { throw Failure(status: errSecDecode) }
        value[id.uuidString] = secret
        try writeVault(value)
        guard try vault()[id.uuidString] == secret else { throw Failure(status: errSecDecode) }
        try? remove(id.uuidString)
        return secret
    }
    func delete(_ id: UUID) throws {
        var value = try vault()
        // Delete a legacy duplicate first. If writing the vault then fails, its old value remains.
        try remove(id.uuidString)
        if value.removeValue(forKey: id.uuidString) != nil { try writeVault(value) }
    }
    private func check(_ status: OSStatus) throws { if status != errSecSuccess { throw Failure(status: status) } }
    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Could not access Keychain (\(status)). Unlock it or save your account password again." }
    }
    static func selfTest() throws {
        let store = CredentialStore(service: "local.mailcode.selftest." + UUID().uuidString)
        defer { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service] as CFDictionary) }
        let ids = (0..<3).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            try store.write(Data("temporary-test-\(index)".utf8), account: id.uuidString)
        }
        for (index, id) in ids.enumerated() {
            guard try store.read(id) == "temporary-test-\(index)", try store.record(id.uuidString) == nil else { throw Failure(status: errSecInternalComponent) }
        }
        guard try store.vault().count == 3 else { throw Failure(status: errSecInternalComponent) }
        var records: CFTypeRef?
        try store.check(SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service, kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll] as CFDictionary, &records))
        guard let items = records as? [[String: Any]], items.count == 1,
              items[0][kSecAttrLabel as String] as? String == "InboxCode" else { throw Failure(status: errSecInternalComponent) }
        try store.save("updated-test-value", id: ids[0])
        guard try store.read(ids[0]) == "updated-test-value", try store.read(ids[1]) == "temporary-test-1" else { throw Failure(status: errSecInternalComponent) }
        try store.delete(ids[0])
        guard try store.vault().count == 2, try store.read(ids[2]) == "temporary-test-2" else { throw Failure(status: errSecInternalComponent) }
        do { _ = try store.read(ids[0]); throw Failure(status: errSecInternalComponent) }
        catch let error as Failure where error.status == errSecItemNotFound { }
        let corrupt = Data("invalid-test-vault".utf8)
        try store.write(corrupt, account: store.vaultAccount)
        do { try store.save("must-not-overwrite", id: ids[0]); throw Failure(status: errSecInternalComponent) }
        catch let error as Failure where error.status == errSecDecode { }
        guard try store.record(store.vaultAccount) == corrupt else { throw Failure(status: errSecInternalComponent) }
    }
}
