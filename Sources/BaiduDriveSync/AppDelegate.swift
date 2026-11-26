import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        _ = AppServices.shared
        if !CommandLine.arguments.contains("--background") { showMainWindow() }
    }

    func showMainWindow() {
        if mainWindow == nil {
            let view = FolderBridgeView()
                .environmentObject(AppServices.shared.bridge)

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "FolderBridge 文件桥"
            window.contentViewController = NSHostingController(rootView: view)
            window.contentMinSize = NSSize(width: 520, height: 360)
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1040, height: 680)
            window.setContentSize(NSSize(width: min(1040, visible.width - 24), height: min(620, visible.height - 60)))
            window.isReleasedWhenClosed = false
            window.center()
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }
}
