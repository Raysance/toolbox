import Foundation
import MailCodeCore

struct LatestCode: Codable, Sendable {
    let id: String
    let accountID: UUID
    let account: String
    let username: String
    let provider: String
    let sender: String
    let code: String
    let receivedAt: TimeInterval
    init(account: MailAccount, uid: UInt64, mail: MIMEMessage, code: String, date: Date) {
        id = account.id.uuidString + ":" + String(uid); accountID = account.id
        self.account = account.displayName; username = account.username
        sender = mail.sender; self.code = code; receivedAt = date.timeIntervalSince1970
        provider = ProviderExtractor.extract(subject: mail.subject, body: mail.text, sender: mail.sender)
    }
}

struct LookupResult: Sendable {
    let accountID: UUID
    let code: LatestCode?
    let error: String?
}

enum MailLookup {
    static func latest(account: MailAccount, password: String) async -> LookupResult {
        let transport = TLSIMAPTransport(host: account.host, port: account.port)
        let session = IMAPSession(transport: transport)
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: 45_000_000_000); transport.close() } catch { }
        }
        defer { deadline.cancel(); transport.close() }
        do {
            _ = try await session.open(account: account, password: password)
            for uid in try await session.recentUIDs() {
                try Task.checkCancellation()
                guard let (data, date) = try await session.fetch(uid: uid), let date else { continue }
                let mail = MIMEMessage(data: data)
                if let code = OTPExtractor.extract(subject: mail.subject, body: mail.text) {
                    return LookupResult(accountID: account.id, code: LatestCode(account: account, uid: uid, mail: mail, code: code, date: date), error: nil)
                }
            }
            return LookupResult(accountID: account.id, code: nil, error: nil)
        } catch {
            return LookupResult(accountID: account.id, code: nil, error: error.localizedDescription)
        }
    }
}
