import Foundation
import Testing
@testable import MailCodeCore

struct LookupCacheTests {
    let account = MailAccount(username: "test@example.com", host: "imap.example.com")
    func handshake(validity: UInt64 = 777, next: UInt64 = 104) -> [(String, String)] {
        [("M1 CAPABILITY", "* CAPABILITY IMAP4rev1 IDLE\r\nM1 OK done\r\n"),
         ("M2 LOGIN \"test@example.com\" \"secret\"", "M2 OK done\r\n"),
         ("M3 CAPABILITY", "* CAPABILITY IMAP4rev1 IDLE\r\nM3 OK done\r\n"),
         ("M4 EXAMINE \"INBOX\"", "* 3 EXISTS\r\n* OK [UIDVALIDITY \(validity)]\r\n* OK [UIDNEXT \(next)]\r\nM4 OK selected\r\n")]
    }
    func recent() -> (String, String) {
        ("M5 FETCH 1:* (UID)", "* 1 FETCH (UID 101)\r\n* 2 FETCH (UID 102)\r\n* 3 FETCH (UID 103)\r\nM5 OK done\r\n")
    }
    func fetch(_ tag: Int, _ uid: UInt64, code: String? = nil) -> (String, String) {
        let mail = code.map { "Subject: Verification code\r\nFrom: Example <notify@example.com>\r\n\r\nYour verification code is \($0)" }
            ?? "Subject: Newsletter\r\n\r\nHello from the weekly newsletter."
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return ("M\(tag) UID FETCH \(uid) (UID INTERNALDATE BODY.PEEK[]<0.262144>)",
            "* 1 FETCH (UID \(uid) INTERNALDATE \"\(date.string(from: Date()))\" BODY[]<0> {\(mail.utf8.count)}\r\n\(mail))\r\nM\(tag) OK done\r\n")
    }
    @Test func negativeResultSurvivesRestartWithoutRefetchingBodies() async throws {
        let transport = ScriptedTransport(steps: handshake() + [recent(), fetch(6, 103), fetch(7, 102), fetch(8, 101)])
        let first = await MailLookup.latest(account: account, password: "secret", transport: transport, cached: nil)
        let entry = try #require(first.entry)
        #expect(first.error == nil && first.fetchedMessages == 3 && entry.latest == nil && entry.initialized)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LookupCacheStore(directory: directory)
        try store.save([account.id: entry])
        let restored = try store.load(accounts: [account])[account.id]
        let secondTransport = ScriptedTransport(steps: handshake())
        let second = await MailLookup.latest(account: account, password: "secret", transport: secondTransport, cached: restored)
        #expect(second.error == nil && second.fetchedMessages == 0 && second.entry?.initialized == true)
        #expect(secondTransport.steps.isEmpty)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }
    @Test func refreshReadsOnlyNewUIDsAndKeepsNewestCode() async throws {
        var cached = LookupCacheEntry(account: account, validity: 777)
        cached.initialized = true; cached.checkedThrough = 103
        let transport = ScriptedTransport(steps: handshake(next: 106) + [
            ("M5 UID SEARCH UID 104:*", "* SEARCH 104 105\r\nM5 OK done\r\n"), fetch(6, 105), fetch(7, 104, code: "483920")])
        let result = await MailLookup.latest(account: account, password: "secret", transport: transport, cached: cached)
        #expect(result.error == nil && result.fetchedMessages == 2)
        #expect(result.entry?.checkedThrough == 105 && result.entry?.latest?.code == "483920")
        #expect(transport.steps.isEmpty)
    }
    @Test func interruptedSearchResumesWithoutReopeningProcessedBodies() async throws {
        let first = ScriptedTransport(steps: handshake() + [recent(), fetch(6, 103)])
        first.failureOnCommand = fetch(7, 102).0
        let interrupted = await MailLookup.latest(account: account, password: "secret", transport: first, cached: nil)
        #expect(interrupted.error != nil && interrupted.entry?.processedUIDs == [103])
        let retry = ScriptedTransport(steps: handshake() + [recent(), fetch(6, 102), fetch(7, 101)])
        let completed = await MailLookup.latest(account: account, password: "secret", transport: retry, cached: interrupted.entry)
        #expect(completed.error == nil && completed.fetchedMessages == 2 && completed.entry?.initialized == true)
        #expect(retry.steps.isEmpty)
    }
    @Test func UIDValidityChangeInvalidatesPreviousResults() async throws {
        var cached = LookupCacheEntry(account: account, validity: 777)
        cached.initialized = true; cached.checkedThrough = 103; cached.processedUIDs = [103, 102, 101]
        let transport = ScriptedTransport(steps: handshake(validity: 888) + [recent(), fetch(6, 103, code: "483920")])
        let result = await MailLookup.latest(account: account, password: "secret", transport: transport, cached: cached)
        #expect(result.error == nil && result.fetchedMessages == 1 && result.entry?.validity == 888)
        #expect(result.entry?.latest?.code == "483920")
    }
    @Test func backgroundResultsAreReusedDuringLookup() async throws {
        var cached = LookupCacheEntry(account: account, validity: 777)
        cached.initialized = true; cached.checkedThrough = 103
        var watcher = cached; watcher.checkedThrough = 105; watcher.record(uid: 104, code: nil); watcher.record(uid: 105, code: nil)
        let observed = watcher
        let transport = ScriptedTransport(steps: handshake(next: 106))
        let result = await MailLookup.latest(account: account, password: "secret", transport: transport, cached: cached, current: { observed })
        #expect(result.error == nil && result.fetchedMessages == 0 && result.entry?.checkedThrough == 105)
    }
    @Test func mergeNeverRewindsWatcherProgress() throws {
        let mail = MIMEMessage(data: Data("From: Example\r\n\r\n".utf8))
        var old = LookupCacheEntry(account: account, validity: 777); old.checkedThrough = 103; old.record(uid: 103, code: nil)
        var newer = old; newer.initialized = true; newer.checkedThrough = 104
        newer.record(uid: 104, code: LatestCode(account: account, uid: 104, mail: mail, code: "483920", date: Date()))
        let merged = old.merging(newer)
        #expect(merged.checkedThrough == 104 && merged.latest?.code == "483920" && merged.initialized)
        #expect(merged.processedUIDs == [104, 103])
    }
    @Test func expiresCodesButKeepsScanProgressAndFiltersMailboxChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LookupCacheStore(directory: directory)
        var entry = LookupCacheEntry(account: account, validity: 777)
        entry.initialized = true; entry.checkedThrough = 103
        let mail = MIMEMessage(data: Data("From: Example\r\n\r\n".utf8))
        entry.record(uid: 103, code: LatestCode(account: account, uid: 103, mail: mail, code: "483920", date: Date()))
        try store.save([account.id: entry])
        let expired = try store.load(accounts: [account], now: Date().addingTimeInterval(86_401))[account.id]
        #expect(expired?.latest == nil && expired?.latestUID == 103 && expired?.checkedThrough == 103 && expired?.initialized == true)
        for keyPath in [\MailAccount.host, \MailAccount.username, \MailAccount.folder] {
            var changed = account; changed[keyPath: keyPath] += ".changed"
            #expect(try store.load(accounts: [changed]).isEmpty)
        }
        #expect(try store.load(accounts: []).isEmpty)
        try store.save([account.id: expired!])
        #expect(try store.load(accounts: [account])[account.id]?.latest == nil)
    }
}
