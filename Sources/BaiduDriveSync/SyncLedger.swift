import Foundation

private struct UploadedFileRecord: Codable, Hashable {
    let localPath: String
    let remotePath: String
}

private struct SyncLedgerData: Codable {
    var uploadedFiles: Set<UploadedFileRecord> = []
    var knownRemoteDirectories: Set<String> = []
}

actor SyncLedger {
    static let shared = SyncLedger()

    private let fileURL: URL
    private var data: SyncLedgerData
    private var isDirty = false

    init(fileURL customFileURL: URL? = nil) {
        if let customFileURL {
            fileURL = customFileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BaiduDriveSync", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            fileURL = base.appendingPathComponent("sync-ledger.json")
        }
        if let encoded = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(SyncLedgerData.self, from: encoded) {
            data = decoded
        } else {
            data = SyncLedgerData()
        }
    }

    func contains(localURL: URL, remotePath: String) -> Bool {
        data.uploadedFiles.contains(
            UploadedFileRecord(localPath: localURL.standardizedFileURL.path, remotePath: remotePath)
        )
    }

    func markUploaded(localURL: URL, remotePath: String) {
        let inserted = data.uploadedFiles.insert(
            UploadedFileRecord(localPath: localURL.standardizedFileURL.path, remotePath: remotePath)
        ).inserted
        isDirty = isDirty || inserted
    }

    func knowsDirectory(_ remotePath: String) -> Bool {
        remotePath.isEmpty || data.knownRemoteDirectories.contains(remotePath)
    }

    func markDirectoryKnown(_ remotePath: String) {
        guard !remotePath.isEmpty else { return }
        let inserted = data.knownRemoteDirectories.insert(remotePath).inserted
        isDirty = isDirty || inserted
    }

    func flush() {
        guard isDirty, let encoded = try? JSONEncoder().encode(data) else { return }
        do {
            try encoded.write(to: fileURL, options: .atomic)
            isDirty = false
        } catch {
            // A failed ledger write must never turn a successful upload into a failed sync.
        }
    }
}
