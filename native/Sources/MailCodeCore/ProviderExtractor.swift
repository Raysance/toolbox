import Foundation

/// Display labels inferred from mail content, not authenticated sender identities.
public enum ProviderExtractor {
    private struct Brand {
        let name: String
        let aliases: [String]
        let domains: [String]
    }
    private static let brands: [Brand] = [
        Brand(name: "京东", aliases: ["京东", "JD.com"], domains: ["jd.com", "360buy.com"]),
        Brand(name: "淘宝", aliases: ["淘宝", "Taobao"], domains: ["taobao.com"]),
        Brand(name: "支付宝", aliases: ["支付宝", "Alipay"], domains: ["alipay.com"]),
        Brand(name: "GitHub", aliases: ["GitHub"], domains: ["github.com"]),
        Brand(name: "OpenAI", aliases: ["OpenAI", "ChatGPT"], domains: ["openai.com"]),
        Brand(name: "Google", aliases: ["Google", "谷歌"], domains: ["google.com", "accounts.google.com"]),
        Brand(name: "Apple", aliases: ["Apple", "苹果账户"], domains: ["apple.com"]),
        Brand(name: "Microsoft", aliases: ["Microsoft", "微软"], domains: ["accountprotection.microsoft.com", "microsoft.com"]),
        Brand(name: "哔哩哔哩", aliases: ["哔哩哔哩", "bilibili"], domains: ["bilibili.com"]),
        Brand(name: "12306", aliases: ["12306"], domains: ["12306.cn"])
    ]
    private static let keyword = "验证码|驗證碼|校验码|登录码|verification\\s+code|security\\s+code|login\\s+code|one[ -]?time\\s+(?:code|password)|\\bOTP\\b|\\bpasscode\\b"

    public static func extract(subject: String, body: String, sender: String) -> String {
        let subject = String(subject.prefix(500)).precomposedStringWithCompatibilityMapping
        let sender = String(sender.prefix(500))
        let domain = senderDomain(sender)
        // Titles usually explicitly identify the service, including mail sent by delivery vendors.
        if let label = bracketLabel(subject) { return label }
        if let brand = knownBrand(subject) { return brand }
        if let domain, let brand = brands.first(where: { brand in
            brand.domains.contains { domain == $0 || domain.hasSuffix("." + $0) }
        }) { return brand.name }
        // Only inspect body text near code language, excluding quoted replies and URLs.
        let body = String(body.prefix(8_000)).components(separatedBy: "\n")
            .prefix(while: { !$0.hasPrefix("On ") || !$0.hasSuffix("wrote:") })
            .filter { !$0.hasPrefix(">") }.joined(separator: "\n")
            .replacingOccurrences(of: "(?i)https?://[^\\s<>]+", with: " ", options: .regularExpression)
        if let regex = try? NSRegularExpression(pattern: keyword, options: .caseInsensitive) {
            let ns = body as NSString
            for match in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)).prefix(12) {
                let start = max(0, match.range.location - 100)
                let end = min(ns.length, NSMaxRange(match.range) + 100)
                let context = ns.substring(with: NSRange(location: start, length: end - start))
                if let label = bracketLabel(context) { return label }
                if let brand = knownBrand(context) { return brand }
            }
        }
        let display = sender.components(separatedBy: "<").first?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\""))) ?? ""
        if let label = cleanLabel(display) { return knownBrand(label) ?? label }
        return domain ?? "Email"
    }

    private static func knownBrand(_ text: String) -> String? {
        let matches = brands.filter { brand in brand.aliases.contains { alias in
            // Latin brand names must be separate words; e.g. "notgithub" is not GitHub.
            let latin = alias.unicodeScalars.allSatisfy { $0.isASCII }
            let pattern = (latin ? "(?<![a-z0-9._%-])" : "") + NSRegularExpression.escapedPattern(for: alias) + (latin ? "(?![a-z0-9._%-])" : "")
            return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        } }
        return matches.count == 1 ? matches[0].name : nil
    }
    private static func bracketLabel(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "【([^】\\r\\n]{1,40})】|\\[([^\\]\\r\\n]{1,40})\\]") else { return nil }
        var labels: [String] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(8) {
            for index in 1..<match.numberOfRanges {
                if let range = Range(match.range(at: index), in: text), let label = cleanLabel(String(text[range])) {
                    let name = knownBrand(label) ?? label
                    if !labels.contains(name) { labels.append(name) }
                }
            }
        }
        return labels.count == 1 ? labels[0] : nil
    }
    private static func cleanLabel(_ value: String) -> String? {
        guard !value.contains("@"), !value.contains(":"), !value.contains("/") else { return nil }
        if let brand = knownBrand(value) { return brand }
        var label = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<3 {
            label = label.replacingOccurrences(of: "(?i)(?:登录验证码|登錄驗證碼|验证码|驗證碼|校验码|安全码|登录验证|登录|验证|通知|verification\\s+code|security\\s+code)$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let generic = ["安全提醒", "安全", "提醒", "账户", "账号", "邮箱", "邮件", "系统", "系统消息", "身份", "no-reply", "noreply", "no reply", "do not reply", "notification", "notifications", "security", "verification", "code", "otp", "external", "warning", "重要", "重要通知"]
        guard (2...32).contains(label.count), !generic.contains(label.lowercased()),
              !label.contains("@"), !label.contains(":"), !label.contains("/"),
              label.range(of: "^[0-9]+$", options: .regularExpression) == nil,
              label.range(of: "^(?=.*[0-9])(?=.*[A-Za-z])[A-Za-z0-9]{6,10}$", options: .regularExpression) == nil else { return nil }
        return label
    }
    private static func senderDomain(_ sender: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?i)[a-z0-9._%+-]+@([a-z0-9.-]+\\.[a-z]{2,})"),
              let match = regex.matches(in: sender, range: NSRange(sender.startIndex..., in: sender)).last,
              let range = Range(match.range(at: 1), in: sender) else { return nil }
        return sender[range].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
