import AppKit
import SwiftUI
import ServiceManagement
import MailCodeCore

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var config = Configuration()
    @Published var statuses: [UUID: String] = [:]
    @Published var online: Set<UUID> = []
    @Published var history: [CodeEvent] = []
    @Published var latestCodes: [UUID: LatestCode] = [:]
    @Published var lookupErrors: [UUID: String] = [:]
    @Published var lookupPhases: [UUID: LookupPhase] = [:]
    var lookupCache: [UUID: LookupCacheEntry] = [:]
    var lookupFetched: [UUID: Int] = [:]
    private var mailboxHeads: [UUID: MailboxCheckpoint] = [:]
    private var cacheStore: LookupCacheStore { LookupCacheStore(directory: store.directory) }
    @Published var paused = false
    @Published var locked = false
    @Published var errorMessage: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    var onCode: ((CodeEvent, Bool) -> Void)?
    var onHidePopup: (() -> Void)?
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var purgeTask: Task<Void, Never>?
    private var clipboardTask: Task<Void, Never>?
    private let store: ConfigurationStore
    private var persistenceReady = true
    private let pasteboard: NSPasteboard
    private var copiedChangeCount: Int?
    private var seen: [String: Date] = [:]
    private var sleeping = false
    private var lookupTask: Task<Void, Never>?
    let preview: Bool

    init(preview: Bool = false, pasteboard: NSPasteboard = .general) {
        self.preview = preview; self.pasteboard = pasteboard; store = ConfigurationStore()
        if preview {
            let account = MailAccount(name: "Personal", username: "hello@example.com", host: "imap.example.com")
            config.accounts = [account]; statuses[account.id] = "Listening"; online.insert(account.id)
            history = [CodeEvent(code: "482916", sender: "Example <no-reply@example.com>", account: account.username)]
        } else {
            do { config = try store.load() }
            catch { persistenceReady = false; errorMessage = "Could not load settings. The original file was preserved. Check ~/Library/Application Support/MailCode/settings.json." }
            loadCache()
            purgeTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                    self?.purgeExpired()
                }
            }
        }
    }
    var accounts: [MailAccount] { config.accounts }
    var preferences: Preferences { config.preferences }
    var networkSettings: IMAPNetworkSettings { config.network ?? .init() }
    func setNetwork(_ settings: IMAPNetworkSettings) async throws {
        try settings.validate()
        guard settings != networkSettings else { return }
        guard persistenceReady else { throw MailError.commandRejected("saving network settings") }
        var next = config; next.network = settings
        try store.save(next)
        config = next
        // Complete the cancelled lookup before starting workers with the new route.
        let pending = lookupTask
        pending?.cancel()
        stop()
        await pending?.value
        start()
    }
    var summary: String {
        if locked || sleeping { return "Paused until unlock or wake" }
        if paused { return "Monitoring Paused" }
        if accounts.isEmpty { return "Connect an account to receive codes" }
        let enabled = accounts.filter(\.enabled).count
        if enabled == 0 { return "All Accounts Disabled" }
        return online.isEmpty ? "Connecting Accounts…" : "Listening to \(online.count) accounts"
    }
    func start() {
        guard !preview, !paused, !locked, !sleeping else { return }
        for account in accounts where account.enabled && workers[account.id] == nil {
            workers[account.id] = Task { [weak self] in await self?.monitor(account) }
        }
    }
    func stop() {
        workers.values.forEach { $0.cancel() }; workers.removeAll(); online.removeAll()
    }
    func restart() { stop(); start() }
    func togglePause() { paused.toggle(); paused ? stop() : start() }
    func setLocked(_ value: Bool) {
        locked = value
        if value { stop(); lookupTask?.cancel(); onHidePopup?(); clearOwnedClipboard(); history.removeAll(); latestCodes.removeAll(); lookupCache.removeAll() } else { loadCache(); start() }
    }
    func setSleeping(_ value: Bool) { sleeping = value; value ? stop() : start() }
    func updatePreferences(_ update: (inout Preferences) -> Void) {
        var next = config; update(&next.preferences)
        guard persist(next) else { return }; config = next
        if !next.preferences.showPopup { onHidePopup?() }
        if !next.preferences.clearClipboard { clipboardTask?.cancel() }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && !launchAtLogin { errorMessage = "Allow InboxCode in System Settings → General → Login Items." }
        } catch { errorMessage = "Could not set launch at login. Move the app to Applications and try again." }
    }
    func saveAccount(_ account: MailAccount, password: String) throws {
        guard persistenceReady else { throw MailError.commandRejected("saving settings") }
        try account.validate(password: password)
        let oldAccount = accounts.first { $0.id == account.id }
        var next = config
        if let index = next.accounts.firstIndex(where: { $0.id == account.id }) { next.accounts[index] = account }
        else { next.accounts.append(account) }
        if let oldAccount, oldAccount.host != account.host || oldAccount.username != account.username || oldAccount.folder != account.folder || oldAccount.port != account.port { next.checkpoints.removeValue(forKey: account.id.uuidString) }
        try store.save(next)
        do { try Keychain.save(password, id: account.id) }
        catch {
            try? store.save(config)
            throw error
        }
        if let cached = lookupCache[account.id], !cached.matches(account) { removeCache(account.id) }
        if oldAccount != account { lookupErrors.removeValue(forKey: account.id) }
        config = next; restart()
    }
    func removeAccount(_ id: UUID) {
        var next = config; next.accounts.removeAll { $0.id == id }; next.checkpoints.removeValue(forKey: id.uuidString)
        guard persist(next) else { return }
        do { try Keychain.delete(id) }
        catch { _ = persist(config); errorMessage = error.localizedDescription; return }
        config = next; statuses.removeValue(forKey: id); restart()
        removeCache(id); lookupErrors.removeValue(forKey: id)
    }
    func enableAccount(_ id: UUID, enabled: Bool) {
        var next = config
        guard let index = next.accounts.firstIndex(where: { $0.id == id }) else { return }
        next.accounts[index].enabled = enabled
        guard persist(next) else { return }; config = next; restart()
    }
    func test(account: MailAccount, password: String) async throws {
        try account.validate(password: password)
        let session = IMAPSession(transport: TLSIMAPTransport(host: account.host, port: account.port, network: networkSettings))
        do { _ = try await session.open(account: account, password: password); await session.close() }
        catch { await session.close(); throw error }
    }
    func refreshLatest(force: Bool = false) async {
        guard !locked else { return }
        if let lookupTask { await lookupTask.value; return }
        purgeExpired()
        let activeAccounts = accounts.filter { account in
            guard account.enabled else { return false }
            if !force, lookupErrors[account.id] == nil, online.contains(account.id),
               let entry = lookupCache[account.id], entry.initialized,
               let head = mailboxHeads[account.id], entry.validity == head.validity,
               entry.checkedThrough >= head.lastUID {
                lookupPhases[account.id] = .idle; lookupFetched[account.id] = 0
                return false
            }
            return true
        }
        guard !activeAccounts.isEmpty else { return }
        for account in activeAccounts { lookupPhases[account.id] = .queued }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { for account in activeAccounts { self.lookupPhases[account.id] = .idle } }
            for start in stride(from: 0, to: activeAccounts.count, by: 3) {
                if Task.isCancelled { return }
                var credentials: [(MailAccount, String)] = []
                for account in activeAccounts[start..<min(start + 3, activeAccounts.count)] {
                    do { credentials.append((account, try Keychain.read(account.id))) }
                    catch { self.lookupErrors[account.id] = error.localizedDescription; self.lookupPhases[account.id] = .idle }
                }
                await withTaskGroup(of: LookupResult.self) { group in
                    let network = self.networkSettings
                    for (account, password) in credentials {
                        let cached = self.lookupCache[account.id]
                        group.addTask {
                            await MailLookup.latest(account: account, password: password,
                                transport: TLSIMAPTransport(host: account.host, port: account.port, network: network), cached: cached,
                                current: { await self.cachedEntry(for: account) },
                                progress: { entry, phase in await self.lookupProgress(entry, phase: phase, account: account) })
                        }
                    }
                    for await result in group {
                        guard !Task.isCancelled, !self.locked,
                              self.accounts.first(where: { $0.id == result.accountID }) == activeAccounts.first(where: { $0.id == result.accountID }) else { continue }
                        self.lookupErrors[result.accountID] = result.error
                        self.lookupPhases[result.accountID] = .idle
                        self.lookupFetched[result.accountID] = result.fetchedMessages
                    }
                }
            }
        }
        lookupTask = task; await task.value; lookupTask = nil
    }
    private func cachedEntry(for account: MailAccount) -> LookupCacheEntry? {
        guard !locked, accounts.contains(account) else { return nil }
        return lookupCache[account.id]
    }
    private func lookupProgress(_ entry: LookupCacheEntry?, phase: LookupPhase, account: MailAccount) {
        guard !Task.isCancelled, !locked, accounts.contains(account) else { return }
        lookupPhases[account.id] = phase
        if let entry { updateCache(entry) }
    }
    private func loadCache() {
        do {
            lookupCache = try cacheStore.load(accounts: accounts)
            latestCodes = lookupCache.compactMapValues(\.latest)
            if !lookupCache.isEmpty { saveCache() }
        } catch {
            lookupCache = [:]
            errorMessage = "Could not load the local code cache. It will be rebuilt from your mailbox."
        }
    }
    private func saveCache() {
        guard !preview else { return }
        do { try cacheStore.save(lookupCache) }
        catch { errorMessage = "Could not save the local code cache. Check disk space and folder permissions." }
    }
    private func updateCache(_ incoming: LookupCacheEntry) {
        var entry = incoming
        if let existing = lookupCache[entry.account.id] { entry = entry.merging(existing) }
        entry.expire()
        lookupCache[entry.account.id] = entry
        latestCodes[entry.account.id] = entry.latest
        saveCache()
    }
    private func removeCache(_ id: UUID) {
        lookupCache.removeValue(forKey: id); latestCodes.removeValue(forKey: id)
        mailboxHeads.removeValue(forKey: id); lookupPhases.removeValue(forKey: id)
        saveCache()
    }
    @discardableResult func copy(_ event: CodeEvent) -> Bool {
        guard !locked, Date().timeIntervalSince(event.received) <= 600 else { return false }
        clipboardTask?.cancel()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(event.code, forType: .string)
        // Best-effort hints used by clipboard history tools to avoid retaining secrets.
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        let success = pasteboard.writeObjects([item])
        copiedChangeCount = success ? pasteboard.changeCount : nil
        if success && preferences.clearClipboard {
            clipboardTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
                self?.clearOwnedClipboard()
            }
        }
        return success
    }
    func clearOwnedClipboard() {
        if let copiedChangeCount, pasteboard.changeCount == copiedChangeCount { pasteboard.clearContents() }
        copiedChangeCount = nil
    }
    func demo(link: Bool = false) {
        let source = link ? "Subject: Reset your password\r\n\r\nUse this link to choose a new password: https://auth.example.invalid/reset-password/demo-test-token?source=email&token=abc%2Bdef"
            : "Subject: InboxCode verification code\r\nFrom: InboxCode Demo\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nYour verification code is 482916. It expires in 10 minutes."
        guard let payload = VerificationExtractor.extract(MIMEMessage(data: Data(source.utf8))) else { return }
        deliver(CodeEvent(code: payload.value, sender: "InboxCode Demo", account: "Local Test", kind: payload.kind))
    }
    private func deliver(_ event: CodeEvent) {
        guard !locked, !sleeping else { return }
        purgeExpired()
        history.insert(event, at: 0); history = Array(history.prefix(8))
        let copied = !event.isLink && preferences.autoCopy && copy(event)
        if preferences.showPopup { onCode?(event, copied) }
    }
    private func persist(_ next: Configuration) -> Bool {
        guard persistenceReady else { return false }
        do { try store.save(next); return true }
        catch { errorMessage = "Could not save settings. Check disk space and folder permissions."; return false }
    }
    private func checkpoint(_ value: MailboxCheckpoint, account: MailAccount) {
        config.checkpoints[account.id.uuidString] = value
        _ = persist(config)
    }
    private func purgeExpired() {
        let now = Date()
        history.removeAll { now.timeIntervalSince($0.received) > 600 }
        seen = seen.filter { now.timeIntervalSince($0.value) < 600 }
        var changed = false
        for (id, var entry) in lookupCache {
            let old = entry.latest; entry.expire(now: now)
            if entry.latest != old { lookupCache[id] = entry; latestCodes[id] = entry.latest; changed = true }
        }
        if changed { saveCache() }
    }
    private func monitor(_ account: MailAccount) async {
        let password: String
        do { password = try Keychain.read(account.id) }
        catch { statuses[account.id] = error.localizedDescription; lookupErrors[account.id] = error.localizedDescription; return }
        var retry: UInt64 = 5
        while !Task.isCancelled {
            statuses[account.id] = "Connecting Securely…"
            let session = IMAPSession(transport: TLSIMAPTransport(host: account.host, port: account.port, network: networkSettings))
            do {
                let baseline = try await session.open(account: account, password: password)
                try Task.checkCancellation()
                if let cached = lookupCache[account.id], cached.validity != baseline.validity {
                    lookupTask?.cancel(); removeCache(account.id)
                }
                mailboxHeads[account.id] = baseline
                var cursor = MailboxCheckpoint.resume(stored: config.checkpoints[account.id.uuidString], baseline: baseline)
                checkpoint(cursor, account: account)
                online.insert(account.id); retry = 5
                statuses[account.id] = await session.supportsIdle ? "Listening" : "Checking Every 20 Seconds"
                while !Task.isCancelled {
                    let uids = try await session.newUIDs(after: cursor.lastUID)
                    try Task.checkCancellation()
                    if let current = lookupCache[account.id], current.validity != baseline.validity { throw MailError.missingMailboxMetadata }
                    if let last = uids.last { mailboxHeads[account.id] = MailboxCheckpoint(validity: baseline.validity, lastUID: max(baseline.lastUID, last)) }
                    for uid in uids.suffix(100) {
                        let cached = lookupCache[account.id]
                        var latest: LatestCode?
                        if cached?.validity == baseline.validity, cached?.processedUIDs.contains(uid) == true {
                            if cached?.latestUID == uid { latest = cached?.latest }
                        } else {
                            let fetched = try await session.fetch(uid: uid)
                            try Task.checkCancellation()
                            if let current = lookupCache[account.id], current.validity != baseline.validity { throw MailError.missingMailboxMetadata }
                            if let (data, date) = fetched, let date {
                                let mail = MIMEMessage(data: data)
                                if let payload = VerificationExtractor.extract(mail) {
                                    latest = LatestCode(account: account, uid: uid, mail: mail, code: payload.value, date: date, kind: payload.kind)
                                }
                            }
                        }
                        var entry = lookupCache[account.id].flatMap { $0.validity == baseline.validity ? $0 : nil }
                            ?? LookupCacheEntry(account: account, validity: baseline.validity)
                        entry.record(uid: uid, code: latest)
                        if latest != nil { entry.initialized = true; entry.checkedThrough = max(entry.checkedThrough, uid) }
                        else if entry.initialized, entry.checkedThrough >= cursor.lastUID { entry.checkedThrough = max(entry.checkedThrough, uid) }
                        updateCache(entry)
                        if let latest, Freshness.accepts(Date(timeIntervalSince1970: latest.receivedAt)) {
                            purgeExpired()
                            let identity = account.id.uuidString + "|" + latest.sender + "|" + latest.code
                            if seen[identity] == nil {
                                seen[identity] = Date()
                                deliver(CodeEvent(code: latest.code, sender: latest.sender, account: account.username,
                                    received: Date(timeIntervalSince1970: latest.receivedAt), provider: latest.provider, kind: latest.kind ?? .code))
                            }
                        }
                        cursor.lastUID = uid; checkpoint(cursor, account: account)
                    }
                    try await session.waitForChange()
                    statuses[account.id] = await session.supportsIdle ? "Listening" : "Checking Every 20 Seconds"
                }
                await session.close()
            } catch {
                await session.close()
                if Task.isCancelled { return }
                online.remove(account.id)
                let message = (error as? LocalizedError)?.errorDescription ?? "Connection failed. Check the IMAP server and your network."
                if (error as? MailError) == .authenticationFailed { retry = 300 }
                statuses[account.id] = "\(message) (retrying in \(retry)s)"
                do { try await Task.sleep(nanoseconds: retry * 1_000_000_000) } catch { return }
                retry = min(retry * 2, 300)
            }
        }
    }
}
