import AppKit
import SwiftUI

typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct BaiduDriveSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var bridge = AppServices.shared.bridge

    var body: some Scene {
        Settings {
            SettingsView(launchAtLogin: AppServices.shared.launchAtLogin).frame(width: 420, height: 110)
        }

        MenuBarExtra(
            "FolderBridge 文件桥",
            systemImage: !bridge.running.isEmpty ? "arrow.triangle.2.circlepath" : "externaldrive.fill.badge.icloud"
        ) {
            StatusMenuView(bridge: bridge)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct StatusMenuView: View {
    @ObservedObject var bridge: BridgeModel

    var body: some View {
        Button("打开FolderBridge 文件桥") {
            AppDelegate.shared?.showMainWindow()
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Menu("同步") {
            ForEach(bridge.rules) { rule in
                Button(URL(fileURLWithPath: rule.local.root).lastPathComponent + (rule.uploadsOnly ? " → " : " ↔ ") + rule.remote.name + "/" + rule.remote.root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) {
                    AppDelegate.shared?.showMainWindow()
                    Task { await bridge.sync(rule) }
                }.disabled(bridge.running.contains(rule.id))
            }
        }.disabled(bridge.rules.isEmpty)
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出FolderBridge 文件桥") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}

@MainActor
final class AppServices {
    static let shared = AppServices()
    let network = NetworkState()
    let launchAtLogin = LaunchAtLoginManager()
    let bridge = BridgeModel()
    private let scheduler: BridgeScheduler

    private init() {
        let network = self.network
        scheduler = BridgeScheduler(bridge: bridge) { rule in
            network.isOnline && (!network.isHotspotLike || rule.settings.allowMetered)
        }
    }
}
