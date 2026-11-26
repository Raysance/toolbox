import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [RemoteItem] = []
    @Published var currentPath = ""
    @Published var isBusy = false
    @Published var accountStatusText = "正在检查登录状态…"
    @Published var isLoggedIn = false
    @Published var errorMessage: String?
    let network = NetworkState()
    private let client: BDPanClient

    init(client: BDPanClient, root: String) {
        self.client = client
        currentPath = root.normalizedRemotePath ?? ""
    }

    var displayPath: String {
        currentPath.isEmpty ? "我的应用数据/bdpan" : "我的应用数据/bdpan/\(currentPath)"
    }

    func refreshStatus() async {
        let state = await client.loginStatus()
        isLoggedIn = state.isLoggedIn
        accountStatusText = state.label
    }

    func refresh() async {
        isBusy = true
        defer { isBusy = false }
        do { items = try await client.list(currentPath); errorMessage = nil }
        catch { errorMessage = error.localizedDescription; items = [] }
    }

    func enter(_ item: RemoteItem) async {
        guard item.isDirectory else {
            if let url = item.returnURL { NSWorkspace.shared.open(url) }
            return
        }
        currentPath = pathFromAPI(item.path)
        await refresh()
    }

    func openInBaiduDrive(_ item: RemoteItem) {
        guard let url = item.returnURL else {
            errorMessage = "该项目暂时没有可用的百度网盘查看链接。"
            return
        }
        NSWorkspace.shared.open(url)
    }

    func goUp() async {
        currentPath = currentPath.split(separator: "/").dropLast().joined(separator: "/")
        await refresh()
    }

    func createFolder(named name: String) async {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.contains("/") else { errorMessage = "请输入不含 / 的文件夹名称。"; return }
        await perform { try await self.client.createDirectory(self.join(self.currentPath, cleaned)) }
    }

    func rename(_ item: RemoteItem, to newName: String) async {
        await perform { try await self.client.rename(self.pathFromAPI(item.path), to: newName) }
    }

    func move(_ item: RemoteItem, to directory: String) async {
        await perform { try await self.client.move(self.pathFromAPI(item.path), to: directory) }
    }

    func delete(_ item: RemoteItem) async {
        await perform { try await self.client.delete(self.pathFromAPI(item.path)) }
    }

    func upload(_ url: URL) async {
        if items.contains(where: { $0.name == url.lastPathComponent }) {
            errorMessage = "远端已有同名内容，已安全跳过，不会覆盖。"
            return
        }
        await perform { try await self.client.upload(localURL: url, to: self.join(self.currentPath, url.lastPathComponent)) }
    }

    func download(_ item: RemoteItem, to url: URL) async {
        isBusy = true
        defer { isBusy = false }
        do { try await client.download(pathFromAPI(item.path), to: url) }
        catch { errorMessage = error.localizedDescription }
    }

    func openLogin() {
        do { try client.openLoginTerminal() }
        catch { errorMessage = error.localizedDescription }
    }

    private func perform(_ operation: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do { try await operation(); errorMessage = nil; await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    private func pathFromAPI(_ path: String) -> String {
        path.replacingOccurrences(of: "/apps/bdpan/", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func join(_ lhs: String, _ rhs: String) -> String {
        [lhs, rhs].filter { !$0.isEmpty }.joined(separator: "/")
    }
}
