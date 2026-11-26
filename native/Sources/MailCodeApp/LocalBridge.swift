import Foundation
import AppKit
import Darwin
import MailCodeCore

/// Per-user Unix socket. No TCP listener, shell commands, or credential logging.
final class LocalBridge: @unchecked Sendable {
    private let descriptor: Int32
    private let path: String
    private let lock = NSLock()
    private var stopped = false
    private let handler: @Sendable (Data) async -> Data

    init(handler: @escaping @Sendable (Data) async -> Data) throws {
        self.handler = handler
        let directory = ConfigurationStore().directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        path = directory.appendingPathComponent("bridge.sock").path
        guard path.utf8.count < 104 else { throw MailError.invalidConfiguration }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFSOCK else { throw MailError.commandRejected("creating the local connection") }
            unlink(path)
        }
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MailError.disconnected }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            Array(path.utf8).withUnsafeBytes { buffer.copyBytes(from: $0) }
        }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard status == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor); unlink(path); throw MailError.disconnected
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.acceptConnections() }
    }
    func stop() {
        lock.lock(); let wasStopped = stopped; stopped = true; lock.unlock()
        guard !wasStopped else { return }
        shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor); unlink(path)
    }
    private func acceptConnections() {
        while true {
            lock.lock(); let done = stopped; lock.unlock()
            if done { return }
            let client = accept(descriptor, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            let handler = handler
            DispatchQueue.global(qos: .utility).async {
                var timeout = timeval(tv_sec: 5, tv_usec: 0), noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var request = Data(), bytes = [UInt8](repeating: 0, count: 4096)
                while request.count <= 65_536 {
                    let count = Darwin.read(client, &bytes, bytes.count)
                    guard count > 0 else { Darwin.close(client); return }
                    request.append(contentsOf: bytes.prefix(count))
                    if let newline = request.firstIndex(of: 10) {
                        let payload = Data(request[..<newline])
                        Task {
                            var response = await handler(payload); response.append(10)
                            DispatchQueue.global(qos: .utility).async {
                                response.withUnsafeBytes { buffer in
                                    var offset = 0
                                    while offset < buffer.count {
                                        let written = Darwin.write(client, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                                        if written <= 0 { break }; offset += written
                                    }
                                }
                                Darwin.close(client)
                            }
                        }
                        return
                    }
                }
                Darwin.close(client)
            }
        }
    }
}

struct BridgeRequest: Decodable {
    let action: String
    var account: MailAccount?
    var password: String?
    var id: String?
    var value: Bool?
    var network: IMAPNetworkSettings?
}
struct BridgeAccount: Encodable {
    let account: MailAccount
    let online: Bool
    let error: String?
    let lookupState: LookupPhase
    let cacheReady: Bool
    let fetchedMessages: Int
}
struct BridgeResponse: Encodable {
    var accounts: [BridgeAccount] = []
    var codes: [LatestCode] = []
    var paused = false
    var autoCopy = true
    var showPopup = true
    var launchAtLogin = false
    var error: String?
}

extension AppModel {
    func bridgeResponse(error: String? = nil) -> BridgeResponse {
        BridgeResponse(accounts: accounts.map { BridgeAccount(account: $0, online: online.contains($0.id), error: lookupErrors[$0.id],
                       lookupState: lookupPhases[$0.id] ?? .idle, cacheReady: lookupCache[$0.id]?.initialized ?? false,
                       fetchedMessages: lookupFetched[$0.id] ?? 0) },
                       codes: locked ? [] : latestCodes.values.sorted { $0.receivedAt > $1.receivedAt }, paused: paused,
                       autoCopy: preferences.autoCopy, showPopup: preferences.showPopup, launchAtLogin: launchAtLogin, error: error)
    }
    func handleBridge(_ data: Data) async -> Data {
        let result: BridgeResponse
        do {
            guard !locked else { throw MailError.commandRejected("access while locked") }
            let request = try JSONDecoder().decode(BridgeRequest.self, from: data)
            if request.action != "list" && request.action != "refresh" { errorMessage = nil }
            if let network = request.network { try await setNetwork(network) }
            switch request.action {
            case "list": break
            case "refresh": await refreshLatest(force: request.value ?? false)
            case "save":
                guard let account = request.account else { throw MailError.invalidConfiguration }
                let password: String
                if let supplied = request.password, !supplied.isEmpty { password = supplied }
                else { password = try Keychain.read(account.id) }
                try await test(account: account, password: password)
                try saveAccount(account, password: password)
            case "remove":
                guard let value = request.id, let id = UUID(uuidString: value) else { throw MailError.invalidConfiguration }
                removeAccount(id)
                if let errorMessage { throw NSError(domain: "MailCode", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage]) }
            case "copy":
                guard let id = request.id, let record = latestCodes.values.first(where: { $0.id == id }) else { throw MailError.commandRejected("copying an unavailable code") }
                // Explicit manual copy is allowed even for older mail; Raycast displays its age.
                guard copy(CodeEvent(code: record.code, sender: record.provider, account: record.account, kind: record.kind ?? .code)) else { throw MailError.commandRejected("copying") }
            case "autoCopy": updatePreferences { $0.autoCopy = request.value ?? true }
            case "showPopup": updatePreferences { $0.showPopup = request.value ?? true }
            case "launchAtLogin": setLogin(request.value ?? false)
            case "pause": if paused != (request.value ?? false) { togglePause() }
            case "quit":
                stop(); clearOwnedClipboard(); onHidePopup?()
                // Return the RPC response before terminating the helper.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            case "enable":
                guard let value = request.id, let id = UUID(uuidString: value) else { throw MailError.invalidConfiguration }
                enableAccount(id, enabled: request.value ?? true)
            default: throw MailError.invalidConfiguration
            }
            if request.action != "list" && request.action != "refresh", let errorMessage {
                throw NSError(domain: "MailCode", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }
            result = bridgeResponse()
        } catch { result = bridgeResponse(error: error.localizedDescription) }
        return (try? JSONEncoder().encode(result)) ?? Data("{\"error\":\"Local connection failed\"}".utf8)
    }
}
