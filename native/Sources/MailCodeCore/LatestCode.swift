import Foundation

public struct LatestCode: Codable, Equatable, Sendable {
    public let id: String
    public let accountID: UUID
    public let account: String
    public let username: String
    public let provider: String
    public let sender: String
    public let code: String
    public let kind: VerificationKind?
    public var isLink: Bool { kind == .link }
    public let receivedAt: TimeInterval
    public init(account: MailAccount, uid: UInt64, mail: MIMEMessage, code: String, date: Date, kind: VerificationKind = .code) {
        id = account.id.uuidString + ":" + String(uid); accountID = account.id
        self.account = account.displayName; username = account.username
        sender = mail.sender; self.code = code; self.kind = kind; receivedAt = date.timeIntervalSince1970
        provider = ProviderExtractor.extract(subject: mail.subject, body: mail.text, sender: mail.sender)
    }
}
