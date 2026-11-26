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
            let account = MailAccount(name: "个人邮箱", username: "hello@example.com", host: "imap.example.com")
            config.accounts = [account]; statuses[account.id] = "实时监听中"; online.insert(account.id)
            history = [CodeEvent(code: "482916", sender: "Example <no-reply@example.com>", account: account.username)]
        } else {
            do { config = try store.load() }
            catch { persistenceReady = false; errorMessage = "配置读取失败，未覆盖原文件。请检查 ~/Library/Application Support/MailCode/settings.json。" }
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
    var summary: String {
        if locked || sleeping { return "已暂停 · 等待解锁或唤醒" }
        if paused { return "监听已暂停" }
        if accounts.isEmpty { return "连接邮箱，让验证码自己过来" }
        let enabled = accounts.filter(\.enabled).count
        if enabled == 0 { return "邮箱均已停用" }
        return online.isEmpty ? "正在连接邮箱…" : "\(online.count) 个邮箱正在监听"
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
        if value { stop(); lookupTask?.cancel(); onHidePopup?(); clearOwnedClipboard(); history.removeAll(); latestCodes.removeAll() } else { start() }
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
            if enabled && !launchAtLogin { errorMessage = "请在系统设置 → 通用 → 登录项中允许「InboxCode」后台运行。" }
        } catch { errorMessage = "开机启动设置失败。请先把应用移到「应用程序」后再试。" }
    }
    func saveAccount(_ account: MailAccount, password: String) throws {
        guard persistenceReady else { throw MailError.commandRejected("保存配置") }
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
        if oldAccount != account { latestCodes.removeValue(forKey: account.id); lookupErrors.removeValue(forKey: account.id) }
        config = next; restart()
    }
    func removeAccount(_ id: UUID) {
        var next = config; next.accounts.removeAll { $0.id == id }; next.checkpoints.removeValue(forKey: id.uuidString)
        guard persist(next) else { return }
        do { try Keychain.delete(id) }
        catch { _ = persist(config); errorMessage = error.localizedDescription; return }
        config = next; statuses.removeValue(forKey: id); restart()
        latestCodes.removeValue(forKey: id); lookupErrors.removeValue(forKey: id)
    }
    func enableAccount(_ id: UUID, enabled: Bool) {
        var next = config
        guard let index = next.accounts.firstIndex(where: { $0.id == id }) else { return }
        next.accounts[index].enabled = enabled
        guard persist(next) else { return }; config = next; restart()
    }
    func test(account: MailAccount, password: String) async throws {
        try account.validate(password: password)
        let session = IMAPSession(transport: TLSIMAPTransport(host: account.host, port: account.port))
        do { _ = try await session.open(account: account, password: password); await session.close() }
        catch { await session.close(); throw error }
    }
    func refreshLatest() async {
        guard !locked else { return }
        if let lookupTask { await lookupTask.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            let activeAccounts = self.accounts.filter(\.enabled)
            // Limit concurrent logins to avoid a burst with many configured accounts.
            for start in stride(from: 0, to: activeAccounts.count, by: 3) {
                if Task.isCancelled { return }
                var credentials: [(MailAccount, String)] = []
                for account in activeAccounts[start..<min(start + 3, activeAccounts.count)] {
                    do { credentials.append((account, try Keychain.read(account.id))) }
                    catch { self.lookupErrors[account.id] = error.localizedDescription }
                }
                await withTaskGroup(of: LookupResult.self) { group in
                    for (account, password) in credentials { group.addTask { await MailLookup.latest(account: account, password: password) } }
                    for await result in group {
                        guard !Task.isCancelled, !self.locked,
                              self.accounts.first(where: { $0.id == result.accountID }) == activeAccounts.first(where: { $0.id == result.accountID }) else { continue }
                        self.lookupErrors[result.accountID] = result.error
                        if let code = result.code, code.receivedAt >= (self.latestCodes[result.accountID]?.receivedAt ?? 0) { self.latestCodes[result.accountID] = code }
                    }
                }
            }
        }
        lookupTask = task; await task.value; lookupTask = nil
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
    func demo() {
        let message = MIMEMessage(data: Data("Subject: InboxCode测试验证码\r\nFrom: InboxCode演示\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n你的验证码是 482916，十分钟内有效。".utf8))
        guard let code = OTPExtractor.extract(subject: message.subject, body: message.text) else { return }
        deliver(CodeEvent(code: code, sender: "InboxCode演示", account: "本地测试"))
    }
    private func deliver(_ event: CodeEvent) {
        guard !locked, !sleeping else { return }
        purgeExpired()
        history.insert(event, at: 0); history = Array(history.prefix(8))
        let copied = preferences.autoCopy && copy(event)
        if preferences.showPopup { onCode?(event, copied) }
    }
    private func persist(_ next: Configuration) -> Bool {
        guard persistenceReady else { return false }
        do { try store.save(next); return true }
        catch { errorMessage = "配置保存失败，请检查磁盘空间和目录权限。"; return false }
    }
    private func checkpoint(_ value: MailboxCheckpoint, account: MailAccount) {
        config.checkpoints[account.id.uuidString] = value
        _ = persist(config)
    }
    private func purgeExpired() {
        let now = Date()
        history.removeAll { now.timeIntervalSince($0.received) > 600 }
        seen = seen.filter { now.timeIntervalSince($0.value) < 600 }
    }
    private func monitor(_ account: MailAccount) async {
        let password: String
        do { password = try Keychain.read(account.id) }
        catch { statuses[account.id] = error.localizedDescription; return }
        var retry: UInt64 = 5
        while !Task.isCancelled {
            statuses[account.id] = "正在安全连接…"
            let session = IMAPSession(transport: TLSIMAPTransport(host: account.host, port: account.port))
            do {
                let baseline = try await session.open(account: account, password: password)
                try Task.checkCancellation()
                var cursor = MailboxCheckpoint.resume(stored: config.checkpoints[account.id.uuidString], baseline: baseline)
                checkpoint(cursor, account: account)
                online.insert(account.id); retry = 5
                statuses[account.id] = await session.supportsIdle ? "实时监听中" : "每 20 秒检查"
                while !Task.isCancelled {
                    let uids = try await session.newUIDs(after: cursor.lastUID)
                    for uid in uids.suffix(100) {
                        let fetched = try await session.fetch(uid: uid)
                        try Task.checkCancellation()
                        if let (data, date) = fetched, Freshness.accepts(date) {
                            let mail = MIMEMessage(data: data)
                            if let code = OTPExtractor.extract(subject: mail.subject, body: mail.text) {
                                let latest = LatestCode(account: account, uid: uid, mail: mail, code: code, date: date!)
                                latestCodes[account.id] = latest
                                purgeExpired()
                                let identity = account.id.uuidString + "|" + mail.sender + "|" + code
                                if seen[identity] == nil {
                                    seen[identity] = Date()
                                    deliver(CodeEvent(code: code, sender: mail.sender, account: account.username, received: date!, provider: latest.provider))
                                }
                            }
                        }
                        cursor.lastUID = uid; checkpoint(cursor, account: account)
                    }
                    try await session.waitForChange()
                    statuses[account.id] = await session.supportsIdle ? "实时监听中" : "每 20 秒检查"
                }
                await session.close()
            } catch {
                await session.close()
                if Task.isCancelled { return }
                online.remove(account.id)
                let message = (error as? LocalizedError)?.errorDescription ?? "网络连接失败，请检查 IMAP 地址或网络。"
                if (error as? MailError) == .authenticationFailed { retry = 300 }
                statuses[account.id] = "\(message)（\(retry) 秒后重试）"
                do { try await Task.sleep(nanoseconds: retry * 1_000_000_000) } catch { return }
                retry = min(retry * 2, 300)
            }
        }
    }
}
