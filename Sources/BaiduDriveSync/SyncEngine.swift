import Foundation

private enum FileSyncResult {
    case completed
    case uploaded(Int64)
    case skippedEmpty
    case failed(String)
}

private struct FileSyncSummary {
    private var skippedEmptyFiles = 0
    private(set) var progress = UploadProgress()
    private var firstFailure: String?

    mutating func record(_ result: FileSyncResult) {
        switch result {
        case .completed: break
        case .uploaded(let bytes):
            progress.files += 1
            progress.bytes += bytes
        case .skippedEmpty: skippedEmptyFiles += 1
        case .failed(let reason):
            progress.failures += 1
            if firstFailure == nil { firstFailure = reason }
        }
    }

    var outcome: MappingSyncOutcome {
        var details: [String] = []
        if skippedEmptyFiles > 0 { details.append("已跳过 \(skippedEmptyFiles) 个空文件") }
        if let firstFailure { details.append("\(progress.failures) 个文件失败：\(firstFailure)") }
        return MappingSyncOutcome(
            progress: progress,
            succeeded: progress.failures == 0,
            message: details.isEmpty ? "同步完成" : details.joined(separator: "；")
        )
    }
}

actor SyncEngine {
    private let client: BDPanClient
    private let ledger: SyncLedger
    private var remoteSnapshots: [String: [RemoteItem]] = [:]
    private var remoteSnapshotTasks: [String: Task<[RemoteItem], Error>] = [:]

    init(ledger: SyncLedger = .shared, client: BDPanClient = .shared) {
        self.client = client
        self.ledger = ledger
    }

    func sync(
        mapping: SyncMapping,
        maxConcurrentUploads: Int,
        onProgress: @escaping @Sendable (UploadProgress) async -> Void = { _ in },
        report: @escaping @Sendable (SyncEvent) async -> Void
    ) async -> MappingSyncOutcome {
        guard mapping.isEnabled else { return MappingSyncOutcome(succeeded: true, message: "映射已停用") }
        guard let remoteRoot = mapping.remotePath.normalizedRemotePath else {
            let message = "远程路径无效：\(mapping.remotePath)"
            await report(SyncEvent(kind: .failure, message: message))
            return MappingSyncOutcome(succeeded: false, message: message)
        }
        let localRoot = URL(fileURLWithPath: mapping.localPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localRoot.path, isDirectory: &isDirectory) else {
            let message = "本地路径不存在：\(localRoot.path)"
            await report(SyncEvent(kind: .failure, message: message))
            return MappingSyncOutcome(succeeded: false, message: message)
        }
        await report(SyncEvent(kind: .info, message: "开始同步 \(localRoot.lastPathComponent) → 我的应用数据/bdpan/\(remoteRoot)"))
        remoteSnapshots.removeAll(keepingCapacity: true)
        remoteSnapshotTasks.values.forEach { $0.cancel() }
        remoteSnapshotTasks.removeAll(keepingCapacity: true)
        do {
            var summary = FileSyncSummary()
            if isDirectory.boolValue {
                try await ensureDirectory(remoteRoot)
                summary = try await syncDirectory(
                    localRoot,
                    remoteRoot: remoteRoot,
                    maxConcurrentUploads: maxConcurrentUploads,
                    onProgress: onProgress,
                    report: report
                )
            } else {
                summary.record(await uploadIfMissing(localRoot, remotePath: join(remoteRoot, localRoot.lastPathComponent), report: report))
                await onProgress(summary.progress)
            }
            await ledger.flush()
            let outcome = summary.outcome
            await report(SyncEvent(kind: outcome.succeeded ? .success : .failure, message: "\(localRoot.lastPathComponent)：\(outcome.message)"))
            return outcome
        } catch {
            await ledger.flush()
            await report(SyncEvent(kind: .failure, message: "同步失败：\(error.localizedDescription)"))
            return MappingSyncOutcome(succeeded: false, message: error.localizedDescription)
        }
    }

    private func syncDirectory(
        _ localDirectory: URL,
        remoteRoot: String,
        maxConcurrentUploads: Int,
        onProgress: @escaping @Sendable (UploadProgress) async -> Void,
        report: @escaping @Sendable (SyncEvent) async -> Void
    ) async throws -> FileSyncSummary {
        let (directories, files) = try localEntries(localDirectory, remoteRoot: remoteRoot)
        for (_, remotePath) in directories.sorted(by: { $0.1.split(separator: "/").count < $1.1.split(separator: "/").count }) {
            try await ensureDirectory(remotePath)
        }

        let limit = min(8, max(1, maxConcurrentUploads))
        return await withTaskGroup(of: FileSyncResult.self) { group in
            var summary = FileSyncSummary()
            for entry in files.prefix(limit) {
                group.addTask { await self.uploadIfMissing(entry.0, remotePath: entry.1, report: report) }
            }
            var remaining = files.dropFirst(limit).makeIterator()
            while let result = await group.next() {
                summary.record(result)
                switch result {
                case .uploaded, .failed: await onProgress(summary.progress)
                case .completed, .skippedEmpty: break
                }
                if let entry = remaining.next() {
                    group.addTask { await self.uploadIfMissing(entry.0, remotePath: entry.1, report: report) }
                }
            }
            return summary
        }
    }

    private func localEntries(_ localDirectory: URL, remoteRoot: String) throws -> (directories: [(URL, String)], files: [(URL, String)]) {
        var directories: [(URL, String)] = []
        var files: [(URL, String)] = []
        let rootComponents = localDirectory.standardizedFileURL.pathComponents
        for itemURL in try Self.enumeratedURLs(in: localDirectory) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            let values = try itemURL.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { continue }
            let components = itemURL.standardizedFileURL.pathComponents
            guard components.starts(with: rootComponents), components.count > rootComponents.count else {
                throw AppError.commandFailed("无法确定文件相对于本机文件夹的路径。")
            }
            let relative = components.dropFirst(rootComponents.count).joined(separator: "/")
            let remote = join(remoteRoot, relative)
            if values.isDirectory == true { directories.append((itemURL, remote)) }
            else if values.isRegularFile == true { files.append((itemURL, remote)) }
        }

        return (directories, files)
    }

    private var previewDirectories: [String: Bool] = ["": true]
    private func directoryExists(_ path: String) async throws -> Bool {
        if let value = previewDirectories[path] { return value }
        let parent = parentPath(path)
        var value = false
        if try await directoryExists(parent) {
            let children = try await remoteItems(in: parent)
            if let row = children.first(where: { $0.name == URL(fileURLWithPath: path).lastPathComponent }) {
                guard row.isDirectory else { throw AppError.commandFailed("远端同名项不是文件夹：" + path) }
                value = true
            }
        }
        previewDirectories[path] = value
        return value
    }

    func preview(mapping: SyncMapping, progress: @Sendable (Int) async -> Void) async throws -> UploadPreview {
        guard let root = mapping.remotePath.normalizedRemotePath else { throw AppError.invalidRemotePath }
        let local = URL(fileURLWithPath: mapping.localPath).standardizedFileURL
        previewDirectories = ["": true]
        remoteSnapshots.removeAll()
        let entries = try localEntries(local, remoteRoot: root)
        var result = UploadPreview()
        var names: [String: Set<String>] = [:]
        var lastUpdate = Date.distantPast
        for (url, remote) in entries.files {
            result.checked += 1
            if Date().timeIntervalSince(lastUpdate) >= 0.25 {
                await progress(result.checked)
                lastUpdate = Date()
            }
            if await ledger.contains(localURL: url, remotePath: remote) { continue }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size else { throw AppError.commandFailed("无法读取文件大小：" + url.lastPathComponent) }
            if size == 0 { continue }
            let parent = parentPath(remote)
            if names[parent] == nil {
                if try await directoryExists(parent) {
                    names[parent] = Set(try await remoteItems(in: parent).map(\.name))
                } else { names[parent] = [] }
            }
            if names[parent]?.contains(url.lastPathComponent) == true { continue }
            let path = root.isEmpty ? remote : String(remote.dropFirst(root.count + 1))
            result.files.append(.init(path: path, size: Int64(size)))
        }
        result.files.sort { $0.path < $1.path }
        return result
    }

    nonisolated private static func enumeratedURLs(in directory: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey]
        var readError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in readError = error; return false }
        ) else { throw AppError.commandFailed("无法读取本机目录：" + directory.path) }
        var result: [URL] = []
        while let value = enumerator.nextObject() as? URL {
            if (try? value.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                enumerator.skipDescendants()
                continue
            }
            result.append(value)
        }
        if let readError { throw readError }
        return result
    }

    private func ensureDirectory(_ path: String) async throws {
        guard !path.isEmpty else { return }
        if await ledger.knowsDirectory(path) { return }
        let parent = parentPath(path)
        let name = URL(fileURLWithPath: path).lastPathComponent
        let items = try await remoteItems(in: parent)
        if let existing = items.first(where: { $0.name == name }) {
            if !existing.isDirectory { throw AppError.commandFailed("远端同名项不是文件夹：\(path)") }
            await ledger.markDirectoryKnown(path)
            return
        }
        try await client.createDirectory(path)
        await ledger.markDirectoryKnown(path)
    }

    private func uploadIfMissing(_ localURL: URL, remotePath: String, report: @escaping @Sendable (SyncEvent) async -> Void) async -> FileSyncResult {
        if await ledger.contains(localURL: localURL, remotePath: remotePath) { return .completed }
        do {
            try localURL.requireNonemptyFileForUpload()
            let parent = parentPath(remotePath)
            try await ensureDirectory(parent)
            let items = try await remoteItems(in: parent)
            if items.contains(where: { $0.name == localURL.lastPathComponent }) {
                await ledger.markUploaded(localURL: localURL, remotePath: remotePath)
                await report(SyncEvent(kind: .warning, message: "已存在，跳过：\(remotePath)"))
                return .completed
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            try await client.upload(localURL: localURL, to: remotePath)
            await ledger.markUploaded(localURL: localURL, remotePath: remotePath)
            await report(SyncEvent(kind: .success, message: "已上传：\(remotePath)"))
            return .uploaded(bytes)
        } catch AppError.emptyLocalFile(_) {
            await report(SyncEvent(kind: .warning, message: "已跳过空文件（0 字节）：\(remotePath)"))
            return .skippedEmpty
        } catch {
            let reason = error.localizedDescription
            await report(SyncEvent(kind: .failure, message: "文件同步失败：\(remotePath)（\(reason)）"))
            return .failed(reason)
        }
    }

    private func remoteItems(in path: String) async throws -> [RemoteItem] {
        if let cached = remoteSnapshots[path] { return cached }
        if let existingTask = remoteSnapshotTasks[path] { return try await existingTask.value }
        let client = self.client
        let task = Task { try await client.list(path) }
        remoteSnapshotTasks[path] = task
        do {
            let items = try await task.value
            remoteSnapshots[path] = items
            remoteSnapshotTasks[path] = nil
            return items
        } catch {
            remoteSnapshotTasks[path] = nil
            throw error
        }
    }

    private func join(_ lhs: String, _ rhs: String) -> String {
        [lhs, rhs].filter { !$0.isEmpty }.joined(separator: "/")
    }

    private func parentPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.dropLast().joined(separator: "/")
    }
}
