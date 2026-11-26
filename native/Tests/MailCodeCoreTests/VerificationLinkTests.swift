import Foundation
import Testing
@testable import MailCodeCore

struct VerificationLinkTests {
    let target = "https://ctrl.example.invalid/reset-password/synthetic-test-token-AbC123?token=a%2Bb%2Fc%3D&source=email"
    func mail(_ subject: String, _ body: String, html: Bool = false) -> MIMEMessage {
        MIMEMessage(data: Data("Subject: \(subject)\r\nFrom: RackNerd <noreply@example.invalid>\r\nContent-Type: text/\(html ? "html" : "plain"); charset=utf-8\r\n\r\n\(body)".utf8))
    }
    @Test func rackNerdStyleResetPreservesEntireURL() {
        let message = mail("Reset your RackNerd VPS Control Panel password", """
        Hello,
        We received a request to reset the password for your RackNerd VPS Control Panel account.
        Your username is: vmuser000000
        Use this link to choose a new password (expires in 60 minutes):
        \(target)
        IMPORTANT: After you reset your password, sign in with your USERNAME, not your email address.
        If you did not request this, you can ignore this email.
        """)
        let result = VerificationExtractor.extract(message)
        #expect(result?.kind == .link && result?.value == target)
    }
    @Test func HTMLButtonsEntitiesAndAlternatives() {
        let encoded = target.replacingOccurrences(of: "&", with: "&amp;")
        let html = "<p>Reset your password</p><a href='\(encoded)'><b>Choose a new password</b></a>"
        #expect(VerificationExtractor.extract(mail("Password reset", html, html: true))?.value == target)
        let source = """
        Subject: Password reset
        Content-Type: multipart/alternative; boundary="parts"

        --parts
        Content-Type: text/plain

        View the HTML version to reset your password.
        --parts
        Content-Type: text/html
        Content-Transfer-Encoding: base64

        \(Data(html.utf8).base64EncodedString())
        --parts--
        """
        let message = MIMEMessage(data: Data(source.utf8))
        #expect(message.text.contains("HTML version"))
        #expect(VerificationExtractor.extract(message)?.value == target)
        let quoted = "Subject: Reset your password\r\nContent-Type: text/html\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n<a href=3D\"https://auth.example.invalid/reset-password/synthetic-abc=\r\ndef-token\">Reset password</a>"
        #expect(VerificationExtractor.extract(MIMEMessage(data: Data(quoted.utf8)))?.value == "https://auth.example.invalid/reset-password/synthetic-abcdef-token")
    }
    @Test func verificationAndMagicLinksInChineseAndEnglish() {
        let cases = [
            ("Verify your email", "Please confirm your email address:", "https://auth.example.invalid/verify?token=test-token-123"),
            ("Sign in to Example", "Click this link to sign in:", "https://auth.example.invalid/magic-link/test-token-456"),
            ("验证邮箱", "请点击链接验证您的邮箱：", "https://auth.example.invalid/confirm?token=test-token-789"),
            ("登录链接", "点击下面的链接登录账号：", "https://auth.example.invalid/login?token=test-token-abc"),
            ("Reset your password", "Use this link to choose a new password:", "https://auth.example.invalid/synthetic-opaque-test-token")
        ]
        for (subject, body, url) in cases {
            #expect(VerificationExtractor.extract(mail(subject, body + "\n" + url))?.value == url)
        }
    }
    @Test func codeWinsAndOrdinaryLinksAreIgnored() {
        let message = mail("Your verification code", "Your verification code is 483920.\nUse this link to reset your password: \(target)")
        #expect(VerificationExtractor.extract(message)?.kind == .code)
        #expect(VerificationExtractor.extract(message)?.value == "483920")
        for body in ["Read our newsletter https://example.invalid/article/test-token-123", "Visit https://example.invalid/login", "Your account https://example.invalid/?utm_campaign=reset-password"] {
            #expect(VerificationExtractor.extract(mail("Weekly newsletter", body)) == nil)
        }
        #expect(VerificationExtractor.extract(mail("Reset your password", "https://example.invalid/reset/password")) == nil)
    }
    @Test func ignoreFootersQuotesAttachmentsAndAmbiguousLinks() {
        let body = "<a href='https://example.invalid/unsubscribe?token=synthetic-123'>Unsubscribe</a><a href='\(target)'>Reset password</a><a href='https://example.invalid/privacy?token=synthetic-456'>Privacy</a>" // Synthetic .invalid fixtures, not live credentials. gitleaks:allow
        #expect(VerificationExtractor.extract(mail("Reset your password", body, html: true))?.value == target)
        #expect(VerificationExtractor.extract(mail("Reset your password", "Use this link to choose a new password:\n\(target)\nhttps://ctrl.example.invalid/reset-password/other-test-token")) == nil)
        #expect(VerificationExtractor.extract(mail("Re: Reset password", "> Use this link to reset your password: \(target)")) == nil)
        #expect(VerificationExtractor.extract(mail("Re: Reset password", "<blockquote><a href='\(target)'>Reset password</a></blockquote>", html: true)) == nil)
        let attachment = "Subject: Reset your password\r\nContent-Type: text/html\r\nContent-Disposition: attachment\r\n\r\n<a href='\(target)'>Reset password</a>"
        #expect(VerificationExtractor.extract(MIMEMessage(data: Data(attachment.utf8))) == nil)
    }
    @Test func unsupportedSchemesAndMisleadingAnchorText() {
        for url in ["javascript:resetPassword('synthetic-token')", "file:///reset-password/synthetic-token", "https://user:password@example.invalid/reset-password/synthetic-token"] {
            #expect(VerificationExtractor.extract(mail("Reset your password", "<a href=\"\(url)\">\(target)</a>", html: true)) == nil)
        }
        let tracking = "https://click.example.invalid/redirect?target=synthetic-test-token"
        #expect(VerificationExtractor.extract(mail("Reset your password", "<a href='\(tracking)'>\(target)</a>", html: true))?.value == tracking)
    }
    @Test func oldCacheUpgradesOnceAndLinkRoundtrips() throws {
        let account = MailAccount(username: "test@example.invalid", host: "imap.example.invalid")
        let message = mail("Reset your password", "Use this link to reset your password: \(target)")
        let latest = LatestCode(account: account, uid: 103, mail: message, code: target, date: Date(), kind: .link)
        #expect(try JSONDecoder().decode(LatestCode.self, from: JSONEncoder().encode(latest)) == latest)
        var entry = LookupCacheEntry(account: account, validity: 777)
        entry.initialized = true; entry.checkedThrough = 103; entry.processedUIDs = [101, 102, 103]
        var oldJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        oldJSON.removeValue(forKey: "extractorVersion")
        var old = try JSONDecoder().decode(LookupCacheEntry.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        #expect(old.extractorVersion == nil)
        old.upgradeExtractor()
        #expect(!old.initialized && old.processedUIDs.isEmpty && old.checkedThrough == 0)
        old.record(uid: 103, code: latest); old.initialized = true; old.checkedThrough = 103
        let complete = old; old.upgradeExtractor()
        #expect(old == complete)
        var legacyCode = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(LatestCode(account: account, uid: 102, mail: message, code: "483920", date: Date()))) as? [String: Any])
        legacyCode.removeValue(forKey: "kind")
        #expect(!(try JSONDecoder().decode(LatestCode.self, from: JSONSerialization.data(withJSONObject: legacyCode))).isLink)
    }
    @Test func lookupCachesLinkAndDoesNotReadItAgain() async throws {
        let fixture = LookupCacheTests()
        let source = "Subject: Reset your password\r\nFrom: Example <noreply@example.invalid>\r\n\r\nUse this link to choose a new password: \(target)"
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        let fetch = ("M6 UID FETCH 103 (UID INTERNALDATE BODY.PEEK[]<0.262144>)", "* 1 FETCH (UID 103 INTERNALDATE \"\(format.string(from: Date()))\" BODY[]<0> {\(source.utf8.count)}\r\n\(source))\r\nM6 OK done\r\n")
        let first = await MailLookup.latest(account: fixture.account, password: "secret", transport: ScriptedTransport(steps: fixture.handshake() + [fixture.recent(), fetch]), cached: nil)
        #expect(first.error == nil && first.entry?.latest?.isLink == true && first.entry?.latest?.code == target)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LookupCacheStore(directory: directory)
        try store.save([fixture.account.id: #require(first.entry)])
        let second = await MailLookup.latest(account: fixture.account, password: "secret", transport: ScriptedTransport(steps: fixture.handshake()), cached: try store.load(accounts: [fixture.account])[fixture.account.id])
        #expect(second.error == nil && second.fetchedMessages == 0 && second.entry?.latest?.code == target && second.entry?.latest?.kind == .link)
    }
}
