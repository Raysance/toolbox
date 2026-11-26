import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published var errorMessage: String?

    private let service = SMAppService.loginItem(identifier: "com.local.BaiduDriveSync.Launcher")

    init() { refresh() }

    func refresh() {
        isEnabled = service.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            refresh()
        } catch {
            refresh()
            errorMessage = enabled
                ? "无法启用登录时启动：\(error.localizedDescription)"
                : "无法关闭登录时启动：\(error.localizedDescription)"
        }
    }
}
