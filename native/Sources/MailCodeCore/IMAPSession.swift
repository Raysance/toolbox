import Foundation

private actor IdleFinisher {
    let transport: IMAPTransport
    var sent = false
    init(_ transport: IMAPTransport) { self.transport = transport }
    func finish() async throws {
        guard !sent else { return }; sent = true
        try await transport.send(Data("DONE\r\n".utf8))
    }
}

public actor IMAPSession {
    private let wire: IMAPWire
    private var counter = 0
    private var messageCount = 0
    public private(set) var supportsIdle = false
    public init(transport: IMAPTransport) { wire = IMAPWire(transport: transport) }
    public func close() { wire.transport.close() }

    public func open(account: MailAccount, password: String, timeout: TimeInterval = 60) async throws -> MailboxCheckpoint {
        try account.validate(password: password)
        let transport = wire.transport
        return try await withThrowingTaskGroup(of: MailboxCheckpoint.self) { group in
            group.addTask { try await self.authenticate(account: account, password: password) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                throw MailError.timeout
            }
            defer { group.cancelAll() }
            do { return try await group.next()! }
            catch { transport.close(); throw error }
        }
    }

    private func authenticate(account: MailAccount, password: String) async throws -> MailboxCheckpoint {
        try await wire.transport.connect()
        let greeting = try await wire.frame()
        guard greeting.line.uppercased().hasPrefix("* OK ") || greeting.line.uppercased().hasPrefix("* PREAUTH ") else { throw MailError.malformedResponse }
        var capabilities = try await capability()
        if !greeting.line.uppercased().hasPrefix("* PREAUTH ") {
            do {
                if capabilities.contains("AUTH=PLAIN") {
                    let tag = nextTag()
                    try await wire.send("\(tag) AUTHENTICATE PLAIN")
                    var prompt = try await wire.frame()
                    var remaining = 100
                    while prompt.line.hasPrefix("* "), remaining > 0 { prompt = try await wire.frame(); remaining -= 1 }
                    guard prompt.line.hasPrefix("+") else { throw MailError.authenticationFailed }
                    let payload = Data(("\0" + account.username + "\0" + password).utf8).base64EncodedString()
                    try await wire.send(payload)
                    _ = try await finish(tag: tag, operation: "sign-in")
                } else {
                    _ = try await command("LOGIN \(Self.quote(account.username)) \(Self.quote(password))", operation: "sign-in")
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as MailError where error == .timeout || error == .disconnected { throw error }
            catch { throw MailError.authenticationFailed }
            capabilities = try await capability()
        }
        supportsIdle = capabilities.contains("IDLE")
        if capabilities.contains("ID") { _ = try? await command("ID (\"name\" \"MailCode\" \"version\" \"0.1.0\")", operation: "client identification") }
        let responses = try await command("EXAMINE \(Self.quote(Self.mailboxName(account.folder)))", operation: "opening the mailbox read-only")
        let text = responses.map(\.line).joined(separator: "\n")
        if let expression = try? NSRegularExpression(pattern: "(?im)^\\* ([0-9]+) EXISTS"),
           let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) { messageCount = Int(text[range]) ?? 0 }
        guard let validity = Self.number("UIDVALIDITY", in: text), validity > 0,
              let next = Self.number("UIDNEXT", in: text), next > 0 else { throw MailError.missingMailboxMetadata }
        return MailboxCheckpoint(validity: validity, lastUID: next - 1)
    }

    /// Bounded recent-mail lookup for Raycast, separate from the new-mail watcher.
    public func recentUIDs(limit: Int = 30) async throws -> [UInt64] {
        guard messageCount > 0 else { return [] }
        let first = max(1, messageCount - min(max(1, limit), 50) + 1)
        let responses = try await command("FETCH \(first):* (UID)", operation: "listing recent messages")
        return Array(Set(responses.filter { $0.line.uppercased().contains(" FETCH ") }.compactMap { Self.number("UID", in: $0.line) })).sorted(by: >)
    }

    public func newUIDs(after uid: UInt64) async throws -> [UInt64] {
        guard uid < UInt64.max else { return [] }
        let responses = try await command("UID SEARCH UID \(uid + 1):*", operation: "checking for new messages")
        return Array(Set(responses.filter { $0.line.uppercased().hasPrefix("* SEARCH") }.flatMap { $0.line.split(separator: " ").dropFirst(2).compactMap { UInt64($0) } }.filter { $0 > uid })).sorted()
    }

    public func fetch(uid: UInt64) async throws -> (Data, Date?)? {
        let responses = try await command("UID FETCH \(uid) (UID INTERNALDATE BODY.PEEK[]<0.262144>)", operation: "reading a message")
        for response in responses {
            guard Self.number("UID", in: response.line) == uid, let data = response.literals.first else { continue }
            let regex = try NSRegularExpression(pattern: "(?i)INTERNALDATE \\\"([^\\\"]+)\\\"")
            var date: Date?
            if let match = regex.firstMatch(in: response.line, range: NSRange(response.line.startIndex..., in: response.line)), let range = Range(match.range(at: 1), in: response.line) {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
                date = formatter.date(from: String(response.line[range]).trimmingCharacters(in: .whitespaces))
            }
            return (data, date)
        }
        return nil // Message may have been expunged between SEARCH and FETCH.
    }

    public func waitForChange(idleSeconds: TimeInterval = 25 * 60) async throws {
        guard supportsIdle else {
            try await Task.sleep(nanoseconds: 20_000_000_000)
            _ = try await command("NOOP", operation: "keepalive"); return
        }
        let tag = nextTag()
        try await wire.send("\(tag) IDLE")
        var prompt = try await wire.frame()
        var changedBeforePrompt = false
        var remaining = 100
        while prompt.line.hasPrefix("* "), remaining > 0 {
            changedBeforePrompt = changedBeforePrompt || Self.isChange(prompt.line)
            prompt = try await wire.frame(); remaining -= 1
        }
        guard prompt.line.hasPrefix("+") else {
            if prompt.line.hasPrefix(tag + " NO") || prompt.line.hasPrefix(tag + " BAD") { supportsIdle = false; return }
            throw MailError.malformedResponse
        }
        let finisher = IdleFinisher(wire.transport)
        let transport = wire.transport
        let renewal = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(idleSeconds * 1_000_000_000))
                try await finisher.finish()
                try await Task.sleep(nanoseconds: 30_000_000_000)
                transport.close() // A server that ignores DONE must not hang forever.
            } catch is CancellationError { } catch { transport.close() }
        }
        defer { renewal.cancel() }
        if changedBeforePrompt { try await finisher.finish() }
        while true {
            let response = try await wire.frame(timeout: idleSeconds + 40)
            if response.line.hasPrefix(tag + " ") {
                guard response.line.uppercased().hasPrefix(tag + " OK") else { throw MailError.commandRejected("IDLE monitoring") }
                return
            }
            if response.line.uppercased().hasPrefix("* BYE") { throw MailError.disconnected }
            if Self.isChange(response.line) { try await finisher.finish() }
        }
    }

    private static func isChange(_ line: String) -> Bool { line.uppercased().range(of: "^\\* [0-9]+ (EXISTS|EXPUNGE)", options: .regularExpression) != nil }
    private func capability() async throws -> Set<String> {
        Set(try await command("CAPABILITY", operation: "capability discovery").filter { $0.line.uppercased().hasPrefix("* CAPABILITY ") }.flatMap { $0.line.uppercased().split(separator: " ").dropFirst(2).map(String.init) })
    }
    private func nextTag() -> String { counter += 1; return "M\(counter)" }
    private func command(_ value: String, operation: String) async throws -> [IMAPFrame] {
        let tag = nextTag()
        try await wire.send("\(tag) \(value)")
        return try await finish(tag: tag, operation: operation)
    }
    private func finish(tag: String, operation: String) async throws -> [IMAPFrame] {
        var responses: [IMAPFrame] = [], bytes = 0
        for _ in 0..<2000 {
            let response = try await wire.frame()
            bytes += response.line.utf8.count + response.literals.reduce(0) { $0 + $1.count }
            guard bytes < 2_097_152 else { throw MailError.responseTooLarge }
            if response.line.uppercased().hasPrefix("* BYE") { throw MailError.disconnected }
            responses.append(response)
            if response.line.hasPrefix(tag + " ") {
                guard response.line.uppercased().hasPrefix(tag + " OK") else { throw MailError.commandRejected(operation) }
                return responses
            }
        }
        throw MailError.responseTooLarge
    }
    public static func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    private static func number(_ label: String, in text: String) -> UInt64? {
        guard let regex = try? NSRegularExpression(pattern: "(?i)\\b" + label + " ([0-9]+)"), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
        return UInt64(text[range])
    }
    public static func mailboxName(_ name: String) -> String {
        var result = "", buffer = ""
        func flush() {
            if !buffer.isEmpty {
                let bytes = buffer.data(using: .utf16BigEndian)!
                result += "&" + bytes.base64EncodedString().replacingOccurrences(of: "/", with: ",").replacingOccurrences(of: "=", with: "") + "-"
                buffer = ""
            }
        }
        for scalar in name.unicodeScalars {
            if (0x20...0x7e).contains(scalar.value) { flush(); result += scalar == "&" ? "&-" : String(scalar) }
            else { buffer.unicodeScalars.append(scalar) }
        }
        flush(); return result
    }
}
