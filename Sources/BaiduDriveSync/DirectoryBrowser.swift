import SwiftUI

private struct DirectoryItem: Decodable, Identifiable {
    let name: String
    let isDirectory: Bool
    var id: String { name }
}

struct DirectoryBrowser: View {
    @ObservedObject var model: BridgeModel
    let endpoint: BridgeEndpoint
    var choose: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @ViewState private var path: String
    @ViewState private var items: [DirectoryItem] = []
    @ViewState private var loadedPath: String?
    @ViewState private var issue = ""
    @ViewState private var revision = 0

    init(model: BridgeModel, endpoint: BridgeEndpoint, choose: ((String) -> Void)? = nil) {
        self.model = model
        self.endpoint = endpoint
        self.choose = choose
        let root = endpoint.root
        let initial = endpoint.kind == "baidu" ? "/" + (root.normalizedRemotePath ?? "") : (root.hasPrefix("/") ? root : "/")
        _path = State(initialValue: initial == "/" ? "/" : "/" + initial.split(separator: "/").joined(separator: "/"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(endpoint.name.isEmpty ? endpoint.host : endpoint.name).font(.title2.bold())
                Spacer()
                Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }.help("刷新")
            }
            HStack {
                Button { path = (path as NSString).deletingLastPathComponent } label: { Image(systemName: "chevron.up") }
                    .disabled(path == "/").help("上一级")
                Text(path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            List(items) { item in
                if item.isDirectory {
                    Button {
                        path = (path as NSString).appendingPathComponent(item.name)
                    } label: {
                        HStack { Label(item.name, systemImage: "folder"); Spacer(); Image(systemName: "chevron.right") }
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                } else { Label(item.name, systemImage: "doc").textSelection(.enabled) }
            }.overlay {
                if !issue.isEmpty { Text(issue).padding().textSelection(.enabled) }
                else if loadedPath != path { ProgressView() }
                else if items.isEmpty { Text("空文件夹").foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button(choose == nil ? "完成" : "取消") { dismiss() }.keyboardShortcut(.cancelAction)
                if let choose {
                    Button("选择此文件夹") {
                        choose(endpoint.kind == "baidu" ? String(path.dropFirst()) : path)
                        dismiss()
                    }.disabled(loadedPath != path || (endpoint.kind != "baidu" && path == "/"))
                }
            }
        }.padding(20).frame(width: 480, height: 390)
        .task(id: RequestKey(path: path, revision: revision)) {
            let requested = path
            items = []; issue = ""; loadedPath = nil
            var source = endpoint
            source.root = endpoint.kind == "baidu" ? String(requested.dropFirst()) : requested
            do {
                let reply = try await model.call(["op": "list", "endpoint": source.request()])
                try Task.checkCancellation()
                let data = try JSONSerialization.data(withJSONObject: reply["items"] ?? [])
                items = try JSONDecoder().decode([DirectoryItem].self, from: data)
                loadedPath = requested
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }

    private struct RequestKey: Hashable { let path: String; let revision: Int }
}
