import AppKit
import SwiftUI

struct FolderBridgeView: View {
    @EnvironmentObject private var bridge: BridgeModel
    @AppStorage("workspaceAppearance") private var appearance = "system"
    @ViewState private var previewRule: FolderRule?
    @ViewState private var browsing: BridgeEndpoint?
    @ViewState private var resolving: FolderRule?
    @ViewState private var editing: FolderRule?
    @ViewState private var history: FolderRule?
    @ViewState private var removing: FolderRule?
    @ViewState private var scheduling: FolderRule?
    @ViewState private var managingCloud: FolderRule?
    @ViewState private var showLogs = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("同步关系").font(.title2.weight(.semibold))
                Spacer()
                Button {
                    editing = bridge.newRule()
                } label: { Label("添加同步", systemImage: "plus") }
                actionsMenu
            }.padding(16)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(bridge.rules) { rule in
                        HStack(spacing: 12) {
                            folderCell(rule.local, local: true)
                            Image(systemName: rule.uploadsOnly ? "arrow.right" : "arrow.left.arrow.right").foregroundStyle(.secondary)
                            folderCell(rule.remote, local: false)
                            if rule.uploadsOnly {
                                Button("检查") { Task { await bridge.sync(rule, previewOnly: true) } }
                                    .disabled(bridge.running.contains(rule.id))
                            }
                            Button(bridge.scanning.contains(rule.id) ? "检查中…" : bridge.running.contains(rule.id) ? (rule.uploadsOnly ? "上传中…" : "同步中…") : (rule.uploadsOnly ? "上传" : "同步")) {
                                Task { await bridge.sync(rule) }
                            }.disabled(bridge.running.contains(rule.id))
                            Menu {
                                Button("浏览本机文件夹") { browsing = rule.local }
                                Button("浏览远端文件夹") { browsing = rule.remote }
                                if rule.remote.kind == "baidu" {
                                    Button("网盘文件管理") { managingCloud = rule }
                                    Button("登录百度网盘…") {
                                        do { try bridge.client(for: rule.remote).openLoginTerminal() }
                                        catch { bridge.error = error.localizedDescription }
                                    }
                                    Divider()
                                }
                                Button("同步计划…") { scheduling = rule }
                                Button("编辑") { editing = rule }.disabled(bridge.running.contains(rule.id))
                                if !rule.uploadsOnly { Button("快照与恢复") { history = rule } }
                                Divider()
                                Button("移除同步关系", role: .destructive) { removing = rule }.disabled(bridge.running.contains(rule.id))
                            } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("管理同步关系")
                        }.padding(16)
                        if bridge.conflicts[rule.id] != nil {
                            Button("处理冲突") { resolving = rule }
                        }
                        if let plan = bridge.previews[rule.id] {
                            HStack {
                                Text("已检查 \(plan.checked) 个 · 本次需上传 \(plan.files.count) 个 · \(UploadPreview.format(plan.bytes))")
                                    .monospacedDigit()
                                Spacer()
                                Button("查看清单") { previewRule = rule }
                            }.font(.callout).padding(.horizontal, 16).padding(.bottom, 8)
                        }
                        if let message = bridge.messages[rule.id] {
                            Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.bottom, 10)
                        }
                        Divider()
                    }
                }
            }.overlay { if bridge.rules.isEmpty { Text("暂无同步关系").foregroundStyle(.secondary) } }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: appearance, initial: true) { _, style in
            switch style {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: NSApp.appearance = nil
            }
        }

        .alert("操作未完成", isPresented: Binding(get: { bridge.error != nil }, set: { if !$0 { bridge.error = nil } })) {
            Button("好") { bridge.error = nil }
        } message: { Text(bridge.error ?? "") }
        .sheet(item: $previewRule) { rule in
            if let plan = bridge.previews[rule.id] {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("本次上传清单").font(.title2.bold())
                        Spacer()
                        Button("完成") { previewRule = nil }.keyboardShortcut(.cancelAction)
                    }
                    Text("\(plan.files.count) 个文件 · \(UploadPreview.format(plan.bytes))")
                    Table(plan.files) {
                        TableColumn("文件") { Text($0.path).lineLimit(1).truncationMode(.middle).help($0.path).textSelection(.enabled) }
                        TableColumn("大小") { Text(UploadPreview.format($0.size)).monospacedDigit() }.width(90)
                    }.overlay { if plan.files.isEmpty { Text("没有待上传文件").foregroundStyle(.secondary) } }
                }.padding(20).frame(minWidth: 480, idealWidth: 600, minHeight: 320, idealHeight: 420)
            }
        }
        .sheet(item: $scheduling) { rule in
            RuleScheduleEditor(rule: rule) { try bridge.storeOptions($0, for: rule.id) }
        }
        .sheet(item: $editing) { rule in RuleEditor(model: bridge, rule: rule, destinations: bridge.destinations, save: bridge.store) }
        .sheet(item: $history) { rule in SnapshotBrowser(model: bridge, rule: rule).task { await bridge.loadSnapshots(rule) } }
        .alert("移除这条同步关系？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { rule in
            Button("取消", role: .cancel) {}
            Button("移除关系", role: .destructive) { bridge.remove(rule) }
        } message: { _ in Text("两端文件和快照都会保留。") }
        .sheet(item: $managingCloud) { rule in
            ContentView(rule: rule, bridge: bridge).frame(minWidth: 780, idealWidth: 960, minHeight: 450, idealHeight: 600)
        }
        .sheet(isPresented: $showLogs) {
            VStack(alignment: .leading, spacing: 18) {
                Text("同步记录").font(.title2.bold())
                List(bridge.events, id: \.self) { Text($0).textSelection(.enabled) }
                Button("完成") { showLogs = false }.frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(24).frame(width: 760, height: 420)
        }
        .sheet(item: $resolving) { rule in ConflictBrowser(model: bridge, rule: rule) }
        .sheet(item: $browsing) { endpoint in DirectoryBrowser(model: bridge, endpoint: endpoint) }
    }

    private func folderCell(_ endpoint: BridgeEndpoint, local: Bool) -> some View {
        Button { browsing = endpoint } label: { VStack(alignment: .leading, spacing: 3) {
            Label(local ? "本机" : endpoint.name, systemImage: endpoint.symbol).font(.headline)
            Text(endpoint.root.isEmpty ? "/" : (local ? (endpoint.root as NSString).abbreviatingWithTildeInPath : endpoint.root))
                .lineLimit(2).truncationMode(.middle).help(endpoint.root)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).help("浏览文件夹")
    }
    private var actionsMenu: some View {
        Menu("更多") {
            Picker("外观", selection: $appearance) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            Divider()
            Button("查看同步记录") { showLogs = true }
            Button("在 Finder 打开恢复区") { bridge.openRecovery() }
        }.fixedSize()
    }
}

private struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BridgeModel
    @ViewState private var picker: BridgeEndpoint?
    @ViewState var rule: FolderRule
    let destinations: [BridgeEndpoint]
    let save: (FolderRule) throws -> Void
    @ViewState private var custom = false
    @ViewState private var issue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("同步关系").font(.title2.bold())
            VStack(alignment: .leading, spacing: 10) {
                Label("本机文件夹", systemImage: "laptopcomputer").font(.headline)
                    HStack {
                        Text(rule.local.root.isEmpty ? "未选择" : (rule.local.root as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(2).truncationMode(.middle)
                        Spacer()
                        Button("浏览…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.directoryURL = URL(fileURLWithPath: rule.local.root)
                            if panel.runModal() == .OK, let url = panel.url { rule.local.root = url.path }
                        }
                    }
            }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 12) {
                HStack { Label("远端文件夹", systemImage: "server.rack").font(.headline); Spacer()
                    Menu(custom ? "新的 SSH 服务器" : rule.remote.name) {
                        ForEach(destinations) { remote in
                            Button(remote.name) {
                                if rule.remote.kind != remote.kind { rule.direction = nil }
                                let account = rule.remote.kind == "baidu" ? rule.remote.profileID : rule.id
                                rule.remote = remote
                                rule.remote.profileID = remote.kind == "baidu" ? account : nil
                                custom = false
                            }
                        }
                        Divider()
                        Button("新的 SSH 服务器…") {
                            if rule.remote.kind != "ssh" { rule.direction = nil }
                            rule.remote = BridgeEndpoint(name: "", kind: "ssh", root: "")
                            custom = true
                        }
                    }
                }
                if rule.remote.kind == "baidu" {
                    HStack {
                        Picker("网盘账号", selection: Binding(get: { rule.remote.profileID != nil }, set: {
                            rule.remote.profileID = $0 ? rule.id : nil
                        })) {
                            Text("此关系的独立账号").tag(true)
                            Text("原有账号").tag(false)
                        }
                        Button("登录…") {
                            do { try model.client(for: rule.remote).openLoginTerminal() }
                            catch { issue = error.localizedDescription }
                        }
                    }
                }
                if custom {
                    TextField("SSH 主机", text: $rule.remote.host, prompt: Text("user@host 或 SSH 别名"))
                    DisclosureGroup("连接选项") {
                        TextField("端口", value: $rule.remote.port, format: .number.grouping(.never))
                        TextField("私钥路径", text: $rule.remote.identityFile)
                    }
                }
                HStack {
                    TextField("远端路径", text: $rule.remote.root, prompt: Text(rule.remote.kind == "baidu" ? "网盘根目录" : "/srv/workspace"))
                    Button("浏览…") { picker = rule.remote }.disabled(rule.remote.kind == "ssh" && rule.remote.host.isEmpty)
                }
            }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            Picker("同步方向", selection: Binding(get: { rule.effectiveDirection }, set: { rule.direction = $0 })) {
                Text("本机 → 远端").tag(SyncDirection.upload)
                Text("双向同步").tag(SyncDirection.bidirectional)
            }.pickerStyle(.segmented)
            DisclosureGroup("同步计划") {
                RuleScheduleControls(options: $rule.settings, isBaiduUpload: rule.uploadsOnly && rule.remote.kind == "baidu")
            }
            if !issue.isEmpty { Text(issue).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    var value = rule
                    if value.remote.kind == "baidu" {
                        guard let root = value.remote.root.normalizedRemotePath else { issue = "网盘路径无效"; return }
                        value.remote.root = root
                    } else {
                        guard value.remote.root.hasPrefix("/"), (value.remote.root as NSString).standardizingPath != "/",
                              !value.remote.host.isEmpty, (1...65535).contains(value.remote.port) else {
                            issue = "请输入 SSH 主机、有效端口和远端文件夹完整路径"; return
                        }
                        if custom { value.remote.name = value.remote.host }
                    }
                    guard !value.local.root.isEmpty, value.local.root != "/" else { issue = "请选择具体的本机文件夹"; return }
                    do { try save(value); dismiss() } catch { issue = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 480)
        .sheet(item: $picker) { endpoint in DirectoryBrowser(model: model, endpoint: endpoint, choose: { rule.remote.root = $0 }) }
    }
}

private struct ConflictBrowser: View {
    @ObservedObject var model: BridgeModel
    let rule: FolderRule
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("双方都有修改", systemImage: "exclamationmark.triangle.fill").font(.title2.bold()).foregroundStyle(.orange)
            Text("当前没有写入任何文件。可以取消并手动处理，或为以下冲突选择一侧版本；另一侧会先保存到恢复区。").foregroundStyle(.secondary)
            Table(model.conflicts[rule.id] ?? []) {
                TableColumn("路径") { Text($0.path).textSelection(.enabled) }
                TableColumn("左侧") { Text($0.left).foregroundStyle(.secondary) }
                TableColumn("右侧") { Text($0.right).foregroundStyle(.secondary) }
            }.frame(height: 300)
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("冲突项保留左侧") { dismiss(); Task { await model.sync(rule, prefer: "left") } }
                Button("冲突项保留右侧") { dismiss(); Task { await model.sync(rule, prefer: "right") } }
            }
        }.padding(26).frame(width: 940)
    }
}

private struct SnapshotBrowser: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BridgeModel
    let rule: FolderRule
    @ViewState private var restoring: BridgeSnapshot?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("快照与恢复").font(.title2.bold())
            Text("每次成功同步都保存完整目录状态，文件内容按版本去重保存。恢复前也会创建一份备份。").foregroundStyle(.secondary)
            List(model.snapshots) { snapshot in
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(Date(timeIntervalSince1970: snapshot.created).formatted(date: .abbreviated, time: .standard)).fontWeight(.medium)
                        Text(snapshot.reason + " · " + snapshot.id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("恢复到两端") { restoring = snapshot }.disabled(model.running.contains(rule.id))
                }.padding(.vertical, 5)
            }.frame(height: 320).overlay { if model.snapshots.isEmpty { Text("此同步对还没有快照。完成第一次同步后会显示在这里。").foregroundStyle(.secondary) } }
            HStack {
                Button("打开恢复区") { model.openRecovery() }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 800)
        .alert("恢复这个快照？", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), presenting: restoring) { snapshot in
            Button("取消", role: .cancel) { restoring = nil }
            Button("保存当前状态并恢复") { restoring = nil; dismiss(); Task { await model.restore(snapshot, rule: rule) } }
        } message: { _ in Text("两个主文件夹都会恢复到所选快照的状态，当前内容会先备份。") }
    }
}
