import Foundation
import Network

public struct IMAPNetworkSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case direct, system, socks5, http }
    public var mode: Mode
    public var proxyHost: String
    public var proxyPort: UInt16
    public init(mode: Mode = .direct, proxyHost: String = "127.0.0.1", proxyPort: UInt16 = 7897) {
        self.mode = mode; self.proxyHost = proxyHost; self.proxyPort = proxyPort
    }
    public func validate() throws {
        guard mode == .socks5 || mode == .http else { return }
        guard !proxyHost.isEmpty, proxyPort > 0, !proxyHost.contains("/"), !proxyHost.contains("@"),
              !proxyHost.contains(where: { $0.isWhitespace || $0.isNewline }),
              !proxyHost.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MailError.invalidProxyConfiguration
        }
        guard #available(macOS 14, *) else { throw MailError.proxyRequiresNewerOS }
    }
    func apply(to parameters: NWParameters) throws {
        try validate()
        parameters.preferNoProxies = mode == .direct
        if mode == .socks5 || mode == .http {
            if #available(macOS 14, *) {
                let endpoint = NWEndpoint.hostPort(host: .init(proxyHost), port: .init(rawValue: proxyPort)!)
                var proxy = mode == .socks5 ? ProxyConfiguration(socksv5Proxy: endpoint) : ProxyConfiguration(httpCONNECTProxy: endpoint)
                proxy.allowFailover = false
                let context = NWParameters.PrivacyContext(description: "InboxCode proxy")
                context.proxyConfigurations = [proxy]
                parameters.setPrivacyContext(context)
            }
        }
    }
}
