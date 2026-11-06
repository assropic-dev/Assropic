import Foundation
import AppKit
import CryptoKit
import SwiftUI

/// Switches Cursor between the Chinese UI patch and the original UI.
/// The patch itself lives in Resources/CursorZh (copied from cursor-zh/ by build.sh);
/// this class only runs its install.sh and reads back the result.
@MainActor
final class CursorChinesePatch: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var status = "正在检查 Cursor…"
    @Published private(set) var needsQuit = false

    nonisolated static let marker = "/*BRIDGEDOCK-ZH-EXTRA*/"
    nonisolated static let otherPatchMarker = "__bridgeDockLocal"
    let app = URL(fileURLWithPath: "/Applications/Cursor.app")
    private var glass: URL { app.appendingPathComponent("Contents/Resources/app/out/vs/workbench/workbench.glass.main.js") }
    private var script: URL { Bundle.main.resourceURL!.appendingPathComponent("CursorZh/install.sh") }

    init() { Task { await refresh() } }

    private var runningCursor: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == app.path }
    }

    /// Reads the ~40 MB workbench file off the main thread.
    private func scan() async -> (found: Bool, patched: Bool, other: Bool) {
        let url = glass
        return await Task.detached {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return (false, false, false) }
            return (true, data.range(of: Data(CursorChinesePatch.marker.utf8)) != nil,
                    data.range(of: Data(CursorChinesePatch.otherPatchMarker.utf8)) != nil)
        }.value
    }

    func refresh() async {
        let state = await scan()
        enabled = state.patched
        needsQuit = false
        if !state.found { status = "没有找到 /Applications/Cursor.app" }
        else { status = (enabled ? "已开启 · Cursor 显示中文" : "已关闭 · Cursor 原版界面") + (state.other ? " · 与 Assropic 适配共存" : "") }
    }

    /// The language pack restores whole files by hash, so the BD adapter is taken
    /// off first and put back afterwards; neither patch ever restores over the other.
    func set(_ on: Bool, store: BridgeStore) async {
        guard !busy, !store.cursorBusy, on != enabled else { return }
        if runningCursor != nil {
            needsQuit = true
            status = "请先退出 Cursor，再切换"
            return
        }
        guard FileManager.default.fileExists(atPath: script.path) else {
            status = "App 里缺少汉化补丁文件，请重新构建 Assropic"
            return
        }
        busy = true
        store.cursorBusy = true
        defer { busy = false; store.cursorBusy = false }
        let installer = store.cursorInstaller
        let reinstall = store.cursorIdentity.enabled
        let identity = store.cursorIdentity
        if installer.hasAdapterFiles {
            status = "正在检查汉化记录…"
            let app = self.app
            let accepted = await Task.detached { Self.languagePackAccepts(installer, app: app) }.value
            if let problem = accepted {
                status = problem
                return
            }
        }
        if installer.hasAdapterFiles {
            status = "正在暂时撤下 Assropic 适配…"
            do { try await Task.detached { try installer.removeAdapter() }.value }
            catch {
                status = error.localizedDescription
                return
            }
        }
        status = on ? "正在安装中文补丁…" : "正在恢复原版 Cursor…"
        let result = await Self.run(script: script, restore: !on)
        var adapterError: String?
        if reinstall {
            status = "正在装回 Assropic 适配…"
            do { try await Task.detached { try installer.install(identity: identity) }.value }
            catch { adapterError = error.localizedDescription }
        }
        store.cursorInstalled = await Task.detached { installer.isInstalled() }.value
        await refresh()
        if result.code != 0 {
            status = result.lastLine.isEmpty ? "切换失败（\(result.code)）" : result.lastLine
        } else if let adapterError {
            status = "汉化已切换，Assropic 适配未能装回 · " + adapterError
        } else if enabled == on {
            status += " · 重新打开 Cursor 生效"
        }
    }

    /// The language pack only installs over or restores files whose hash it recorded.
    /// Check that taking the adapter off yields exactly those files before touching
    /// anything; an older install made on top of a previous adapter cannot be switched.
    nonisolated static func languagePackAccepts(_ installer: CursorLocalInstaller, app: URL) -> String? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/cursor-language-pack/installs")
        guard let product = try? JSONSerialization.jsonObject(with: Data(contentsOf: app.appendingPathComponent("Contents/Resources/app/product.json"))) as? [String: Any],
              let version = product["version"] as? String else { return nil }
        let records = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.lastPathComponent == "rewrite.json" }
            .compactMap { try? JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any] }
            .filter { record in
                let root = (record["installRoot"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                return record["cursorVersion"] as? String == version
                    && (root == nil || root == app.standardizedFileURL.path || root == app.appendingPathComponent("Contents").standardizedFileURL.path)
            }
        guard let record = records.first, let files = record["files"] as? [String: [String: Any]] else { return nil }
        guard let unadapted = try? installer.unadaptedFiles() else { return "Assropic 适配无法可靠撤下，汉化保持不变。" }
        let zhBackup = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BridgeDock/cursor-zh-backup/workbench.glass.main.js")
        func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        for (path, entry) in files {
            guard var data = unadapted[path] else { continue }
            if path.hasSuffix("workbench.glass.main.js"), data.range(of: Data(marker.utf8)) != nil {
                guard let backup = try? Data(contentsOf: zhBackup) else { return "缺少汉化补充改动的备份，无法自动切换。" }
                data = backup
            }
            let known = ["patched", "original", "pendingFrom"].compactMap { entry[$0] as? String }
            guard known.contains(hex(data)) else {
                return "这台 Cursor 的汉化是在旧版 Assropic 适配之后装上的，语言包记录里含旧适配代码，无法自动切换。请重新安装 Cursor 3.27.22 后，先开汉化、再开 Assropic 反代。"
            }
        }
        return nil
    }

    /// Asks Cursor to quit the normal way, so it can prompt for unsaved files.
    func quitCursor() async {
        guard let cursor = runningCursor else { needsQuit = false; return }
        cursor.terminate()
        for _ in 0..<60 where !cursor.isTerminated { try? await Task.sleep(nanoseconds: 500_000_000) }
        needsQuit = !cursor.isTerminated
        status = needsQuit ? "Cursor 还没退出，请在 Cursor 里保存或关闭提示" : "Cursor 已退出，可以切换"
    }

    nonisolated private static func run(script: URL, restore: Bool) async -> (code: Int32, lastLine: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path] + (restore ? ["restore"] : [])
            process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                                   "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory()]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { return (-1, error.localizedDescription) }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let lines = output.split(separator: "\n").map(String.init)
                .filter { !$0.contains("DeprecationWarning") && !$0.contains("trace-deprecation") }
            return (process.terminationStatus, lines.last ?? "")
        }.value
    }
}

// Same values as the private colors in Views.swift.
private let zhMutedInk = Color(red: 0.45, green: 0.43, blue: 0.40)
private let zhAccent = Color(red: 0.69, green: 0.32, blue: 0.22)

struct CursorChineseCard: View {
    @EnvironmentObject var store: BridgeStore
    @StateObject private var patch = CursorChinesePatch()
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "character.bubble").foregroundStyle(zhAccent)
                    Text("Cursor 中文界面").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if patch.busy { ProgressView().controlSize(.small) }
                    Toggle("中文补丁", isOn: Binding(get: { patch.enabled }, set: { on in Task { await patch.set(on, store: store) } }))
                        .toggleStyle(.switch).labelsHidden().disabled(patch.busy || store.cursorBusy)
                }
                Text("打开：Cursor 显示中文。关闭：恢复原版 Cursor。切换前要先退出 Cursor。")
                    .font(.system(size: 12)).foregroundStyle(zhMutedInk)
                HStack {
                    Text(patch.status).font(.system(size: 11)).foregroundStyle(zhMutedInk)
                    Spacer()
                    if patch.needsQuit { Button("退出 Cursor") { Task { await patch.quitCursor() } } }
                    Button("重新检查") { Task { await patch.refresh() } }.disabled(patch.busy)
                }
                Text("译文对应 Cursor 3.27.22。Cursor 更新后，关闭再打开一次即可重装。改过的 Cursor 程序签名检查不通过，打不开时关闭此开关即可恢复。")
                    .font(.system(size: 10)).foregroundStyle(zhMutedInk)
            }
        }
    }
}
