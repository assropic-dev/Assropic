import Foundation
import Combine

/// Compile with Sources/*.swift except App.swift. Run from a temporary directory
/// with no CursorLocal resources: a failed preflight must never reach the real app.
@main
struct CursorSwitchingTests {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridgedock-switch-tests-" + UUID().uuidString)
        setenv("BRIDGEDOCK_DATA_DIR", root.path, 1)
        defer { try? FileManager.default.removeItem(at: root) }
        precondition(!FileManager.default.fileExists(atPath:
            Bundle.main.resourceURL!.appendingPathComponent("CursorLocal/patches.json").path),
            "Run this fixture without CursorLocal resources; it must not modify Cursor")
        let store = BridgeStore()
        var assertions = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            assertions += 1
        }

        check(!store.cursorToggleEnabled && !store.cursorNeedsRecovery, "official mode starts off")
        check(store.cursorModeTitle == "Cursor 官方账号", "official mode is labelled accurately")
        store.cursorIdentity.enabled = true
        check(!store.cursorToggleEnabled && store.cursorNeedsRecovery, "a saved choice alone must not light the switch")
        check(store.cursorModeTitle == "BD 反代已暂停", "stopped service is labelled paused")
        store.running = true
        store.cursorInstalled = true
        check(!store.cursorToggleEnabled, "an installed adapter without a session is not active")
        check(store.cursorModeTitle == "BD 反代未就绪", "failed session is not labelled as current BD mode")
        store.cursorSessionReady = true
        check(store.cursorToggleEnabled && !store.cursorNeedsRecovery, "a ready service lights the switch")
        store.running = false
        check(!store.cursorToggleEnabled, "stopping the service immediately turns off the effective switch")
        store.running = true
        store.cursorInstalled = false
        check(!store.cursorToggleEnabled, "a removed adapter cannot appear active")
        store.cursorInstalled = true
        store.cursorPendingEnabled = false
        check(!store.cursorToggleEnabled, "turning off responds before the asynchronous work completes")
        check(store.cursorModeTitle == "正在切回官方账号", "pending off has an explicit progress label")
        store.cursorPendingEnabled = true
        store.cursorSessionReady = false
        check(store.cursorToggleEnabled, "turning on responds before the asynchronous work completes")
        check(store.cursorModeTitle == "正在开启 BD 反代", "pending on is not mistaken for success")
        store.cursorPendingEnabled = nil

        var pending: [Bool?] = []
        let observer = store.$cursorPendingEnabled.sink { pending.append($0) }
        await store.setCursorLocalEnabled(true)
        check(pending.contains(where: { $0 == true }), "real switch publishes pending state before preflight")
        check(store.error != nil, "the deliberately missing adapter resources fail preflight")
        check(!store.cursorBusy && store.cursorPendingEnabled == nil, "failure clears busy and pending state")
        check(store.cursorIdentity.enabled, "failure preserves the user's saved preference")
        check(!store.cursorToggleEnabled && store.cursorNeedsRecovery, "failure exposes recovery instead of a false on state")
        check(store.cursorModeTitle == "BD 反代未就绪", "failure cannot claim BD is currently connected")
        let saved = try JSONDecoder().decode(CursorLocalIdentity.self,
            from: Data(contentsOf: root.appendingPathComponent("cursor-local.json")))
        check(saved.enabled, "failure preserves the preference on disk too")
        store.running = false
        store.cursorInstalled = true
        store.cursorSessionReady = true
        store.error = nil
        await store.setCursorLocalEnabled(true)
        check(store.error != nil && !store.cursorSessionReady,
              "retry is not skipped when a stopped service has stale readiness flags")
        store.cursorIdentity.enabled = false
        await store.setCursorLocalEnabled(true)
        check(!store.cursorToggleEnabled && !store.cursorIdentity.enabled, "failed first enable rolls back to official mode")
        check(store.cursorModeTitle == "Cursor 官方账号", "failed first enable labels the retained official mode")
        withExtendedLifetime(observer) {}
        print("PASS \(assertions) Cursor switch state and failure recovery assertions")
    }
}
