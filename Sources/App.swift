import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let reopenNotification = Notification.Name("local.bridgedock.app.reopen")
    /// 冷启动时链接可能先于窗口的 .task 到达，先排队，等 store 就绪再交给它。
    private var pendingLinks: [URL] = []
    var store: BridgeStore? { didSet { deliverLinks() } }
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingLinks += urls.filter { $0.scheme?.lowercased() == "ccswitch" }
        deliverLinks()
    }
    private func deliverLinks() {
        guard let store, !pendingLinks.isEmpty else { return }
        let links = pendingLinks
        pendingLinks = []
        for url in links { store.receiveImportLink(url) }
        // 重新 openWindow 会重建窗口内容并取消其中正在进行的启动任务，已有窗口时只前置。
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) { window.makeKeyAndOrderFront(nil) }
        else { store.openMainWindow?() }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reopenWindow),
            name: Self.reopenNotification, object: String(getpid()))
    }
    @objc private func reopenWindow(_ notification: Notification) {
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { store?.stop(waitForExit: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }
}

/// Claim the data directory before SwiftUI constructs BridgeStore or migrates
/// configuration. A duplicate must never start/stop the owner's child runtimes.
@main
enum BridgeDockMain {
    @MainActor
    static func main() {
        let instance = AppInstanceLock()
        do {
            // The owner may still be publishing its PID immediately after flock.
            for _ in 0..<20 {
                if try instance.acquire() {
                    withExtendedLifetime(instance) { BridgeDockApp.main() }
                    return
                }
                if let pid = instance.ownerPID,
                   let app = NSRunningApplication(processIdentifier: pid),
                   app.bundleIdentifier == Bundle.main.bundleIdentifier, !app.isTerminated {
                    // Target the owner PID directly; asking Launch Services to
                    // open a bundle can select another installed copy.
                    DistributedNotificationCenter.default().postNotificationName(
                        AppDelegate.reopenNotification, object: String(pid), userInfo: nil, deliverImmediately: true)
                    app.activate(options: [.activateAllWindows])
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw BridgeError.message("另一个 Assropic 正在启动，请稍后重新打开。")
        } catch {
            let alert = NSAlert()
            alert.messageText = "Assropic 未能启动"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "知道了")
            alert.runModal()
        }
    }
}

struct BridgeDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = BridgeStore()
    var body: some Scene {
        Window("Assropic 桥接台", id: "main") {
            ContentView().environmentObject(store).task {
                delegate.store = store
                store.claimImportLinks()
                await store.start()
            }
        }.defaultSize(width: 1220, height: 820)
            .windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(after: .appInfo) { Button("打开数据目录") { store.showDataDirectory() } }
            }
        MenuBarExtra("Assropic", systemImage: "point.3.connected.trianglepath.dotted") {
            MenuContent().environmentObject(store)
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var store: BridgeStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(store.status)
        Text("127.0.0.1:" + String(store.settings.port))
        Divider()
        Button("打开桥接台") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(store.running ? "停止服务" : "启动服务") {
            if store.running { store.stop() } else { Task { await store.start() } }
        }.disabled(store.busy)
        Button("复制 API 地址") { store.copy(store.apiURL) }
        Button("打开 Claude") { Task { await store.openClaudeDesktop() } }
            .disabled(store.launchingAgent || store.busy)
        Button("打开 Cursor 主窗口") { Task { await store.openCursorWindow() } }
            .disabled(store.cursorBusy || store.busy || store.launchingAgent)
        Divider()
        Button("退出 Assropic") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
