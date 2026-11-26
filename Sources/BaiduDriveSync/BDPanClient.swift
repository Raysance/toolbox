import AppKit
import Dispatch
import Foundation

final class BDPanClient: @unchecked Sendable {
    static let shared = BDPanClient()
    private let sessionID: String

    let profileDirectory: URL?
    init(profileDirectory: URL? = nil) {
        self.profileDirectory = profileDirectory
        let suffix = String(UUID().uuidString.lowercased().filter(\.isLetter).prefix(6))
        sessionID = "\(Int(Date().timeIntervalSince1970))-\(suffix)"
    }

    private func profileConfig() throws -> String? {
        guard let profileDirectory else { return nil }
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return profileDirectory.appendingPathComponent("config.json").path
    }

    func executableURL() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/bdpan").path {
            candidates.append(bundled)
        }
        candidates += ["\(home)/.local/bin/bdpan", "/opt/homebrew/bin/bdpan", "/usr/local/bin/bdpan"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AppError.cliNotFound
        }
        return URL(fileURLWithPath: path)
    }

    private func run(_ command: String, _ arguments: [String], json: Bool = true) async throws -> Data {
        let process = Process()
        defer { withExtendedLifetime(process) {} }
        let executable = try executableURL()
        process.executableURL = executable
        var args = [command] + arguments
        if json { args.append("--json") }
        if executable.path == Bundle.main.resourceURL?.appendingPathComponent("bin/bdpan").path {
            args.append("--no-check-update")
        }
        args += ["--agentname", "FolderBridge-macOS", "--session-id", sessionID]
        if let path = try profileConfig() { args += ["--config-path", path] }
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let (exitCodes, exitCode) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingOldest(1))
        process.terminationHandler = { finished in
            exitCode.yield(finished.terminationStatus)
            exitCode.finish()
        }
        try process.run()
        async let output = Self.readOutput(stdout.fileHandleForReading)
        async let diagnostics = Self.readOutput(stderr.fileHandleForReading)
        let (out, err) = try await (output, diagnostics)
        var statuses = exitCodes.makeAsyncIterator()
        guard let status = await statuses.next() else { throw CancellationError() }
        guard status == 0 else {
            let message = String(data: err.isEmpty ? out : err, encoding: .utf8) ?? "命令执行失败"
            throw AppError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }

    private static func readOutput(_ handle: FileHandle) async throws -> Data {
        var output = Data()
        while true {
            let chunk = try await readChunk(from: handle)
            if chunk.isEmpty { return output }
            output.append(chunk)
        }
    }

    private static func readChunk(from handle: FileHandle) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchIO.read(
                fromFileDescriptor: handle.fileDescriptor,
                maxLength: 64 * 1024,
                runningHandlerOn: .global(qos: .utility)
            ) { data, error in
                withExtendedLifetime(handle) {
                    if error != 0 {
                        continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO))
                    } else {
                        continuation.resume(returning: Data(data))
                    }
                }
            }
        }
    }

    func loginStatus() async -> AccountState {
        do {
            let data = try await run("whoami", [])
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["authenticated"] as? Bool == true {
                return AccountState(isLoggedIn: true, label: object["username"] as? String ?? "已登录")
            }
            let plain = Self.removeTerminalControlCodes(String(data: data, encoding: .utf8) ?? "")
            let loggedIn = plain.contains("已登录") && !plain.contains("未登录")
            return AccountState(isLoggedIn: loggedIn, label: loggedIn ? "已登录" : "未登录")
        } catch {
            return AccountState(isLoggedIn: false, label: "无法检查登录状态")
        }
    }

    private static func removeTerminalControlCodes(_ value: String) -> String {
        value.replacingOccurrences(of: #"\u{001B}\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }

    @MainActor
    func openLoginTerminal() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("baidu-drive/scripts/login.sh").path {
            candidates.append(bundled)
        }
        if profileDirectory == nil {
            candidates += [
                "\(home)/.codex/skills/baidu-drive/scripts/login.sh",
                "\(home)/.agents/skills/baidu-drive/scripts/login.sh"
            ]
        }
        guard let script = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0) }) else {
            throw AppError.commandFailed("没有找到 baidu-drive skill 的 login.sh。请先安装该 skill。")
        }
        let quoted = script.replacingOccurrences(of: "'", with: "'\\''")
        let binDirectory = Bundle.main.resourceURL?.appendingPathComponent("bin").path ?? ""
        let quotedBin = binDirectory.replacingOccurrences(of: "'", with: "'\\''")
        var shellCommand = "PATH='\(quotedBin):/usr/bin:/bin:/usr/sbin:/sbin' bash '\(quoted)'"
        if let path = try profileConfig() {
            shellCommand += " --config-path '" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let escapedCommand = shellCommand.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "tell application \"Terminal\" to do script \"\(escapedCommand)\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", appleScript]
        try task.run()
    }

    func list(_ remotePath: String) async throws -> [RemoteItem] {
        guard let path = remotePath.normalizedRemotePath else { throw AppError.invalidRemotePath }
        let data = try await run("ls", path.isEmpty ? [] : [path])
        let object = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let array = object as? [[String: Any]] { rows = array }
        else if let dict = object as? [String: Any], let items = dict["items"] as? [[String: Any]] { rows = items }
        else { throw AppError.malformedResponse }
        let items = rows.compactMap(Self.remoteItem)
        guard !path.isEmpty else { return items }
        let requestedAPIPath = "/apps/bdpan/\(path)".trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return items.filter {
            $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != requestedAPIPath
        }
    }

    private static func remoteItem(_ row: [String: Any]) -> RemoteItem? {
        guard let name = row["server_filename"] as? String,
              let path = row["path"] as? String else { return nil }
        let fsid = (row["fsid"] as? String) ?? String(describing: row["fs_id"] ?? path)
        let size = (row["size"] as? NSNumber)?.int64Value ?? 0
        let isDirectory = (row["isdir"] as? Bool) ?? ((row["isdir"] as? NSNumber)?.boolValue ?? false)
        let createdText = row["server_ctime"] as? String
        let dateText = row["server_mtime"] as? String
        let created = createdText.flatMap { ISO8601DateFormatter().date(from: $0) }
        let date = dateText.flatMap { ISO8601DateFormatter().date(from: $0) }
        let md5 = (row["md5"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let url = (row["return_url"] as? String).flatMap(URL.init(string:))
        return RemoteItem(
            id: fsid,
            name: name,
            path: path,
            size: size,
            isDirectory: isDirectory,
            createdAt: created,
            modifiedAt: date,
            md5: md5,
            returnURL: url
        )
    }

    func createDirectory(_ remotePath: String) async throws {
        guard let path = remotePath.normalizedRemotePath, !path.isEmpty else { throw AppError.invalidRemotePath }
        _ = try await run("mkdir", [path])
    }

    func rename(_ remotePath: String, to newName: String) async throws {
        guard let path = remotePath.normalizedRemotePath,
              !path.isEmpty,
              !newName.isEmpty,
              newName.normalizedRemotePath == newName,
              !newName.contains("/") else { throw AppError.invalidRemotePath }
        _ = try await run("rename", [path, newName])
    }

    func move(_ remotePath: String, to directory: String) async throws {
        guard let path = remotePath.normalizedRemotePath,
              let target = directory.normalizedRemotePath,
              !path.isEmpty else { throw AppError.invalidRemotePath }
        _ = try await run("mv", [path, target])
    }

    func delete(_ remotePath: String) async throws {
        guard let path = remotePath.normalizedRemotePath, !path.isEmpty else { throw AppError.invalidRemotePath }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(6)
        let directories = ["_FolderBridgeHistory", "_FolderBridgeHistory/manual", "_FolderBridgeHistory/manual/\(stamp)"]
        for directory in directories {
            do { _ = try await run("mkdir", [directory]) }
            catch {
                let message = error.localizedDescription.lowercased()
                guard message.contains("exist") || message.contains("已存在") || message.contains("31061") else { throw error }
            }
        }
        _ = try await run("mv", [path, directories.last!])
    }

    func upload(localURL: URL, to remotePath: String) async throws {
        guard let path = remotePath.normalizedRemotePath, !path.isEmpty else { throw AppError.invalidRemotePath }
        try localURL.requireNonemptyFileForUpload()
        do {
            _ = try await run("upload", [localURL.path, path])
        } catch AppError.commandFailed(let details) {
            let response = try? JSONSerialization.jsonObject(with: Data(details.utf8)) as? [String: Any]
            let message = (response?["error"] as? String) ?? details
            if message == "不支持上传空文件" {
                throw AppError.emptyLocalFile(localURL.lastPathComponent)
            }
            throw AppError.commandFailed(message)
        }
    }

    func download(_ remotePath: String, to localURL: URL) async throws {
        guard let path = remotePath.normalizedRemotePath, !path.isEmpty else { throw AppError.invalidRemotePath }
        _ = try await run("download", [path, localURL.path])
    }
}
