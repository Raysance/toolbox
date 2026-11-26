import Foundation
import CoreFoundation

public struct MIMEMessage: Sendable {
    public let subject: String
    public let sender: String
    public let text: String
    public let links: [MailLink]

    public init(data: Data) {
        let raw = String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        let (headers, body) = Self.split(raw)
        subject = Self.decodeHeader(headers["subject"] ?? "")
        sender = Self.decodeHeader(headers["from"] ?? "Unknown Sender")
        let content = Self.parts(headers: headers, body: body, depth: 0)
        text = content.text.joined(separator: "\n")
        links = Array(content.links.prefix(256))
    }

    private static func split(_ raw: String) -> ([String: String], String) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard let divider = normalized.range(of: "\n\n") else { return ([:], normalized) }
        let unfolded = String(normalized[..<divider.lowerBound]).replacingOccurrences(of: "\n[ \t]+", with: " ", options: .regularExpression)
        var headers: [String: String] = [:]
        for line in unfolded.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (headers, String(normalized[divider.upperBound...]))
    }

    private static func parameter(_ name: String, in value: String) -> String? {
        let pattern = "(?i)(?:^|;)\\s*" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*(?:\"([^\"]*)\"|([^;\\s]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        for i in 1...2 { if let range = Range(match.range(at: i), in: value) { return String(value[range]) } }
        return nil
    }

    private static func parts(headers: [String: String], body: String, depth: Int) -> (text: [String], links: [MailLink]) {
        guard depth < 8 else { return ([], []) }
        let type = headers["content-type"] ?? "text/plain; charset=utf-8"
        if (headers["content-disposition"] ?? "").lowercased().hasPrefix("attachment") { return ([], []) }
        if type.lowercased().hasPrefix("multipart/"), let boundary = parameter("boundary", in: type), !boundary.isEmpty {
            var chunks: [String] = [], current: [String]? = nil
            for line in body.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "--" + boundary || trimmed == "--" + boundary + "--" {
                    if let current { chunks.append(current.joined(separator: "\n")) }
                    current = trimmed.hasSuffix("--") ? nil : []
                    if chunks.count >= 64 || trimmed == "--" + boundary + "--" { break }
                } else { current?.append(line) }
            }
            if let current, !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
            let parsed = chunks.prefix(64).map { split($0) }
            let contents = parsed.map { parts(headers: $0.0, body: $0.1, depth: depth + 1) }
            let links = Array(contents.flatMap(\.links).prefix(256))
            if type.lowercased().hasPrefix("multipart/alternative"), let index = parsed.firstIndex(where: { ($0.0["content-type"] ?? "text/plain").lowercased().hasPrefix("text/plain") }) {
                let result = contents[index].text
                if result.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return (result, links) }
            }
            return (contents.flatMap(\.text), links)
        }
        guard type.lowercased().hasPrefix("text/plain") || type.lowercased().hasPrefix("text/html") else { return ([], []) }
        let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
        let bytes: Data
        if encoding == "base64" { bytes = Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? Data() }
        else if encoding == "quoted-printable" { bytes = decodeQuotedPrintable(body) }
        else { bytes = body.data(using: .isoLatin1) ?? Data(body.utf8) }
        let text = decode(bytes, charset: parameter("charset", in: type) ?? "utf-8")
        let html = type.lowercased().hasPrefix("text/html")
        let visible = html ? stripHTML(text) : text
        // Anchor text can look like a different URL; only its href is a destination.
        let withoutAnchors = html ? stripHTML(text.replacingOccurrences(of: #"(?is)<a\b[^>]*>.*?</a\s*>"#, with: " ", options: .regularExpression)) : text
        return ([visible], html ? htmlLinks(text) + plainLinks(withoutAnchors) : plainLinks(text))
    }

    public static func decodeHeader(_ value: String) -> String {
        let joined = value.replacingOccurrences(of: "(?<=\\?=)\\s+(?==\\?)", with: "", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?=") else { return value }
        var result = joined
        for match in regex.matches(in: joined, range: NSRange(joined.startIndex..., in: joined)).reversed() {
            guard let full = Range(match.range, in: result), let c = Range(match.range(at: 1), in: joined), let e = Range(match.range(at: 2), in: joined), let b = Range(match.range(at: 3), in: joined) else { continue }
            let encoded = String(joined[b])
            let data = joined[e].lowercased() == "b" ? Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) ?? Data() : decodeQuotedPrintable(encoded.replacingOccurrences(of: "_", with: " "))
            result.replaceSubrange(full, with: decode(data, charset: String(joined[c])))
        }
        // Raw UTF-8 headers are also used by modern servers.
        if !joined.contains("=?"), let bytes = result.data(using: .isoLatin1), let utf8 = String(data: bytes, encoding: .utf8) { return utf8 }
        return result
    }

    private static func decode(_ data: Data, charset: String) -> String {
        let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        if cf != kCFStringEncodingInvalidId {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func decodeQuotedPrintable(_ text: String) -> Data {
        let bytes = Array((text.data(using: .isoLatin1) ?? Data(text.utf8)))
        var result = Data(), i = 0
        while i < bytes.count {
            if bytes[i] == 61 {
                if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
                if i + 2 < bytes.count, let hex = String(bytes: bytes[(i+1)...(i+2)], encoding: .ascii), let value = UInt8(hex, radix: 16) { result.append(value); i += 3; continue }
            }
            result.append(bytes[i]); i += 1
        }
        return result
    }

    private static func cleanHTML(_ text: String) -> String {
        var result = text
        for pattern in ["(?is)<(script|style|head)\\b[^>]*>.*?</\\1\\s*>", "(?is)<!--.*?-->", "(?is)<blockquote\\b[^>]*>.*?</blockquote>"] {
            result = result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return result
    }
    private static func plainLinks(_ source: String) -> [MailLink] {
        let text = String(source.prefix(100_000)).components(separatedBy: "\n")
            .prefix(while: { !$0.hasPrefix("On ") || !$0.hasSuffix("wrote:") }).filter { !$0.hasPrefix(">") }.joined(separator: "\n")
        guard let regex = try? NSRegularExpression(pattern: #"(?i)https?://[^\s<>"']+"#) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(256).map { match in
            let raw = ns.substring(with: match.range)
            let url = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?)]}。，；！）】"))
            let start = max(0, match.range.location - 180), end = min(ns.length, NSMaxRange(match.range) + 80)
            return MailLink(url: url, label: "", context: ns.substring(with: NSRange(location: start, length: end - start)))
        }
    }
    private static func htmlLinks(_ source: String) -> [MailLink] {
        let text = cleanHTML(String(source.prefix(262_144)))
        guard let anchors = try? NSRegularExpression(pattern: #"(?is)<a\b([^>]*)>(.*?)</a\s*>"#),
              let href = try? NSRegularExpression(pattern: #"(?is)(?:^|\s)href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else { return [] }
        let ns = text as NSString
        return anchors.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(256).compactMap { anchor in
            let attributes = ns.substring(with: anchor.range(at: 1))
            guard let match = href.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)),
                  let range = (1...3).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { return nil }
            let url = decodeEntities((attributes as NSString).substring(with: range)).trimmingCharacters(in: .whitespacesAndNewlines)
            let start = max(0, anchor.range.location - 300), end = min(ns.length, NSMaxRange(anchor.range) + 100)
            return MailLink(url: url, label: stripHTML(ns.substring(with: anchor.range(at: 2))),
                            context: stripHTML(ns.substring(with: NSRange(location: start, length: end - start))))
        }
    }
    public static func stripHTML(_ text: String) -> String {
        var result = cleanHTML(text)
        result = result.replacingOccurrences(of: "(?is)<(?:br|/p|/div|/tr|/h[1-6])\\b[^>]*>", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
        return decodeEntities(result)
    }
    private static func decodeEntities(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let r = Range(match.range, in: result), let n = Range(match.range(at: 1), in: result) else { continue }
                let number = String(result[n]); let radix = number.hasPrefix("x") ? 16 : 10
                if let value = UInt32(radix == 16 ? String(number.dropFirst()) : number, radix: radix), let scalar = UnicodeScalar(value) { result.replaceSubrange(r, with: String(scalar)) }
            }
        }
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] { result = result.replacingOccurrences(of: entity, with: value) }
        return result
    }
}
