import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: AppModel
    @ObservedObject var bridge: BridgeModel
    let rule: FolderRule

    init(rule: FolderRule, bridge: BridgeModel) {
        self.rule = rule
        self.bridge = bridge
        _model = StateObject(wrappedValue: AppModel(client: bridge.client(for: rule.remote), root: rule.remote.root))
    }
    @ViewState private var showHistory = false
    @ViewState private var selection: RemoteItem.ID?
    @ViewState private var showingNewFolder = false
    @ViewState private var showingRename = false
    @ViewState private var showingMove = false
    @ViewState private var showingDelete = false
    @ViewState private var inspectingItem: RemoteItem?
    @ViewState private var textInput = ""

    private var selectedItem: RemoteItem? { model.items.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider()
            pathBar
            Divider()
            Table(model.items, selection: $selection) {
                TableColumn("名称") { item in
                    HStack {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundStyle(item.isDirectory ? .blue : .secondary)
                        Text(item.name)
                    }
                    .contentShape(Rectangle())
                }
                TableColumn("大小") { item in Text(item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) }
                    .width(min: 90, ideal: 110, max: 150)
                TableColumn("修改时间") { item in
                    if let date = item.modifiedAt { Text(date, format: .dateTime.year().month().day().hour().minute()) }
                    else { Text("—") }
                }.width(min: 150, ideal: 180, max: 260)
            }
            .alternatingRowBackgrounds(.disabled)
            .contextMenu(forSelectionType: RemoteItem.ID.self) { ids in
                if let item = item(for: ids) {
                    itemContextMenu(item)
                } else {
                    backgroundContextMenu
                }
            } primaryAction: { ids in
                if let item = item(for: ids) { Task { await model.enter(item) } }
            }
            .overlay { if model.isBusy { ProgressView().controlSize(.large) } }
            Divider()
            statusBar
        }
        .alert("操作失败", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("新建文件夹", isPresented: $showingNewFolder) { textFieldAlert(confirm: "创建") { Task { await model.createFolder(named: textInput) } } }
        .alert("重命名", isPresented: $showingRename) { textFieldAlert(confirm: "重命名") { if let item = selectedItem { Task { await model.rename(item, to: textInput) } } } }
        .alert("移动到远程目录", isPresented: $showingMove) { textFieldAlert(confirm: "移动") { if let item = selectedItem { Task { await model.move(item, to: textInput) } } } } message: {
            Text("填写相对于“我的应用数据/bdpan”的目录路径。")
        }
        .alert("确认删除？", isPresented: $showingDelete, presenting: selectedItem) { item in
            Button("取消", role: .cancel) {}
            Button("移入恢复区", role: .destructive) { Task { await model.delete(item) } }
        } message: { item in
            Text("将“\(item.name)”\(item.isDirectory ? "及其全部内容" : "")移入网盘的 _FolderBridgeHistory/manual 恢复区，不会永久删除。")
        }
        .task { await model.refreshStatus(); if model.isLoggedIn { await model.refresh() } }
        .sheet(isPresented: $showHistory) {
            VStack(alignment: .leading) {
                Text("同步记录").font(.headline)
                List(bridge.ruleEvents[rule.id] ?? [], id: \.self) { Text($0).textSelection(.enabled) }
                Button("完成") { showHistory = false }.keyboardShortcut(.cancelAction)
            }.padding().frame(width: 560, height: 300)
        }
        .sheet(item: $inspectingItem) { ItemInfoView(item: $0) }
    }

    private var actionBar: some View {
        HStack(spacing: 9) {
            HStack(spacing: 3) {
                Button { Task { await model.refresh() } } label: {
                    Label("刷新列表", systemImage: "arrow.clockwise")
                }
                Button { beginNewFolder() } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
                Button { chooseUpload() } label: {
                    Label("上传", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(model.isBusy)

            Divider().frame(height: 18)

            HStack(spacing: 3) {
                Button {
                    if let item = selectedItem { download(item) }
                } label: {
                    Label("下载", systemImage: "square.and.arrow.down")
                }
                Button {
                    if let item = selectedItem { beginRename(item) }
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Button {
                    if let item = selectedItem { beginMove(item) }
                } label: {
                    Label("移动", systemImage: "folder")
                }
                Button(role: .destructive) {
                    if let item = selectedItem { confirmDelete(item) }
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .disabled(selectedItem == nil || model.isBusy)
            .help(selectedItem == nil ? "先选择一个文件或文件夹" : "")

            Spacer(minLength: 8)

            Button("同步记录") { showHistory = true }
            Button(rule.uploadsOnly ? "单向上传" : "同步") { Task { await bridge.sync(rule) } }
                .disabled(bridge.running.contains(rule.id) || !model.isLoggedIn)
            Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(BrowserButtonStyle())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button { Task { await model.goUp() } } label: {
                Label("返回上一级", systemImage: "chevron.left").labelStyle(.iconOnly)
            }
            .disabled(model.currentPath.isEmpty || model.isBusy)
            .help("返回上一级")
            Image(systemName: "externaldrive.fill.badge.icloud").foregroundStyle(.secondary)
            Text(model.displayPath)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Label {
                    Text(model.accountStatusText).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: model.isLoggedIn ? "checkmark.circle.fill" : "person.crop.circle")
                        .foregroundStyle(model.isLoggedIn ? Color.green : Color.secondary)
                }
                .font(.callout)
                Button("检查登录") { Task { await model.refreshStatus(); if model.isLoggedIn { await model.refresh() } } }
                    .help("检查百度网盘登录状态")
                if !model.isLoggedIn {
                    Button("登录") { model.openLogin() }
                        .buttonStyle(BrowserButtonStyle(emphasized: true))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(BrowserButtonStyle())
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusBar: some View {
        HStack {
            Label(model.network.isOnline ? (model.network.isHotspotLike ? "热点/受限网络" : "网络已连接") : "网络离线",
                  systemImage: model.network.isOnline ? "network" : "network.slash")
            Spacer()
            if let message = bridge.messages[rule.id] { Text(message).lineLimit(1) }
            Text("\(model.items.count) 项")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private func textFieldAlert(confirm: String, action: @escaping () -> Void) -> some View {
        TextField("名称或路径", text: $textInput)
        Button("取消", role: .cancel) {}
        Button(confirm, action: action)
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.upload(url) }
    }

    private func download(_ item: RemoteItem) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = item.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.download(item, to: url) }
    }

    private func item(for ids: Set<RemoteItem.ID>) -> RemoteItem? {
        guard let id = ids.first else { return nil }
        return model.items.first { $0.id == id }
    }

    private func beginNewFolder() {
        textInput = ""
        showingNewFolder = true
    }

    private func beginRename(_ item: RemoteItem) {
        selection = item.id
        textInput = item.name
        showingRename = true
    }

    private func beginMove(_ item: RemoteItem) {
        selection = item.id
        textInput = model.currentPath
        showingMove = true
    }

    private func confirmDelete(_ item: RemoteItem) {
        selection = item.id
        showingDelete = true
    }

    @ViewBuilder private func itemContextMenu(_ item: RemoteItem) -> some View {
        Button(item.isDirectory ? "打开" : "在百度网盘中查看") {
            if item.isDirectory { Task { await model.enter(item) } }
            else { model.openInBaiduDrive(item) }
        }
        .keyboardShortcut(.defaultAction)

        if item.isDirectory, item.returnURL != nil {
            Button("在百度网盘中查看") { model.openInBaiduDrive(item) }
        }
        Button("下载…") { download(item) }
        if item.returnURL != nil {
            Button("拷贝查看链接") { copyReturnLink(item) }
        }
        Button("显示简介") { inspectingItem = item }
            .keyboardShortcut("i", modifiers: .command)
        Divider()
        Button("重命名…") { beginRename(item) }
        Button("移动到…") { beginMove(item) }
        Divider()
        Button("删除…", role: .destructive) { confirmDelete(item) }
    }

    @ViewBuilder private var backgroundContextMenu: some View {
        Button("新建文件夹…") { beginNewFolder() }
        Button("上传…") { chooseUpload() }
        Divider()
        Button("刷新列表") { Task { await model.refresh() } }
    }

    private func copyReturnLink(_ item: RemoteItem) {
        guard let url = item.returnURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

private struct BrowserButtonStyle: ButtonStyle {
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        BrowserButton(configuration: configuration, emphasized: emphasized)
    }

    private struct BrowserButton: View {
        let configuration: Configuration
        let emphasized: Bool
        @Environment(\.isEnabled) private var isEnabled
        @ViewState private var isHovered = false

        var body: some View {
            configuration.label
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.primary)
                .opacity(isEnabled ? 1 : 0.42)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 6).fill(backgroundColor)
                }
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }

        private var backgroundColor: Color {
            guard isEnabled else { return .clear }
            if emphasized {
                return .accentColor.opacity(configuration.isPressed ? 0.26 : (isHovered ? 0.20 : 0.14))
            }
            return .primary.opacity(configuration.isPressed ? 0.14 : (isHovered ? 0.08 : 0))
        }
    }
}

private struct ItemInfoView: View {
    let item: RemoteItem
    @Environment(\.dismiss) private var dismiss

    private var visiblePath: String {
        item.path.replacingOccurrences(of: "/apps/bdpan", with: "我的应用数据/bdpan")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(item.isDirectory ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.title2.bold()).textSelection(.enabled)
                    Text(item.isDirectory ? "文件夹" : "文件").foregroundStyle(.secondary)
                }
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 11) {
                infoRow("位置", visiblePath)
                infoRow("大小", item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                infoRow("创建时间", formatted(item.createdAt))
                infoRow("修改时间", formatted(item.modifiedAt))
                if let md5 = item.md5 { infoRow("MD5", md5) }
            }

            HStack {
                if let url = item.returnURL {
                    Button("在百度网盘中查看") { NSWorkspace.shared.open(url) }
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520)
    }

    @ViewBuilder
    private func infoRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .long, time: .standard)
    }
}
