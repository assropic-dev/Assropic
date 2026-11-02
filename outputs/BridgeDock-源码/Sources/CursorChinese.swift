import Foundation
import AppKit
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
        else if state.other && !state.patched { status = "Cursor 上装着另一个程序补丁，汉化不能叠加" }
        else { status = enabled ? "已开启 · Cursor 显示中文" : "已关闭 · Cursor 原版界面" }
    }

    func set(_ on: Bool) async {
        guard !busy, on != enabled else { return }
        if runningCursor != nil {
            needsQuit = true
            status = "请先退出 Cursor，再切换"
            return
        }
        guard FileManager.default.fileExists(atPath: script.path) else {
            status = "App 里缺少汉化补丁文件，请重新构建 BridgeDock"
            return
        }
        busy = true
        status = on ? "正在安装中文补丁…" : "正在恢复原版 Cursor…"
        let result = await Self.run(script: script, restore: !on)
        busy = false
        await refresh()
        if result.code != 0 {
            status = result.lastLine.isEmpty ? "切换失败（\(result.code)）" : result.lastLine
        } else if enabled == on {
            status += " · 重新打开 Cursor 生效"
        }
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
    @StateObject private var patch = CursorChinesePatch()
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "character.bubble").foregroundStyle(zhAccent)
                    Text("Cursor 中文界面").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if patch.busy { ProgressView().controlSize(.small) }
                    Toggle("中文补丁", isOn: Binding(get: { patch.enabled }, set: { on in Task { await patch.set(on) } }))
                        .toggleStyle(.switch).labelsHidden().disabled(patch.busy)
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
