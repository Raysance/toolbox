import Foundation
import Testing
@testable import MailCodeCore

struct ProviderTests {
    @Test func serviceTagsInSubject() {
        #expect(ProviderExtractor.extract(subject: "【京东】登录验证码123456", body: "", sender: "no-reply@delivery.example") == "京东")
        #expect(ProviderExtractor.extract(subject: "[GitHub] Your verification code", body: "", sender: "no-reply@delivery.example") == "GitHub")
        #expect(ProviderExtractor.extract(subject: "【Vercel】验证码", body: "", sender: "no-reply@delivery.example") == "Vercel")
        #expect(ProviderExtractor.extract(subject: "【小众服务登录验证码】", body: "", sender: "no-reply@delivery.example") == "小众服务")
    }
    @Test func genericTagsAndCodeTokensAreNotServices() {
        for subject in ["【验证码】123456", "[123456]", "[AB12CD]", "【安全提醒】", "[EXTERNAL]", "[Verification code]"] {
            #expect(ProviderExtractor.extract(subject: subject, body: "", sender: "no-reply@notice.jd.com") == "京东")
        }
    }
    @Test func domainMatchesRequireBoundary() {
        #expect(ProviderExtractor.extract(subject: "", body: "", sender: "no-reply@notice.jd.com") == "京东")
        #expect(ProviderExtractor.extract(subject: "", body: "", sender: "no-reply@notjd.com") == "notjd.com")
        #expect(ProviderExtractor.extract(subject: "", body: "", sender: "no-reply@jd.com.attacker.test") == "jd.com.attacker.test")
        #expect(ProviderExtractor.extract(subject: "notgithub code", body: "", sender: "no-reply@mailer.example") == "mailer.example")
    }
    @Test func contentAndDisplayNameFallbacks() {
        #expect(ProviderExtractor.extract(subject: "登录验证", body: "【新服务】您的验证码为123456", sender: "no-reply@delivery.example") == "新服务")
        #expect(ProviderExtractor.extract(subject: "登录验证", body: "你的京东登录验证码是123456", sender: "no-reply@delivery.example") == "京东")
        #expect(ProviderExtractor.extract(subject: "登录验证", body: "验证码123456", sender: "\"Linear\" <notify@delivery.example>") == "Linear")
        #expect(ProviderExtractor.extract(subject: "登录验证", body: "> 【京东】验证码123456", sender: "no-reply@delivery.example") == "delivery.example")
    }
    @Test func ambiguousAndAbsentHintsUseSender() {
        #expect(ProviderExtractor.extract(subject: "【京东】【淘宝】验证码", body: "", sender: "no-reply@delivery.example") == "delivery.example")
        #expect(ProviderExtractor.extract(subject: "验证码", body: "", sender: "") == "Email")
    }
    @Test func notificationRetainsFullRecipientAddress() {
        let event = CodeEvent(code: "123456", sender: "no-reply@jd.com", account: "hello@example.com")
        #expect(event.provider == "京东" && event.account == "hello@example.com")
    }
}
