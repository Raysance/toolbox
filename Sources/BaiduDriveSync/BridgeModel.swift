import AppKit
import Foundation

struct BridgeEndpoint: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var kind: String
    var root: String
    var host = ""
    var port = 22
    var identityFile = ""
    var profileID: UUID?
    var symbol: String { kind == "local" ? "laptopcomputer" : kind == "ssh" ? "server.rack" : "externaldrive.fill.badge.icloud" }
    var typeName: String { kind == "local" ? "本机" : kind == "ssh" ? "SSH 服务器" : "百度网盘" }
    func request() -> [String: Any] {
        var result: [String: Any] = ["kind": kind, "root": root, "host": host, "port": port, "identityFile": identityFile]
        if kind == "baidu" { result["bdpan"] = (try? BDPanClient.shared.executableURL().path) ?? "" }
        if kind == "baidu", let profileID { result["profileID"] = profileID.uuidString }
        return result
    }
}

enum SyncDirection: String, Codable {
    case upload, bidirectional
}

struct RuleOptions: Codable, Equatable {
    var automatic = false
    var minutes = 60
    var allowMetered = false
    var parallelUploads = 4
}

struct FolderRule: Identifiable, Codable {
    var id = UUID()
    var local: BridgeEndpoint
    var remote: BridgeEndpoint
    var remoteFirst = false
    var direction: SyncDirection?
    var baselineGeneration: UUID?
    var options: RuleOptions?
    var settings: RuleOptions {
        get { options ?? RuleOptions() }
        set { options = newValue }
    }
    var effectiveDirection: SyncDirection {
        direction ?? (remote.kind == "baidu" ? .upload : .bidirectional)
    }
    var uploadsOnly: Bool { effectiveDirection == .upload }
    var sides: [BridgeEndpoint] { remoteFirst ? [remote, local] : [local, remote] }
    func matches(_ other: FolderRule) -> Bool {
        local.root == other.local.root && remote.kind == other.remote.kind && remote.profileID == other.remote.profileID &&
        remote.host == other.remote.host && remote.port == other.remote.port && remote.root == other.remote.root
    }
}

struct BridgeSnapshot: Decodable, Identifiable {
    let id: String
    let created: Double
    let reason: String
    let leftRoot: String
    let rightRoot: String
}
struct BridgeConflict: Identifiable {
    var id: String { path }
    let path: String
    let left: String
    let right: String
}
private struct BridgeConfiguration: Codable {
    var endpoints: [BridgeEndpoint]
    var selected: [UUID]
}
enum BridgeFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

private enum BridgeWorker {
    static func run(data: Data, script: URL, state: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = [script.path, "request", "--state", state.path]
                    let input = Pipe(), output = Pipe(), error = Pipe()
                    process.standardInput = input; process.standardOutput = output; process.standardError = error
                    try process.run()
                    input.fileHandleForWriting.write(data)
                    try input.fileHandleForWriting.close()
                    let reply = output.fileHandleForReading.readDataToEndOfFile()
                    let diagnostic = error.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if reply.isEmpty { throw BridgeFailure.message(String(data: diagnostic, encoding: .utf8) ?? "同步进程未返回结果。") }
                    continuation.resume(returning: reply)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

@MainActor
final class BridgeModel: ObservableObject {
    @Published private(set) var rules: [FolderRule] = []
    @Published private(set) var servers: [BridgeEndpoint] = []
    @Published private(set) var running = Set<UUID>()
    @Published private(set) var previews: [UUID: UploadPreview] = [:]
    @Published private(set) var scanning = Set<UUID>()
    @Published var messages: [UUID: String] = [:]
    @Published var error: String?
    @Published var conflicts: [UUID: [BridgeConflict]] = [:]
    @Published var snapshots: [BridgeSnapshot] = []
    @Published var events: [String] = []
    @Published private(set) var ruleEvents: [UUID: [String]] = [:]
    private var conflictTokens: [UUID: String] = [:]
    let state: URL
    private let defaultOptions: RuleOptions
    private let configFile: URL
    private var profileLedgers: [UUID: SyncLedger] = [:]
    private let uploadLedger: SyncLedger

    init(support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0], uploadLedger: SyncLedger = .shared) {
        let legacy = SettingsStore(support: support).value
        defaultOptions = RuleOptions(minutes: legacy.intervalMinutes, allowMetered: legacy.syncOnHotspot,
                                     parallelUploads: legacy.maxConcurrentUploads)
        self.uploadLedger = uploadLedger
        state = support.appendingPathComponent("FolderBridge")
        configFile = state.appendingPathComponent("rules.json")
        do {
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            let legacyURL = state.appendingPathComponent("connections.json")
            let old = try FileManager.default.fileExists(atPath: legacyURL.path)
                ? JSONDecoder().decode(BridgeConfiguration.self, from: Data(contentsOf: legacyURL)) : nil
            servers = old?.endpoints.filter { $0.kind != "local" } ?? []
            if FileManager.default.fileExists(atPath: configFile.path) {
                rules = try JSONDecoder().decode([FolderRule].self, from: Data(contentsOf: configFile))
                if rules.contains(where: { $0.direction == nil || $0.options == nil }) { try persist(rules) }
                return
            }
            var migrated: [FolderRule] = []
            if let old {
                let pair = old.selected.compactMap { id in old.endpoints.first { $0.id == id } }
                if pair.count == 2, let mac = pair.first(where: { $0.kind == "local" }),
                   let remote = pair.first(where: { $0.kind != "local" }) {
                    migrated.append(FolderRule(local: mac, remote: remote, remoteFirst: pair[0].kind != "local"))
                }
            }
            let settings = support.appendingPathComponent("BaiduDriveSync/settings.json")
            if FileManager.default.fileExists(atPath: settings.path) {
                let oldSettings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settings))
                for mapping in oldSettings.mappings {
                    let pair = FolderRule(local: BridgeEndpoint(name: "本机", kind: "local", root: mapping.localPath),
                                          remote: BridgeEndpoint(name: "百度网盘", kind: "baidu", root: mapping.remotePath))
                    if !migrated.contains(where: { $0.matches(pair) }) { migrated.append(pair) }
                }
            }
            try persist(migrated)
        } catch { self.error = error.localizedDescription }
    }
    private func profileDirectory(_ id: UUID) -> URL {
        state.appendingPathComponent("baidu-accounts").appendingPathComponent(id.uuidString)
    }
    func client(for endpoint: BridgeEndpoint) -> BDPanClient {
        BDPanClient(profileDirectory: endpoint.profileID.map(profileDirectory))
    }
    private func uploadEngine(for endpoint: BridgeEndpoint) -> SyncEngine {
        guard let id = endpoint.profileID else { return SyncEngine(ledger: uploadLedger) }
        let ledger = profileLedgers[id] ?? SyncLedger(fileURL: profileDirectory(id).appendingPathComponent("upload-ledger.json"))
        profileLedgers[id] = ledger
        return SyncEngine(ledger: ledger, client: client(for: endpoint))
    }
    func newRule() -> FolderRule {
        var rule = FolderRule(local: BridgeEndpoint(name: "本机", kind: "local", root: ""),
                              remote: destinations.first ?? BridgeEndpoint(name: "百度网盘", kind: "baidu", root: ""))
        if rule.remote.kind == "baidu" { rule.remote.profileID = rule.id }
        rule.settings = defaultOptions
        return rule
    }
    var destinations: [BridgeEndpoint] {
        var seen = Set<String>()
        return (servers + rules.map(\.remote) + [BridgeEndpoint(name: "百度网盘", kind: "baidu", root: "")]).filter {
            seen.insert($0.kind + "|" + $0.host + "|" + String($0.port) + "|" + $0.identityFile).inserted
        }
    }
    private func persist(_ values: [FolderRule]) throws {
        let values = values.map { rule in
            var saved = rule
            saved.direction = rule.effectiveDirection
            saved.options = rule.options ?? defaultOptions
            return saved
        }
        guard values.allSatisfy({ (1...1440).contains($0.settings.minutes) && (1...8).contains($0.settings.parallelUploads) }) else {
            throw BridgeFailure.message("同步间隔可设为 1 到 1440 分钟，并行上传数可设为 1 到 8。")
        }
        try JSONEncoder().encode(values).write(to: configFile, options: .atomic)
        rules = values
    }
    func store(_ rule: FolderRule) throws {
        if rules.contains(where: { $0.id != rule.id && $0.matches(rule) }) {
            throw BridgeFailure.message("这条同步关系已经存在。")
        }
        var updated = rules
        if let index = updated.firstIndex(where: { $0.id == rule.id }) {
            var saved = rule
            if saved.effectiveDirection != updated[index].effectiveDirection || saved.remote.profileID != updated[index].remote.profileID {
                saved.baselineGeneration = UUID()
            }
            updated[index] = saved
        }
        else { updated.append(rule) }
        guard !running.contains(rule.id) else { throw BridgeFailure.message("这条关系正在同步。") }
        try persist(updated)
        previews[rule.id] = nil
        conflicts[rule.id] = nil; conflictTokens[rule.id] = nil; messages[rule.id] = nil
    }
    func storeOptions(_ options: RuleOptions, for id: UUID) throws {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { throw BridgeFailure.message("同步关系已移除。") }
        var updated = rules
        updated[index].settings = options
        try persist(updated)
    }
    func remove(_ rule: FolderRule) {
        do { try persist(rules.filter { $0.id != rule.id }) } catch { self.error = error.localizedDescription }
    }
    func call(_ request: [String: Any]) async throws -> [String: Any] {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("folderbridge_engine.py"), FileManager.default.fileExists(atPath: script.path) else { throw BridgeFailure.message("未找到 FolderBridge 同步引擎。") }
        let data = try JSONSerialization.data(withJSONObject: request)
        let result = try await BridgeWorker.run(data: data, script: script, state: state)
        guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any] else { throw BridgeFailure.message("同步结果无法解析。") }
        if object["status"] as? String == "error" { throw BridgeFailure.message(object["message"] as? String ?? "同步失败。") }
        return object
    }
    private func overlapsRunningRule(_ rule: FolderRule) -> Bool {
        func overlaps(_ a: String, _ b: String) -> Bool {
            let a = URL(fileURLWithPath: "/" + a).standardizedFileURL.pathComponents
            let b = URL(fileURLWithPath: "/" + b).standardizedFileURL.pathComponents
            return a.starts(with: b) || b.starts(with: a)
        }
        return rules.contains { other in
            guard running.contains(other.id) else { return false }
            let localA = URL(fileURLWithPath: rule.local.root).resolvingSymlinksInPath().path
            let localB = URL(fileURLWithPath: other.local.root).resolvingSymlinksInPath().path
            return overlaps(localA.precomposedStringWithCanonicalMapping.lowercased(),
                            localB.precomposedStringWithCanonicalMapping.lowercased()) ||
                   (rule.remote.kind == "baidu" && other.remote.kind == "baidu" && rule.remote.profileID == other.remote.profileID &&
                    overlaps(rule.remote.root, other.remote.root))
        }
    }
    func sync(_ selected: FolderRule, prefer: String? = nil, previewOnly: Bool = false) async {
        guard let rule = rules.first(where: { $0.id == selected.id && $0.matches(selected) &&
            $0.effectiveDirection == selected.effectiveDirection }) else { return }
        let id = rule.id
        guard !running.contains(id) else { return }
        guard !overlapsRunningRule(rule) else { messages[id] = "目录正由另一条同步关系使用。"; return }
        if prefer != nil && conflictTokens[id] == nil { return }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rule.local.root, isDirectory: &directory), directory.boolValue else {
            error = "找不到本机文件夹：" + rule.local.root
            return
        }
        running.insert(id)
        defer { running.remove(id) }
        let pair = rule.uploadsOnly ? [rule.local, rule.remote] : rule.sides
        messages[id] = rule.uploadsOnly ? "正在检查需要上传的文件…" : "正在比较两端内容并保存恢复快照…"
        if previewOnly && !rule.uploadsOnly { return }
        if rule.uploadsOnly {
            previews[id] = nil
            scanning.insert(id)
            do {
                let plan: UploadPreview
                if rule.remote.kind == "baidu" {
                    let mapping = SyncMapping(localPath: rule.local.root, remotePath: rule.remote.root)
                    plan = try await uploadEngine(for: rule.remote).preview(mapping: mapping) { count in
                        await MainActor.run { self.messages[id] = "已检查 " + String(count) + " 个文件…" }
                    }
                } else {
                    let reply = try await call(["op": "previewUpload", "left": rule.local.request(), "right": rule.remote.request()])
                    plan = try JSONDecoder().decode(UploadPreview.self, from: JSONSerialization.data(withJSONObject: reply))
                }
                previews[id] = plan
                scanning.remove(id)
                messages[id] = previewOnly ? nil : "正在补传…"
                if previewOnly { return }
            } catch {
                scanning.remove(id)
                messages[id] = "检查未完成 · " + error.localizedDescription
                return
            }
        }
        if rule.uploadsOnly && rule.remote.kind == "baidu" {
            let mapping = SyncMapping(localPath: rule.local.root, remotePath: rule.remote.root)
            let outcome = await uploadEngine(for: rule.remote).sync(
                mapping: mapping,
                maxConcurrentUploads: rule.settings.parallelUploads,
                onProgress: { progress in
                    await MainActor.run { self.messages[id] = progress.description }
                },
                report: { _ in }
            )
            let result = outcome.succeeded ? "单向上传完成" : "上传未全部完成"
            messages[id] = result + " · " + outcome.progress.description
            if outcome.message != "同步完成" { messages[id, default: ""] += " · " + outcome.message }
            recordEvent(rule)
            return
        }
        var request: [String: Any] = ["op": "sync", "left": pair[0].request(), "right": pair[1].request()]
        request["direction"] = rule.effectiveDirection.rawValue
        request["baselineGeneration"] = rule.baselineGeneration?.uuidString
        if let prefer { request["prefer"] = prefer; request["conflictToken"] = conflictTokens[id] }
        conflicts[id] = nil
        do {
            let result = try await call(request)
            if result["status"] as? String == "conflict" {
                conflictTokens[id] = result["conflictToken"] as? String
                conflicts[id] = (result["conflicts"] as? [[String: Any]] ?? []).map { row in
                    func describe(_ value: Any?) -> String {
                        guard let value = value as? [String: Any] else { return "已删除 / 不存在" }
                        if value["type"] as? String == "dir" { return "文件夹" }
                        return "\(value["size"] as? Int ?? 0) 字节 · \(String((value["hash"] as? String ?? "").prefix(8)))"
                    }
                    return BridgeConflict(path: row["path"] as? String ?? "", left: describe(row["left"]), right: describe(row["right"]))
                }
                messages[id] = "发现 \(conflicts[id]?.count ?? 0) 项冲突；未写入任何文件。"
            } else {
                conflictTokens[id] = nil
                messages[id] = rule.uploadsOnly ? "单向上传完成 · \(result["operations"] as? Int ?? 0) 项变更" : "两端已同步一致 · \(result["operations"] as? Int ?? 0) 项变更 · 快照已保存"
            }
        } catch { messages[id] = error.localizedDescription }
        recordEvent(rule)
    }
    private func recordEvent(_ rule: FolderRule) {
        let id = rule.id
        let entry = "\(Date().formatted(date: .omitted, time: .standard))  \(rule.remote.name) · \(messages[id] ?? "")"
        events.insert(entry, at: 0)
        ruleEvents[id, default: []].insert(entry, at: 0)


    }
    func loadSnapshots(_ rule: FolderRule) async {
        snapshots = []
        let chosen = rule.sides
        do {
            let result = try await call(["op": "snapshots", "left": chosen[0].request(), "right": chosen[1].request()])
            guard !Task.isCancelled else { return }
            snapshots = try JSONDecoder().decode([BridgeSnapshot].self, from: JSONSerialization.data(withJSONObject: result["snapshots"] ?? []))
        } catch { self.error = error.localizedDescription }
    }
    func restore(_ snapshot: BridgeSnapshot, rule: FolderRule) async {
        let id = rule.id
        guard rules.contains(where: { $0.id == id && $0.matches(rule) && !$0.uploadsOnly }),
              !overlapsRunningRule(rule) else { return }
        conflicts[id] = nil; conflictTokens[id] = nil
        let chosen = rule.sides
        running.insert(id)
        defer { running.remove(id) }
        messages[id] = "正在保存当前状态并恢复快照…"
        do {
            _ = try await call(["op": "restore", "direction": rule.effectiveDirection.rawValue, "baselineGeneration": rule.baselineGeneration?.uuidString ?? "", "left": chosen[0].request(), "right": chosen[1].request(), "snapshot": snapshot.id, "side": "left"])
            messages[id] = "快照已恢复到两端；恢复前的状态也已保存。"
        } catch { messages[id] = error.localizedDescription }

    }
    func openRecovery() { NSWorkspace.shared.open(state.appendingPathComponent("recovery")) }
}
