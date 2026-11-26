import Foundation

struct RemoteItem: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let size: Int64
    let isDirectory: Bool
    let createdAt: Date?
    let modifiedAt: Date?
    let md5: String?
    let returnURL: URL?
}

struct AccountState: Sendable {
    let isLoggedIn: Bool
    let label: String
}

struct SyncMapping: Identifiable, Codable, Hashable {
    var id = UUID()
    var localPath: String
    var remotePath: String
    var isEnabled = true
    var lastSyncAt: Date?
    var lastSyncSucceeded: Bool?
    var lastSyncMessage: String?
}

struct UploadPreview: Codable, Sendable {
    struct File: Codable, Identifiable, Sendable {
        let path: String
        let size: Int64
        var id: String { path }
    }
    var checked = 0
    var files: [File] = []
    var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    static func format(_ bytes: Int64) -> String {
        bytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct UploadProgress: Sendable {
    var files = 0
    var bytes: Int64 = 0
    var failures = 0

    var description: String {
        let completed = "已上传 \(files) 个 · \(UploadPreview.format(bytes))"
        return failures == 0 ? completed : completed + " · \(failures) 个失败"
    }
}

struct MappingSyncOutcome: Sendable {
    var progress = UploadProgress()
    let succeeded: Bool
    let message: String
}

struct AppSettings: Codable {
    var mappings: [SyncMapping] = []
    var intervalMinutes = 30
    var syncOnHotspot = false
    var maxConcurrentUploads = 4

    init(
        mappings: [SyncMapping] = [],
        intervalMinutes: Int = 30,
        syncOnHotspot: Bool = false,
        maxConcurrentUploads: Int = 4
    ) {
        self.mappings = mappings
        self.intervalMinutes = intervalMinutes
        self.syncOnHotspot = syncOnHotspot
        self.maxConcurrentUploads = maxConcurrentUploads
    }

    private enum CodingKeys: String, CodingKey {
        case mappings, intervalMinutes, syncOnHotspot, maxConcurrentUploads
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mappings = try container.decodeIfPresent([SyncMapping].self, forKey: .mappings) ?? []
        intervalMinutes = min(1440, max(1, try container.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 30))
        syncOnHotspot = try container.decodeIfPresent(Bool.self, forKey: .syncOnHotspot) ?? false
        maxConcurrentUploads = min(8, max(1, try container.decodeIfPresent(Int.self, forKey: .maxConcurrentUploads) ?? 4))
    }
}

struct SyncEvent: Identifiable {
    enum Kind { case info, success, warning, failure }
    let id = UUID()
    let date = Date()
    let kind: Kind
    let message: String
}

enum AppError: LocalizedError {
    case cliNotFound
    case invalidRemotePath
    case emptyLocalFile(String)
    case commandFailed(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "没有找到 bdpan。请先安装 baidu-drive skill 提供的命令行工具。"
        case .invalidRemotePath:
            return "远程路径无效。只能使用“我的应用数据/bdpan”内的相对路径，且不能包含 .. 或 ~。"
        case .emptyLocalFile(let name):
            return "无法上传 0 字节文件：\(name)"
        case .commandFailed(let message): return message
        case .malformedResponse: return "bdpan 返回了无法识别的数据。"
        }
    }
}

extension URL {
    func requireNonemptyFileForUpload() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        if attributes[.type] as? FileAttributeType == .typeRegular,
           (attributes[.size] as? NSNumber)?.int64Value == 0 {
            throw AppError.emptyLocalFile(lastPathComponent)
        }
    }
}

extension String {
    var normalizedRemotePath: String? {
        var value = trimmingCharacters(in: .whitespacesAndNewlines)
        let visiblePrefix = "我的应用数据/bdpan/"
        let apiPrefix = "/apps/bdpan/"
        if value == "我的应用数据/bdpan" || value == "/apps/bdpan" { return "" }
        if value.hasPrefix(visiblePrefix) { value.removeFirst(visiblePrefix.count) }
        if value.hasPrefix(apiPrefix) { value.removeFirst(apiPrefix.count) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = value.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(".."), !components.contains("~"), !value.hasPrefix("/") else { return nil }
        return components.joined(separator: "/")
    }
}
