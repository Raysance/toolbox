import Foundation
import Network

@MainActor
final class NetworkState: ObservableObject {
    @Published private(set) var isOnline = true
    @Published private(set) var isHotspotLike = false
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isOnline = path.status == .satisfied
                self?.isHotspotLike = path.isExpensive || path.isConstrained
            }
        }
        monitor.start(queue: DispatchQueue(label: "BaiduDriveSync.Network"))
    }

    deinit { monitor.cancel() }
}
