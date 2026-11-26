import Foundation
import Network
import Security

public protocol IMAPTransport: AnyObject, Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    func receive(timeout: TimeInterval) async throws -> Data
    func close()
}

private final class Completion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    var timer: DispatchWorkItem?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        let pending = continuation; continuation = nil
        lock.unlock()
        guard let pending else { return false }
        timer?.cancel()
        pending.resume(with: result)
        return true
    }
}

/// Implicit TLS only. Network.framework performs normal system trust and hostname validation.
public final class TLSIMAPTransport: IMAPTransport, @unchecked Sendable {
    private let transport: FallbackIMAPTransport
    public init(host: String, port: UInt16) {
        transport = FallbackIMAPTransport { route in
            NetworkIMAPTransport(host: host, port: port, preferDirect: route == .preferDirect)
        }
    }
    public func connect() async throws {
        do { try await transport.connect() }
        catch is CancellationError { throw CancellationError() }
        catch { throw MailError.connectionFailed }
    }
    public func send(_ data: Data) async throws { try await transport.send(data) }
    public func receive(timeout: TimeInterval) async throws -> Data { try await transport.receive(timeout: timeout) }
    public func close() { transport.close() }
}

enum IMAPConnectionRoute: Sendable { case system, preferDirect }

/// Retry only before authentication. Never replay credentials or IMAP commands on a new route.
final class FallbackIMAPTransport: IMAPTransport, @unchecked Sendable {
    private let factory: @Sendable (IMAPConnectionRoute) -> any IMAPTransport
    private let lock = NSLock()
    private var active: (any IMAPTransport)?
    private var closed = false
    init(factory: @escaping @Sendable (IMAPConnectionRoute) -> any IMAPTransport) { self.factory = factory }

    func connect() async throws {
        for route in [IMAPConnectionRoute.system, .preferDirect] {
            try Task.checkCancellation()
            let attempt = factory(route)
            guard install(attempt) else { attempt.close(); throw CancellationError() }
            do {
                try await attempt.connect()
                try Task.checkCancellation()
                _ = try current()
                return
            } catch {
                attempt.close()
                try Task.checkCancellation()
                _ = try current() // A concurrent close must not start another connection.
                if error is CancellationError || route == .preferDirect { throw error }
            }
        }
    }
    func send(_ data: Data) async throws { try await current().send(data) }
    func receive(timeout: TimeInterval) async throws -> Data { try await current().receive(timeout: timeout) }
    func close() {
        lock.lock(); closed = true; let connection = active; lock.unlock()
        connection?.close()
    }
    private func install(_ transport: any IMAPTransport) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        active = transport; return true
    }
    private func current() throws -> any IMAPTransport {
        lock.lock(); defer { lock.unlock() }
        guard !closed, let active else { throw CancellationError() }
        return active
    }
}

private final class NetworkIMAPTransport: IMAPTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let connectTimeout: TimeInterval
    private let queue = DispatchQueue(label: "MailCode.IMAP", qos: .utility)
    init(host: String, port: UInt16, preferDirect: Bool) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 60; tcp.keepaliveInterval = 30; tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.preferNoProxies = preferDirect
        connectTimeout = preferDirect ? 12 : 8
        connection = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: parameters)
    }
    public func connect() async throws {
        try await perform(timeout: connectTimeout) { (finish: @escaping (Result<Void, Error>) -> Void) in
            self.connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let error): finish(.failure(error))
                case .cancelled: finish(.failure(CancellationError()))
                default: break
                }
            }
            self.connection.start(queue: self.queue)
        }
    }
    public func send(_ data: Data) async throws {
        try await perform(timeout: 20) { (finish: @escaping (Result<Void, Error>) -> Void) in
            self.connection.send(content: data, completion: .contentProcessed { error in
                if let error { finish(.failure(error)) } else { finish(.success(())) }
            })
        }
    }
    public func receive(timeout: TimeInterval) async throws -> Data {
        try await perform(timeout: timeout) { finish in
            self.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                if let data, !data.isEmpty { finish(.success(data)) }
                else { finish(.failure(error.map { $0 as Error } ?? MailError.disconnected)) }
            }
        }
    }
    public func close() { connection.cancel() }

    private func perform<T>(timeout: TimeInterval, operation: @escaping (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let completion = Completion<T>(continuation)
                let timer = DispatchWorkItem { [weak self, weak completion] in
                    if completion?.finish(.failure(MailError.timeout)) == true { self?.close() }
                }
                completion.timer = timer
                queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                operation { result in completion.finish(result) }
            }
        } onCancel: { self.close() }
    }
}

public struct IMAPFrame: Sendable {
    public let line: String
    public let literals: [Data]
}

/// A server literal is read by its byte count, never split at a newline or IMAP tag inside mail.
public final class IMAPWire {
    public let transport: IMAPTransport
    private var buffer = Data()
    public init(transport: IMAPTransport) { self.transport = transport }
    public func send(_ command: String) async throws { try await transport.send(Data((command + "\r\n").utf8)) }
    public func frame(timeout: TimeInterval = 30) async throws -> IMAPFrame {
        var line = try await readLine(timeout: timeout)
        var literals: [Data] = [], count = 0
        while let length = Self.literalLength(line) {
            guard length <= 524_288, count + length <= 1_048_576, literals.count < 16 else { throw MailError.responseTooLarge }
            while buffer.count < length { try await fill(timeout: timeout) }
            literals.append(Data(buffer.prefix(length)))
            buffer.removeFirst(length); count += length
            let suffix = try await readLine(timeout: timeout)
            line += " " + suffix
        }
        guard line.utf8.count <= 131_072 else { throw MailError.responseTooLarge }
        return IMAPFrame(line: line, literals: literals)
    }
    private func readLine(timeout: TimeInterval) async throws -> String {
        while true {
            if let range = buffer.range(of: Data([13, 10])) {
                let line = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                buffer.removeSubrange(..<range.upperBound)
                return line
            }
            guard buffer.count <= 131_072 else { throw MailError.responseTooLarge }
            try await fill(timeout: timeout)
        }
    }
    private func fill(timeout: TimeInterval) async throws {
        try Task.checkCancellation()
        let data = try await transport.receive(timeout: timeout)
        guard !data.isEmpty else { throw MailError.disconnected }
        guard buffer.count + data.count <= 1_114_112 else { throw MailError.responseTooLarge }
        buffer.append(data)
    }
    private static func literalLength(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let start = line.lastIndex(of: "{") else { return nil }
        return Int(line[line.index(after: start)..<line.index(before: line.endIndex)].replacingOccurrences(of: "+", with: ""))
    }
}
