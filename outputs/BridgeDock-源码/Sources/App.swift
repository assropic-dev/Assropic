import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: BridgeStore?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { store?.stop(waitForExit: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }
}

@main
struct BridgeDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = BridgeStore()
    var body: some Scene {
        Window("BridgeDock 桥接台", id: "main") {
            ContentView().environmentObject(store).task {
                delegate.store = store
                await store.start()
            }
        }.defaultSize(width: 1220, height: 820)
            .windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(after: .appInfo) { Button("打开数据目录") { store.showDataDirectory() } }
            }
        MenuBarExtra("BridgeDock", systemImage: "point.3.connected.trianglepath.dotted") {
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
        Divider()
        Button("退出 BridgeDock") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
