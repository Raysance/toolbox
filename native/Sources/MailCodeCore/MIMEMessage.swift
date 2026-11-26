import Foundation
import CoreFoundation

public struct MIMEMessage: Sendable {
    public let subject: String
    public let sender: String
    public let text: String

    public init(data: Data) {
        let raw = String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        let (headers, body) = Self.split(raw)
        subject = Self.decodeHeader(headers["subject"] ?? "")
        sender = Self.decodeHeader(headers["from"] ?? "未知发件人")
        text = Self.parts(headers: headers, body: body, depth: 0).joined(separator: "\n")
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

    private static func parts(headers: [String: String], body: String, depth: Int) -> [String] {
        guard depth < 8 else { return [] }
        let type = headers["content-type"] ?? "text/plain; charset=utf-8"
        if (headers["content-disposition"] ?? "").lowercased().hasPrefix("attachment") { return [] }
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
            if type.lowercased().hasPrefix("multipart/alternative"), let plain = parsed.first(where: { ($0.0["content-type"] ?? "text/plain").lowercased().hasPrefix("text/plain") }) {
                let result = parts(headers: plain.0, body: plain.1, depth: depth + 1)
                if result.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return result }
            }
            return parsed.flatMap { parts(headers: $0.0, body: $0.1, depth: depth + 1) }
        }
        guard type.lowercased().hasPrefix("text/plain") || type.lowercased().hasPrefix("text/html") else { return [] }
        let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
        let bytes: Data
        if encoding == "base64" { bytes = Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? Data() }
        else if encoding == "quoted-printable" { bytes = decodeQuotedPrintable(body) }
        else { bytes = body.data(using: .isoLatin1) ?? Data(body.utf8) }
        let text = decode(bytes, charset: parameter("charset", in: type) ?? "utf-8")
        return [type.lowercased().hasPrefix("text/html") ? stripHTML(text) : text]
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

    public static func stripHTML(_ text: String) -> String {
        var result = text
        for pattern in ["(?is)<(script|style|head)\\b[^>]*>.*?</\\1\\s*>", "(?is)<!--.*?-->", "(?is)<blockquote\\b[^>]*>.*?</blockquote>"] {
            result = result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        result = result.replacingOccurrences(of: "(?is)<(?:br|/p|/div|/tr|/h[1-6])\\b[^>]*>", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
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
