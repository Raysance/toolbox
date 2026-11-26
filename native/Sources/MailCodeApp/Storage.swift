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
    private static let service = "local.mailcode.credentials"
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    static func save(_ secret: String, id: UUID) throws {
        let values: [String: Any] = [kSecValueData as String: Data(secret.utf8), kSecAttrLabel as String: "InboxCode · 邮箱授权码"]
        let status = SecItemUpdate(query(id) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(id); values.forEach { item[$0.key] = $0.value }
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }
    static func read(_ id: UUID) throws -> String {
        var item = query(id); item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        try check(SecItemCopyMatching(item as CFDictionary, &result))
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else { throw KeychainError(status: errSecDecode) }
        return secret
    }
    static func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private static func check(_ status: OSStatus) throws { if status != errSecSuccess { throw KeychainError(status: status) } }
    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "无法访问钥匙串（\(status)）。请解锁钥匙串，或重新保存邮箱授权码。" }
    }
}
