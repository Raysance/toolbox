import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    var body: some View {
        Form {
            Section("启动") {
                Toggle(
                    "登录时启动并在后台运行",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
            }
        }.formStyle(.grouped)
        .alert("登录项设置失败", isPresented: Binding(
            get: { launchAtLogin.errorMessage != nil },
            set: { if !$0 { launchAtLogin.errorMessage = nil } }
        )) {
            Button("好") { launchAtLogin.errorMessage = nil }
        } message: {
            Text(launchAtLogin.errorMessage ?? "")
        }
    }

}
