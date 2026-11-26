import Foundation
import Testing
import CoreFoundation
@testable import MailCodeCore

struct OTPTests {
    @Test func testChineseAndEnglish() {
        #expect(OTPExtractor.extract(subject: "登录验证", body: "您的验证码为：483920，请在 5 分钟内输入。") == "483920")
        #expect(OTPExtractor.extract(subject: "Verification code: 749281", body: "Valid for 10 minutes.") == "749281")
        #expect(OTPExtractor.extract(subject: "Sign in", body: "482916 is your verification code.") == "482916")
        #expect(OTPExtractor.extract(subject: "", body: "你的驗證碼是 ６５４３２１") == "654321")
    }
    @Test func testSupportedFormats() {
        #expect(OTPExtractor.extract(subject: "", body: "Your OTP is 123 456") == "123456")
        #expect(OTPExtractor.extract(subject: "", body: "验证码：123-456") == "123456")
        #expect(OTPExtractor.extract(subject: "", body: "Security code: A7B9C2") == "A7B9C2")
        #expect(OTPExtractor.extract(subject: "", body: "验证码 8392") == "8392")
        #expect(OTPExtractor.extract(subject: "", body: "验证码 98765432") == "98765432")
    }
    @Test func testAvoidOrdinaryNumbersAndAmbiguity() {
        #expect(OTPExtractor.extract(subject: "订单已发货", body: "订单号 123456，总价 1299 元。") == nil)
        #expect(OTPExtractor.extract(subject: "", body: "Find your code at https://example.com/123456") == nil)
        #expect(OTPExtractor.extract(subject: "", body: "验证码帮助热线 13812345678") == nil)
        #expect(OTPExtractor.extract(subject: "", body: "Code reference: 2026-11-26") == nil)
        #expect(OTPExtractor.extract(subject: "", body: "验证码 123456\n验证码 654321") == nil)
        #expect(OTPExtractor.extract(subject: "", body: "> Your verification code is 123456") == nil)
    }
    @Test func testFreshness() {
        let now = Date()
        #expect(Freshness.accepts(now.addingTimeInterval(-599), now: now))
        #expect(!(Freshness.accepts(now.addingTimeInterval(-601), now: now)))
        #expect(!(Freshness.accepts(now.addingTimeInterval(120), now: now)))
        #expect(!(Freshness.accepts(nil, now: now)))
    }
    @Test func testReconnectCheckpoint() {
        let baseline = MailboxCheckpoint(validity: 8, lastUID: 500)
        #expect(MailboxCheckpoint.resume(stored: nil, baseline: baseline) == baseline)
        #expect(MailboxCheckpoint.resume(stored: MailboxCheckpoint(validity: 7, lastUID: 999), baseline: baseline) == baseline)
        let previous = MailboxCheckpoint(validity: 8, lastUID: 490)
        #expect(MailboxCheckpoint.resume(stored: previous, baseline: baseline) == previous)
    }
}

struct MIMETests {
    @Test func testRawUTF8AndBase64Header() {
        let subject = Data("你的验证码".utf8).base64EncodedString()
        let body = Data("验证码为 483920".utf8).base64EncodedString()
        let mail = MIMEMessage(data: Data("Subject: =?UTF-8?B?\(subject)?=\r\nFrom: Example <no-reply@example.com>\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(body)".utf8))
        #expect(mail.subject == "你的验证码")
        #expect(OTPExtractor.extract(subject: mail.subject, body: mail.text) == "483920")
        let raw = MIMEMessage(data: Data("Subject: 登录验证\r\n\r\n您的验证码为 123456".utf8))
        #expect(raw.subject == "登录验证")
        #expect(OTPExtractor.extract(subject: raw.subject, body: raw.text) == "123456")
    }
    @Test func testQuotedPrintableHTML() {
        let mail = MIMEMessage(data: Data("Subject: =?UTF-8?Q?Your_verification?=\r\n =?UTF-8?Q?_code?=\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n<style>.code{color:#123456}</style><p>Your verification code is <b>739=\r\n281</b></p><a href=3D\"https://example.com/999999\">Continue</a>".utf8))
        #expect(mail.subject == "Your verification code")
        #expect(OTPExtractor.extract(subject: mail.subject, body: mail.text) == "739281")
        #expect(!(mail.text.contains("999999")))
    }
    @Test func testMultipartPrefersPlainAndIgnoresAttachments() {
        let mail = MIMEMessage(data: Data("""
        Subject: Sign in
        Content-Type: multipart/mixed; boundary="outer"

        --outer
        Content-Type: multipart/alternative; boundary="inner"

        --inner
        Content-Type: text/plain

        Your verification code is 135790
        --inner
        Content-Type: text/html

        <p>Your verification code is 246801</p>
        --inner--
        --outer
        Content-Type: text/plain
        Content-Disposition: attachment; filename="secret.txt"

        Your verification code is 999999
        --outer--
        """.utf8))
        #expect(OTPExtractor.extract(subject: mail.subject, body: mail.text) == "135790")
        #expect(!(mail.text.contains("999999")))
        #expect(!(mail.text.contains("246801")))
    }
    @Test func testGB18030Body() {
        let charset = CFStringConvertIANACharSetNameToEncoding("gb18030" as CFString)
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(charset))
        var data = Data("Subject: Test\r\nContent-Type: text/plain; charset=gb18030\r\n\r\n".utf8)
        data.append("验证码 864209".data(using: encoding)!)
        #expect(OTPExtractor.extract(subject: "", body: MIMEMessage(data: data).text) == "864209")
    }
    @Test func testHTMLNumericEntities() {
        #expect(MIMEMessage.stripHTML("<p>验证码&nbsp;&#49;&#x32;3456</p>") == " 验证码 123456\n")
    }
}

final class ScriptedTransport: IMAPTransport, @unchecked Sendable {
    struct Step { let command: String; let response: Data }
    var steps: [Step]
    var bytes: [Data]
    var closed = false
    var failureOnCommand: String?
    init(greeting: String = "* OK test ready\r\n", steps: [(String, String)] = []) {
        self.steps = steps.map { Step(command: $0.0, response: Data($0.1.utf8)) }
        bytes = [Data(greeting.utf8)]
    }
    func connect() async throws { }
    func send(_ data: Data) async throws {
        if String(decoding: data, as: UTF8.self) == failureOnCommand.map({ $0 + "\r\n" }) { throw MailError.disconnected }
        guard !steps.isEmpty else { Issue.record("Unexpected command"); throw MailError.malformedResponse }
        let step = steps.removeFirst()
        #expect(String(decoding: data, as: UTF8.self) == step.command + "\r\n")
        bytes.append(step.response)
    }
    func receive(timeout: TimeInterval) async throws -> Data {
        guard !bytes.isEmpty else { throw MailError.disconnected }
        return bytes.removeFirst()
    }
    func close() { closed = true }
}

struct IMAPTests {
    private let account = MailAccount(username: "test@example.com", host: "imap.example.com")
    private func initialSteps(idle: Bool = true) -> [(String, String)] {
        [
            ("M1 CAPABILITY", "* CAPABILITY IMAP4rev1 \(idle ? "IDLE" : "")\r\nM1 OK done\r\n"),
            ("M2 LOGIN \"test@example.com\" \"secret\"", "M2 OK authenticated\r\n"),
            ("M3 CAPABILITY", "* CAPABILITY IMAP4rev1 \(idle ? "IDLE" : "")\r\nM3 OK done\r\n"),
            ("M4 EXAMINE \"INBOX\"", "* 3 EXISTS\r\n* OK [UIDVALIDITY 777] valid\r\n* OK [UIDNEXT 104] next\r\nM4 OK [READ-ONLY] selected\r\n")
        ]
    }
    @Test func testReadOnlyFetchAndNoUIDReplay() async throws {
        let mail = "Subject: verification code\r\n\r\nYour code is 123456\r\nM6 OK this is message content"
        let transport = ScriptedTransport(steps: initialSteps() + [
            ("M5 UID SEARCH UID 104:*", "* SEARCH 103 104\r\nM5 OK done\r\n"),
            ("M6 UID FETCH 104 (UID INTERNALDATE BODY.PEEK[]<0.262144>)", "* 4 FETCH (UID 104 INTERNALDATE \"26-Nov-2026 16:30:00 +0800\" BODY[]<0> {\(mail.utf8.count)}\r\n\(mail))\r\nM6 OK done\r\n")
        ])
        let session = IMAPSession(transport: transport)
        let checkpoint = try await session.open(account: account, password: "secret")
        #expect(checkpoint == MailboxCheckpoint(validity: 777, lastUID: 103))
        let ids = try await session.newUIDs(after: checkpoint.lastUID)
        #expect(ids == [104])
        let fetched = try await session.fetch(uid: 104)
        #expect(fetched?.0 == Data(mail.utf8)); #expect(fetched?.1 != nil)
        #expect(transport.steps.isEmpty)
    }
    @Test func testIdleExitsUsingDONE() async throws {
        let transport = ScriptedTransport(steps: initialSteps() + [
            ("M5 IDLE", "+ idling\r\n* 4 EXISTS\r\n"),
            ("DONE", "M5 OK idle completed\r\n")
        ])
        let session = IMAPSession(transport: transport)
        _ = try await session.open(account: account, password: "secret")
        try await session.waitForChange()
        #expect(transport.steps.isEmpty)
    }
    @Test func testRecentLookupIsBoundedAndNewestFirst() async throws {
        let transport = ScriptedTransport(steps: initialSteps() + [
            ("M5 FETCH 2:* (UID)", "* 2 FETCH (UID 102)\r\n* 3 FETCH (UID 103)\r\nM5 OK done\r\n")
        ])
        let session = IMAPSession(transport: transport)
        _ = try await session.open(account: account, password: "secret")
        let ids = try await session.recentUIDs(limit: 2)
        #expect(ids == [103, 102])
        #expect(transport.steps.isEmpty)
    }
    @Test func testIdleFallbackWhenServerRejects() async throws {
        let transport = ScriptedTransport(steps: initialSteps() + [("M5 IDLE", "M5 BAD unavailable\r\n")])
        let session = IMAPSession(transport: transport)
        _ = try await session.open(account: account, password: "secret")
        try await session.waitForChange()
        let idle = await session.supportsIdle
        #expect(!(idle))
    }
    @Test func testPlainAuthenticationAndID() async throws {
        let payload = Data("\0test@example.com\0secret".utf8).base64EncodedString()
        let transport = ScriptedTransport(steps: [
            ("M1 CAPABILITY", "* CAPABILITY IMAP4rev1 AUTH=PLAIN ID\r\nM1 OK done\r\n"),
            ("M2 AUTHENTICATE PLAIN", "+ \r\n"),
            (payload, "M2 OK done\r\n"),
            ("M3 CAPABILITY", "* CAPABILITY IMAP4rev1 AUTH=PLAIN ID\r\nM3 OK done\r\n"),
            ("M4 ID (\"name\" \"MailCode\" \"version\" \"0.1.0\")", "* ID NIL\r\nM4 OK done\r\n"),
            ("M5 EXAMINE \"INBOX\"", "* OK [UIDVALIDITY 9]\r\n* OK [UIDNEXT 1]\r\nM5 OK done\r\n")
        ])
        let session = IMAPSession(transport: transport)
        let cursor = try await session.open(account: account, password: "secret")
        #expect(cursor.lastUID == 0)
        #expect(transport.steps.isEmpty)
    }
    @Test func testRejectedLogin() async throws {
        let transport = ScriptedTransport(steps: [
            ("M1 CAPABILITY", "* CAPABILITY IMAP4rev1\r\nM1 OK done\r\n"),
            ("M2 LOGIN \"test@example.com\" \"secret\"", "M2 NO bad password\r\n")
        ])
        do { _ = try await IMAPSession(transport: transport).open(account: account, password: "secret"); Issue.record("Expected failure") }
        catch { #expect(error as? MailError == .authenticationFailed) }
    }
    @Test func testByteFragmentationAndLiteralBoundaries() async throws {
        let literal = "M1 OK fake\r\n验证码 123456"
        let response = "* 1 FETCH (BODY[] {\(literal.utf8.count)}\r\n\(literal))\r\nM1 OK done\r\n"
        let transport = ScriptedTransport(greeting: "")
        transport.bytes = Data(response.utf8).map { Data([$0]) }
        let wire = IMAPWire(transport: transport)
        let frame = try await wire.frame()
        #expect(frame.literals == [Data(literal.utf8)])
        let completion = try await wire.frame()
        #expect(completion.line == "M1 OK done")
    }
    @Test func testOversizedLiteralIsRejected() async {
        let wire = IMAPWire(transport: ScriptedTransport(greeting: "* 1 FETCH (BODY[] {999999999}\r\n"))
        do { _ = try await wire.frame(); Issue.record("Expected failure") }
        catch { #expect(error as? MailError == .responseTooLarge) }
    }
    @Test func testMailboxEncodingAndInjectionPrevention() throws {
        #expect(IMAPSession.mailboxName("INBOX") == "INBOX")
        #expect(IMAPSession.mailboxName("A&B") == "A&-B")
        #expect(IMAPSession.mailboxName("台北") == "&U,BTFw-")
        #expect(IMAPSession.quote("a\"b\\c") == "\"a\\\"b\\\\c\"")
        var bad = account; bad.username = "user\r\nM1 LOGOUT"
        #expect(throws: (any Error).self) { try bad.validate(password: "secret") }
        #expect(throws: (any Error).self) { try account.validate(password: "secret\n") }
    }
}
