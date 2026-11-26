import Foundation

public enum OTPExtractor {
    private struct Candidate { let code: String; let score: Int }
    public static func extract(subject: String, body: String) -> String? {
        let candidates = collect(subject, bonus: 35) + collect(body, bonus: 0)
        let scores = Dictionary(candidates.map { ($0.code, $0.score) }, uniquingKeysWith: max)
        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= 70 else { return nil }
        // Two equally plausible codes are safer left alone than copied incorrectly.
        if ranked.count > 1, best.value - ranked[1].value < 10 { return nil }
        return best.key
    }

    private static func collect(_ raw: String, bonus: Int) -> [Candidate] {
        var text = String(raw.prefix(100_000)).precomposedStringWithCompatibilityMapping
        text = text.components(separatedBy: "\n").prefix(while: { !$0.hasPrefix("On ") || !$0.hasSuffix("wrote:") }).filter { !$0.hasPrefix(">") }.joined(separator: "\n")
        text = text.replacingOccurrences(of: "(?i)https?://[^\\s<>]+|[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}", with: " ", options: .regularExpression)
        let keywordPattern = "(?i)验证码|校验码|动态码|安全码|认证码|登录码|驗證碼|確認碼|verification\\s+(?:code|number)|security\\s+code|authentication\\s+code|confirmation\\s+code|login\\s+code|sign[ -]?in\\s+code|one[ -]?time\\s+(?:password|code|passcode)|\\bOTP\\b|\\bpasscode\\b|\\bcode\\b"
        guard let keywords = try? NSRegularExpression(pattern: keywordPattern), let tokens = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])(?:[0-9]{3}[ -][0-9]{3}|[0-9]{4}[ -][0-9]{4}|[A-Za-z0-9]{4,10})(?![A-Za-z0-9])") else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        let anchors = keywords.matches(in: text, range: full).prefix(256)
        guard !anchors.isEmpty else { return [] }
        var candidates: [Candidate] = []
        for token in tokens.matches(in: text, range: full).prefix(1024) {
            guard let range = Range(token.range, in: text) else { continue }
            let original = String(text[range])
            let code = original.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
            let numeric = code.allSatisfy(\.isNumber)
            guard numeric ? (4...8).contains(code.count) : ((6...10).contains(code.count) && code.contains(where: \.isNumber) && code.contains(where: \.isLetter)) else { continue }
            // Do not extract a segment of a phone number, date, version or decimal.
            let ns = text as NSString
            let prefix = ns.substring(with: NSRange(location: max(0, token.range.location - 2), length: min(2, token.range.location)))
            let end = NSMaxRange(token.range)
            let suffix = ns.substring(with: NSRange(location: end, length: min(2, ns.length - end)))
            if prefix.range(of: "[0-9][./+()-]$", options: .regularExpression) != nil || suffix.range(of: "^[./()-][0-9]", options: .regularExpression) != nil { continue }
            if suffix.range(of: "^\\s*(?:年|月|日|元)", options: .regularExpression) != nil { continue }
            var best = 0
            for anchor in anchors {
                let after = token.range.location >= NSMaxRange(anchor.range)
                let distance = after ? token.range.location - NSMaxRange(anchor.range) : anchor.range.location - end
                guard distance >= 0, distance <= 64 else { continue }
                let start = after ? NSMaxRange(anchor.range) : end
                let bridge = ns.substring(with: NSRange(location: start, length: distance))
                if bridge.contains("http") || bridge.range(of: "[.!?。！？]", options: .regularExpression) != nil { continue }
                var score = 110 - distance * 2 + bonus + (after ? 5 : 0)
                if numeric && code.count == 6 { score += 12 }
                if code.count == 4 { score -= 8 }
                if !numeric && code != code.uppercased() { score -= 20 }
                best = max(best, score)
            }
            if best > 0 { candidates.append(Candidate(code: code, score: best)) }
        }
        return candidates
    }
}
