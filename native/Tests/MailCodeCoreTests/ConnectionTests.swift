import Foundation
import Testing
import Network
@testable import MailCodeCore

private final class ConnectionStub: IMAPTransport, @unchecked Sendable {
    let failure: MailError?
    let stall: Bool
    private let lock = NSLock()
    private var connects = 0
    private var closes = 0
    private var writes: [Data] = []
    init(failure: MailError? = nil, stall: Bool = false) { self.failure = failure; self.stall = stall }
    var counts: (connects: Int, closes: Int, writes: Int) {
        lock.lock(); defer { lock.unlock() }; return (connects, closes, writes.count)
    }
    private func recordConnect() { lock.lock(); connects += 1; lock.unlock() }
    private func recordWrite(_ data: Data) { lock.lock(); writes.append(data); lock.unlock() }
    func connect() async throws { recordConnect(); if let failure { throw failure } }
    func send(_ data: Data) async throws { recordWrite(data) }
    func receive(timeout: TimeInterval) async throws -> Data {
        if stall { try await Task.sleep(nanoseconds: 60_000_000_000) }
        return Data("* OK test ready\r\n".utf8)
    }
    func close() { lock.lock(); closes += 1; lock.unlock() }
}

struct ConnectionTests {
    @Test func directIsDefaultAndIgnoresSystemProxies() throws {
        let settings = IMAPNetworkSettings()
        let parameters = NWParameters.tcp
        try settings.apply(to: parameters)
        #expect(settings.mode == .direct)
        #expect(parameters.preferNoProxies)
        try IMAPNetworkSettings(mode: .system).apply(to: parameters)
        #expect(!parameters.preferNoProxies)
    }
    @Test func networkSettingsRoundtripAndValidation() throws {
        let settings = IMAPNetworkSettings(mode: .socks5, proxyHost: "localhost", proxyPort: 1080)
        #expect(try JSONDecoder().decode(IMAPNetworkSettings.self, from: JSONEncoder().encode(settings)) == settings)
        for host in ["", "http://localhost", "a@b", "host name", "bad\n"] {
            #expect(throws: MailError.invalidProxyConfiguration) { try IMAPNetworkSettings(mode: .socks5, proxyHost: host).validate() }
        }
        #expect(throws: MailError.invalidProxyConfiguration) { try IMAPNetworkSettings(mode: .http, proxyPort: 0).validate() }
    }
    @Test func selectedRouteDoesNotFallBack() async {
        for route in [IMAPConnectionRoute.system, .preferDirect] {
            let failed = ConnectionStub(failure: .timeout), other = ConnectionStub()
            let transport = FallbackIMAPTransport(routes: [route]) { $0 == route ? failed : other }
            do { try await transport.connect(); Issue.record("Expected failure") }
            catch { #expect(error as? MailError == .timeout) }
            #expect(failed.counts.connects == 1 && failed.counts.closes == 1 && other.counts.connects == 0)
        }
    }
    @Test func brokenProxyFallsBackBeforeSendingCredentials() async throws {
        let proxy = ConnectionStub(failure: .timeout), direct = ConnectionStub()
        let transport = FallbackIMAPTransport { $0 == .system ? proxy : direct }
        try await transport.connect()
        try await transport.send(Data("CAPABILITY\r\n".utf8))
        #expect(proxy.counts.connects == 1 && proxy.counts.closes == 1 && proxy.counts.writes == 0)
        #expect(direct.counts.connects == 1 && direct.counts.writes == 1)
        transport.close()
        #expect(direct.counts.closes == 1)
    }
    @Test func workingProxyDoesNotOpenDirectConnection() async throws {
        let proxy = ConnectionStub(), direct = ConnectionStub()
        let transport = FallbackIMAPTransport { $0 == .system ? proxy : direct }
        try await transport.connect(); transport.close()
        #expect(proxy.counts.connects == 1 && direct.counts.connects == 0)
    }
    @Test func failedAttemptsAreClosed() async {
        let proxy = ConnectionStub(failure: .disconnected), direct = ConnectionStub(failure: .timeout)
        let transport = FallbackIMAPTransport { $0 == .system ? proxy : direct }
        do { try await transport.connect(); Issue.record("Expected failure") }
        catch { #expect(error as? MailError == .timeout) }
        #expect(proxy.counts.closes == 1 && direct.counts.closes == 1)
    }
    @Test func closePreventsConnectionAndFallback() async {
        let proxy = ConnectionStub(failure: .timeout), direct = ConnectionStub()
        let transport = FallbackIMAPTransport { $0 == .system ? proxy : direct }
        transport.close()
        do { try await transport.connect(); Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(proxy.counts.connects == 0 && direct.counts.connects == 0)
    }
    @Test func bindingDeadlineClosesSilentServer() async {
        let transport = ConnectionStub(stall: true)
        let session = IMAPSession(transport: transport)
        do {
            _ = try await session.open(account: MailAccount(username: "test@example.com", host: "imap.example.com"), password: "test", timeout: 0.03)
            Issue.record("Expected timeout")
        } catch { #expect(error as? MailError == .timeout) }
        #expect(transport.counts.closes >= 1)
    }
}
