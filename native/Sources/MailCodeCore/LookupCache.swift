import Foundation

public enum LookupPhase: String, Codable, Sendable { case idle, queued, connecting, checking, searching }

public struct LookupCacheEntry: Codable, Equatable, Sendable {
    public var account: MailAccount
    public var validity: UInt64
    public var checkedThrough: UInt64 = 0
    public var initialized = false
    public var processedUIDs: [UInt64] = []
    public var latestUID: UInt64 = 0
    public var latest: LatestCode?
    public var checkedAt: TimeInterval = 0
    public var extractorVersion: Int? = VerificationExtractor.version
    public init(account: MailAccount, validity: UInt64) { self.account = account; self.validity = validity }
    public mutating func upgradeExtractor() {
        guard extractorVersion != VerificationExtractor.version else { return }
        // Old negative results cannot identify links: recheck the bounded recent window once.
        // Keep the existing displayed result while the new parser fills the cache.
        initialized = false; checkedThrough = 0; processedUIDs = []
        extractorVersion = VerificationExtractor.version
    }
    public func matches(_ other: MailAccount) -> Bool {
        account.id == other.id && account.host == other.host && account.port == other.port && account.username == other.username && account.folder == other.folder
    }
    public mutating func expire(now: Date = Date()) {
        if let latest, now.timeIntervalSince1970 - latest.receivedAt > 86_400 { self.latest = nil }
    }
    public mutating func record(uid: UInt64, code: LatestCode?) {
        processedUIDs = Array(Set(processedUIDs + [uid]).sorted(by: >).prefix(200))
        if let code, uid >= latestUID { latestUID = uid; latest = code }
        expire()
    }
    public func merging(_ other: Self) -> Self {
        guard matches(other.account), validity == other.validity, extractorVersion == other.extractorVersion else { return self }
        var merged = self
        merged.processedUIDs = Array(Set(processedUIDs + other.processedUIDs).sorted(by: >).prefix(200))
        merged.checkedThrough = max(checkedThrough, other.checkedThrough)
        merged.initialized = initialized || other.initialized
        merged.checkedAt = max(checkedAt, other.checkedAt)
        if other.latestUID > latestUID { merged.latestUID = other.latestUID; merged.latest = other.latest }
        else if other.latestUID == latestUID, merged.latest == nil { merged.latest = other.latest }
        merged.expire()
        return merged
    }
}

public struct LookupCacheStore {
    public let file: URL
    public init(directory: URL) { file = directory.appendingPathComponent("code-cache.json") }
    public func load(accounts: [MailAccount], now: Date = Date()) throws -> [UUID: LookupCacheEntry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data = try Data(contentsOf: file)
        guard data.count <= 4_194_304 else { throw MailError.responseTooLarge }
        let stored = try JSONDecoder().decode([UUID: LookupCacheEntry].self, from: data)
        var entries: [UUID: LookupCacheEntry] = [:]
        for account in accounts {
            if var entry = stored[account.id], entry.matches(account) {
                entry.upgradeExtractor(); entry.expire(now: now); entries[account.id] = entry
            }
        }
        return entries
    }
    public func save(_ entries: [UUID: LookupCacheEntry]) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(entries)
        // The temporary file is private before any code is written into it.
        let temporary = directory.appendingPathComponent(".code-cache-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        if FileManager.default.fileExists(atPath: file.path) { _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

public struct LookupResult: Sendable {
    public let accountID: UUID
    public let entry: LookupCacheEntry?
    public let error: String?
    public let fetchedMessages: Int
}

public enum MailLookup {
    public static func latest(account: MailAccount, password: String, transport: any IMAPTransport,
                              cached: LookupCacheEntry?,
                              current: @escaping @Sendable () async -> LookupCacheEntry? = { nil },
                              progress: @escaping @Sendable (LookupCacheEntry?, LookupPhase) async -> Void = { _, _ in }) async -> LookupResult {
        let session = IMAPSession(transport: transport)
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: 45_000_000_000); transport.close() } catch { }
        }
        defer { deadline.cancel(); transport.close() }
        var entry: LookupCacheEntry?, fetched = 0
        do {
            await progress(nil, .connecting)
            let baseline = try await session.open(account: account, password: password)
            var state = cached.flatMap { $0.matches(account) && $0.validity == baseline.validity ? $0 : nil }
                ?? LookupCacheEntry(account: account, validity: baseline.validity)
            state.upgradeExtractor()
            if let current = await current() { state = state.merging(current) }
            entry = state
            await progress(state, .checking)
            if !state.initialized || state.checkedThrough < baseline.lastUID {
                let uids = state.initialized
                    ? Array(try await session.newUIDs(after: state.checkedThrough).suffix(100)).sorted(by: >)
                    : try await session.recentUIDs()
                let upper = max(baseline.lastUID, uids.max() ?? 0)
                for uid in uids {
                    try Task.checkCancellation()
                    if let current = await current() {
                        guard current.validity == baseline.validity else { throw MailError.missingMailboxMetadata }
                        state = state.merging(current)
                    }
                    if uid <= state.latestUID { break }
                    if state.processedUIDs.contains(uid) { continue }
                    await progress(state, .searching)
                    let message = try await session.fetch(uid: uid)
                    fetched += 1
                    try Task.checkCancellation()
                    if let current = await current() {
                        guard current.validity == baseline.validity else { throw MailError.missingMailboxMetadata }
                        state = state.merging(current)
                    }
                    var latest: LatestCode?
                    if let (data, date) = message, let date {
                        let mail = MIMEMessage(data: data)
                        if let payload = VerificationExtractor.extract(mail) {
                            latest = LatestCode(account: account, uid: uid, mail: mail, code: payload.value, date: date, kind: payload.kind)
                        }
                    }
                    state.record(uid: uid, code: latest)
                    entry = state
                    await progress(state, .searching)
                    if latest != nil { break }
                }
                state.checkedThrough = max(state.checkedThrough, upper)
            }
            state.initialized = true; state.checkedAt = Date().timeIntervalSince1970; state.expire()
            entry = state
            await progress(state, .idle)
            return LookupResult(accountID: account.id, entry: state, error: nil, fetchedMessages: fetched)
        } catch {
            return LookupResult(accountID: account.id, entry: entry, error: error.localizedDescription, fetchedMessages: fetched)
        }
    }
}
