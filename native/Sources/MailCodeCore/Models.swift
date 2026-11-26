import Foundation

public struct MailAccount: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var username: String
    public var host: String
    public var port: UInt16
    public var folder: String
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String = "", username: String = "", host: String = "", port: UInt16 = 993, folder: String = "INBOX", enabled: Bool = true) {
        self.id = id; self.name = name; self.username = username; self.host = host
        self.port = port; self.folder = folder; self.enabled = enabled
    }
    public var displayName: String { name.isEmpty ? username : name }
    public func validate(password: String) throws {
        guard !username.isEmpty, !host.isEmpty, !folder.isEmpty, !password.isEmpty, port > 0,
              !host.contains(":"), !host.contains("/"), !host.contains(where: \.isWhitespace),
              [username, password, folder].allSatisfy({ !$0.utf8.contains(where: { $0 == 13 || $0 == 10 || $0 == 0 }) }) else {
            throw MailError.invalidConfiguration
        }
    }
}

public struct MailboxCheckpoint: Codable, Equatable, Sendable {
    public var validity: UInt64
    public var lastUID: UInt64
    public init(validity: UInt64, lastUID: UInt64) { self.validity = validity; self.lastUID = lastUID }
    public static func resume(stored: MailboxCheckpoint?, baseline: MailboxCheckpoint) -> MailboxCheckpoint {
        guard let stored, stored.validity == baseline.validity else { return baseline }
        return stored
    }
}

public struct CodeEvent: Identifiable, Sendable {
    public let id: UUID
    public let code: String
    public let sender: String
    public let account: String
    public let provider: String
    public let received: Date
    public init(code: String, sender: String, account: String, received: Date = Date(), provider: String? = nil) {
        self.id = UUID(); self.code = code; self.sender = sender; self.account = account; self.received = received
        self.provider = provider ?? ProviderExtractor.extract(subject: "", body: "", sender: sender)
    }
}

public enum MailError: Error, LocalizedError, Equatable {
    case invalidConfiguration, disconnected, timeout, connectionFailed, malformedResponse, responseTooLarge
    case authenticationFailed, commandRejected(String), missingMailboxMetadata
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "请检查邮箱、服务器、端口及密码或授权码。服务器只填域名。"
        case .disconnected: return "连接已断开，稍后自动重连。"
        case .timeout: return "邮箱服务器响应超时，请检查网络和 IMAP 服务是否开启。"
        case .connectionFailed: return "无法建立加密连接，已尝试系统网络与直连。请检查代理和 IMAP 地址。"
        case .malformedResponse: return "服务器响应格式无法识别。"
        case .responseTooLarge: return "服务器返回的数据过大，已断开连接。"
        case .authenticationFailed: return "登录失败。请确认 IMAP 已开启，并填写对应凭据：QQ 授权码、Google 应用专用密码，或交大 jAccount 密码。仅支持 OAuth 的账号暂不可用。"
        case .commandRejected(let operation): return "邮箱拒绝了 \(operation) 请求，请检查 IMAP 权限和收件夹名称。"
        case .missingMailboxMetadata: return "邮箱未提供有效的 UID 信息，暂时无法监听。"
        }
    }
}

public enum Freshness {
    public static func accepts(_ date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return false }
        return date.timeIntervalSince(now) <= 60 && now.timeIntervalSince(date) <= 600
    }
}
