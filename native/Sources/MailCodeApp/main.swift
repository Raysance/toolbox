import AppKit
import SwiftUI
import MailCodeCore

final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var toast: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var bridge: LocalBridge?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        NSApp.setActivationPolicy(.accessory)
        if let index = arguments.firstIndex(of: "--render-preview"), arguments.count > index + 1 { renderPreview(at: arguments[index + 1]); return }
        if arguments.contains("--self-test") { selfTest(); return }
        // A second launch should not create a second mail watcher or overwrite the clipboard twice.
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        model = AppModel()
        do { bridge = try LocalBridge { [weak self] data in
            guard let self else { return Data("{\"error\":\"InboxCode has stopped\"}".utf8) }
            return await self.model.handleBridge(data)
        } } catch { model.errorMessage = "Could not start the Raycast connection: \(error.localizedDescription)" }
        model.onCode = { [weak self] event, copied in self?.showToast(event, copied: copied) }
        model.onHidePopup = { [weak self] in self?.hideToast() }
        observeSession()
        model.start()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        model?.stop(); model?.clearOwnedClipboard(); hideTask?.cancel()
        bridge?.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0); DistributedNotificationCenter.default().removeObserver($0) }
    }
    private func showToast(_ event: CodeEvent, copied: Bool) {
        hideTask?.cancel()
        if toast == nil {
            let panel = PassivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            toast = panel
        }
        let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        toast?.setFrame(NSRect(x: screen.maxX - 360, y: screen.maxY - 82, width: 340, height: 62), display: false)
        toast?.contentView = NSHostingView(rootView: ToastView(event: event, copied: copied, copy: { [weak self] in self?.model.copy(event) ?? false }, dismiss: { [weak self] in self?.hideToast() }))
        toast?.orderFrontRegardless()
        hideTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            self?.hideToast()
        }
    }
    private func hideToast() { hideTask?.cancel(); toast?.orderOut(nil) }
    private func observeSession() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.setSleeping(true); self?.hideToast() } })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.setSleeping(false) } })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.setLocked(true) } })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.setLocked(false) } })
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.setLocked(locked) } })
        }
    }
    private func renderPreview(at path: String) {
        let event = CodeEvent(code: "123456", sender: "京东 <notice@jd.com>", account: "hello@example.com", provider: "京东")
        let view = NSHostingView(rootView: ZStack {
            LinearGradient(colors: [Color(red: 0.86, green: 0.91, blue: 0.97), Color(red: 0.92, green: 0.89, blue: 0.96)], startPoint: .topLeading, endPoint: .bottomTrailing)
            ToastView(event: event, copied: true, copy: { true }, dismiss: {}).shadow(color: .black.opacity(0.1), radius: 12, y: 5)
        }.environment(\.colorScheme, .light))
        view.frame = NSRect(x: 0, y: 0, width: 380, height: 102)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            do { try data.write(to: URL(fileURLWithPath: path)); print("Preview rendered"); exit(0) }
            catch { fputs("Preview failed\n", stderr); exit(1) }
        }
    }
    private func selfTest() {
        let board = NSPasteboard.withUniqueName()
        let testModel = AppModel(preview: true, pasteboard: board)
        var observed = false
        testModel.onCode = { event, copied in observed = event.code == "482916" && copied }
        testModel.demo()
        guard observed, board.string(forType: .string) == "482916" else { exit(1) }
        board.clearContents(); board.setString("user's next clipboard", forType: .string)
        testModel.clearOwnedClipboard()
        guard board.string(forType: .string) == "user's next clipboard" else { exit(1) }
        _ = testModel.copy(CodeEvent(code: "123456", sender: "test", account: "test"))
        testModel.clearOwnedClipboard()
        guard board.string(forType: .string) == nil else { exit(1) }
        var linkEvent: CodeEvent?
        testModel.onCode = { event, copied in if event.isLink && !copied { linkEvent = event } }
        testModel.demo(link: true)
        guard let linkEvent, board.string(forType: .string) == nil,
              testModel.copy(linkEvent), board.string(forType: .string) == linkEvent.code,
              linkEvent.code == "https://auth.example.invalid/reset-password/demo-test-token?source=email&token=abc%2Bdef" else { exit(1) }
        testModel.clearOwnedClipboard()
        testModel.setLocked(true); testModel.demo()
        guard board.string(forType: .string) == nil, testModel.history.isEmpty else { exit(1) }
        board.releaseGlobally()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MailCode-test-" + UUID().uuidString)
        do {
            try CredentialStore.selfTest()
            let storage = ConfigurationStore(directory: directory)
            var config = Configuration(); config.accounts = [MailAccount(username: "test@example.com", host: "imap.example.com")]
            try storage.save(config)
            guard try storage.load().accounts == config.accounts else { exit(1) }
            let attributes = try FileManager.default.attributesOfItem(atPath: storage.file.path)
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { exit(1) }
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            fputs("Storage self-test failed: \(error.localizedDescription)\n", stderr); exit(1)
        }
        print("PASS: mail parsing → OTP → callback → pasteboard; links notify without auto-copy and copy intact on click; clipboard ownership; lock suppression; single-item Keychain migration/CRUD/corruption protection; configuration roundtrip and permissions")
        exit(0)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
