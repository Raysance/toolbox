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
    public let kind: VerificationKind
    public var isLink: Bool { kind == .link }
    public init(code: String, sender: String, account: String, received: Date = Date(), provider: String? = nil, kind: VerificationKind = .code) {
        self.id = UUID(); self.code = code; self.sender = sender; self.account = account; self.received = received
        self.provider = provider ?? ProviderExtractor.extract(subject: "", body: "", sender: sender)
        self.kind = kind
    }
}

public enum MailError: Error, LocalizedError, Equatable {
    case invalidConfiguration, disconnected, timeout, connectionFailed, malformedResponse, responseTooLarge
    case authenticationFailed, commandRejected(String), missingMailboxMetadata
    case invalidProxyConfiguration, proxyRequiresNewerOS
    public var errorDescription: String? {
        switch self {
        case .invalidProxyConfiguration: return "Enter a proxy host and a port from 1 to 65535."
        case .proxyRequiresNewerOS: return "Custom proxies require macOS 14 or later."
        case .invalidConfiguration: return "Check the email, server hostname, port, and password or app password."
        case .disconnected: return "Disconnected. InboxCode will reconnect automatically."
        case .timeout: return "Mail server timed out. Check your connection and IMAP settings."
        case .connectionFailed: return "Could not establish a secure connection. Check your connection mode, proxy, and IMAP server."
        case .malformedResponse: return "The mail server returned an invalid response."
        case .responseTooLarge: return "The server response was too large. Connection closed."
        case .authenticationFailed: return "Sign-in failed. Enable IMAP and use your QQ app password, Google app password, or SJTU jAccount password. OAuth-only accounts are not supported."
        case .commandRejected(let operation): return "The server rejected \(operation). Check IMAP access and the mailbox name."
        case .missingMailboxMetadata: return "The server did not provide valid UID metadata. Monitoring is unavailable."
        }
    }
}

public enum Freshness {
    public static func accepts(_ date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return false }
        return date.timeIntervalSince(now) <= 60 && now.timeIntervalSince(date) <= 600
    }
}
