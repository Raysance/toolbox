import Foundation

public enum VerificationKind: String, Codable, Sendable { case code, link }

public struct VerificationPayload: Equatable, Sendable {
    public let value: String
    public let kind: VerificationKind
}

public struct MailLink: Equatable, Sendable {
    public let url: String
    public let label: String
    public let context: String
}

public enum VerificationExtractor {
    public static let version = 2
    public static func extract(_ mail: MIMEMessage) -> VerificationPayload? {
        if let code = OTPExtractor.extract(subject: mail.subject, body: mail.text) {
            return VerificationPayload(value: code, kind: .code)
        }
        if let link = authenticationLink(in: mail) { return VerificationPayload(value: link, kind: .link) }
        return nil
    }

    private static let action = #"(?i)(?:reset|recover|change|choose|set|create|new)[\s\S]{0,35}?password|password[\s\S]{0,25}?(?:reset|recovery)|(?:verify|confirm|activate)[\s\S]{0,30}?(?:email|e-mail|account|address|sign[ -]?in|log[ -]?in)|(?:sign[ -]?in|log[ -]?in|magic|one[ -]?time)[\s\S]{0,25}?link|(?:click|tap|use|follow)[\s\S]{0,40}?(?:sign[ -]?in|log[ -]?in)|(?:重置|找回|修改|设置|设置新|設定|重設|找回)[\s\S]{0,12}?(?:密码|密碼)|(?:验证|驗證|确认|確認|激活|啟用)[\s\S]{0,12}?(?:邮箱|郵箱|邮件|郵件|账户|帳戶|账号|帳號)|(?:登录|登入|登錄)[\s\S]{0,12}?(?:链接|連結)|(?:点击|點擊)[\s\S]{0,12}?(?:登录|登入|登錄)"#
    private static let signIn = #"(?i)^\s*(?:sign[ -]?in|log[ -]?in|登录|登入|登錄)(?:\b|\s|$)"#
    private static let route = #"(?i)(?:^|[/_.-])(?:reset(?:[-_]?password)?|password[-_]?reset|recover|verify(?:[-_]?email)?|confirm(?:[-_]?email)?|activate|activation|magic(?:[-_]?link)?|signin|sign-in|login|log-in|authenticate)(?:$|[/_.-])"#
    private static let excluded = #"(?i)(?:unsubscribe|opt[-_]?out|privacy|terms|preferences|退订|退訂|取消订阅|取消訂閱)|/(?:help|support|docs|blog|articles?)(?:/|$)"#
    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
    private static func authenticationLink(in mail: MIMEMessage) -> String? {
        let subjectAction = matches(mail.subject, action) || matches(mail.subject, signIn)
        var scores: [String: Int] = [:]
        for link in mail.links.prefix(256) {
            guard let url = URLComponents(string: link.url), let host = url.host, !host.isEmpty,
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
                  link.url.utf8.count <= 8192, !link.url.contains(where: { $0.isWhitespace || $0.isNewline }),
                  !link.url.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !matches(url.path + " " + link.label, excluded) else { continue }
            let pathAction = matches(url.path, route)
            let labelAction = matches(link.label, action) || (subjectAction && matches(link.label, signIn))
            let contextAction = matches(link.context, action)
            let queryToken = url.queryItems?.contains {
                !["utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term", "source", "ref"].contains($0.name.lowercased()) && ($0.value?.count ?? 0) >= 6
            } ?? false
            let last = url.path.split(separator: "/").last.map(String.init) ?? ""
            let generic = ["password", "email", "account", "reset-password", "reset_password", "verify-email", "verification", "confirmation", "authentication"]
            let pathToken = !generic.contains(last.lowercased()) && (last.count >= 12 || (pathAction && last.count >= 6 && !matches(last, route)))
            guard queryToken || pathToken || (url.fragment?.count ?? 0) >= 12 else { continue }
            guard labelAction || (pathAction && (subjectAction || contextAction)) || (subjectAction && contextAction) else { continue }
            let score = (labelAction ? 90 : 0) + (pathAction ? 55 : 0) + (subjectAction ? 25 : 0) + (contextAction ? 50 : 0)
            scores[link.url] = max(scores[link.url] ?? 0, score)
        }
        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= 75 else { return nil }
        if ranked.count > 1, best.value - ranked[1].value < 15 { return nil }
        return best.key
    }
}
