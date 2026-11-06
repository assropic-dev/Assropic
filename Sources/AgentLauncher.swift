import Foundation
import AppKit

extension BridgeStore {
    func openCCBaga() async {
        guard !launchingAgent else { return }
        launchingAgent = true
        defer { launchingAgent = false }
        do {
            let application = try installedApplication([
                "/Applications/CCBaga-A.app",
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/CCBaga-A.app").path
            ])
            _ = try await NSWorkspace.shared.openApplication(at: application, configuration: NSWorkspace.OpenConfiguration())
            record("已打开 CCBaga 管理器")
        } catch { report(error) }
    }

    func startEditing(agent: EditingAgent, project: String) async {
        if agent == .claudeDesktop { await openClaudeDesktop(); return }
        guard !launchingAgent, !cursorBusy else { return }
        launchingAgent = true
        defer { launchingAgent = false }
        do {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: project, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw BridgeError.message("请先选择存在的项目文件夹。")
            }
            if agent == .cursor {
                try await prepareCursorForLaunch()
                try await Task.detached { try Self.launchCursorProject(project) }.value
                try rememberLaunch(agent, project: project)
                record("已用 Cursor 主窗口打开项目 · \(URL(fileURLWithPath: project).lastPathComponent)")
                return
            }
            if !running { await start() }
            guard running else { throw BridgeError.message("请先启动 Assropic 代理。") }
            let application: URL
            let configuration = NSWorkspace.OpenConfiguration()
            switch agent {
            case .claudeDesktop: return // Handled without requiring a project folder above.
            case .cursor: return // Handled above; official mode does not start the proxy.
            case .kiro:
                application = try installedApplication(["/Applications/Kiro.app", "/Applications/Kiro CLI.app"])
            case .zcode:
                application = try installedApplication(["/Applications/ZCode.app", "/Applications/Zcode.app"])
            case .claude, .codex, .kimi:
                let tool: ClientTool = agent == .claude ? .claude : agent == .codex ? .codex : .kimi
                let name = agent == .claude ? "claude" : agent == .codex ? "codex" : "kimi"
                let executable = try await Task.detached { try Self.resolveExecutable(name) }.value
                let selected = settings.selectedModels[tool.rawValue].flatMap { id in models.contains { $0.id == id } ? id : nil }
                let model = selected ?? models.first?.id ?? ""
                guard !model.isEmpty else { throw BridgeError.message("请先添加账号或 API 渠道，并为 \(agent.rawValue) 选择模型。") }
                var profile = ConnectionProfile(tool: tool, baseURL: baseURL, key: settings.clientKey, model: model)
                if tool == .kimi, let file = tool.file {
                    let destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(file)
                    // Keep the context length chosen on the integration page.
                    profile.contextSize = Self.managedContextSize(at: destination) ?? profile.contextSize
                    try ConfigurationInstaller(directory: dataDirectory).apply(profile, to: destination)
                }
                let script = dataDirectory.appendingPathComponent("launchers/" + UUID().uuidString + ".command")
                let body = "#!/bin/zsh\nrm -f -- \"$0\"\ncd -- \(shellQuote(project)) || exit 1\nexec \(profile.launchCommand(executable: executable))\n"
                try privateWrite(Data(body.utf8), to: script)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
                application = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                do {
                    _ = try await NSWorkspace.shared.open([script], withApplicationAt: application, configuration: configuration)
                } catch {
                    try? FileManager.default.removeItem(at: script)
                    throw error
                }
                try rememberLaunch(agent, project: project)
                record("已用 \(agent.rawValue) 打开项目 · \(URL(fileURLWithPath: project).lastPathComponent)")
                return
            }
            guard FileManager.default.fileExists(atPath: application.path) else { throw BridgeError.message("没有找到 \(agent.rawValue)，请先安装。") }
            _ = try await NSWorkspace.shared.open([URL(fileURLWithPath: project)], withApplicationAt: application, configuration: configuration)
            try rememberLaunch(agent, project: project)
            record("已用 \(agent.rawValue) 打开项目 · \(URL(fileURLWithPath: project).lastPathComponent)")
        } catch { report(error) }
    }

    nonisolated private static func launchCursorProject(_ project: String) throws {
        let path = "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
        guard FileManager.default.isExecutableFile(atPath: path) else { throw BridgeError.message("未找到 Cursor 的项目启动入口，请先安装 Cursor。") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--glass", project]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "VSCODE_IPC_HOOK_CLI")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BridgeError.message("Cursor 未能打开项目。" + String(decoding: output.prefix(800), as: UTF8.self))
        }
    }

    func openClaudeDesktop() async {
        guard !launchingAgent else { return }
        launchingAgent = true
        defer { launchingAgent = false }
        do {
            let application = try installedApplication([
                "/Applications/Claude.app",
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app").path
            ])
            if !running { await start() }
            guard running else { throw BridgeError.message("请先启动 Assropic 代理。") }
            _ = try await NSWorkspace.shared.openApplication(at: application, configuration: NSWorkspace.OpenConfiguration())
            try rememberLaunch(.claudeDesktop, project: settings.lastOpenedProject)
            record("已打开 Claude 桌面端；模型连接使用 Claude 的第三方推理配置。")
        } catch { report(error) }
    }

    private func installedApplication(_ paths: [String]) throws -> URL {
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw BridgeError.message("未找到这个 Agent 的应用程序，请先安装。")
        }
        return URL(fileURLWithPath: path)
    }

    nonisolated static func managedContextSize(at url: URL) -> Int? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let begin = text.range(of: "# BEGIN BRIDGEDOCK MANAGED"),
              let end = text.range(of: "# END BRIDGEDOCK MANAGED", range: begin.upperBound..<text.endIndex) else { return nil }
        let block = text[begin.upperBound..<end.lowerBound]
        guard let line = block.range(of: "(?m)^max_context_size = [0-9]+$", options: .regularExpression),
              let value = block[line].split(separator: " ").last.flatMap({ Int($0) }), value > 0 else { return nil }
        return value
    }

    nonisolated private static func resolveExecutable(_ name: String) throws -> String {
        // Names are selected by EditingAgent, never supplied by the user.
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v " + shellQuote(name)]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Login shell profiles may print banners before the resolved path.
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = output.components(separatedBy: .newlines).last?.trimmingCharacters(in: .whitespaces) ?? ""
        process.waitUntilExit()
        if process.terminationStatus == 0, text.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: text) { return text }
        if name == "codex" {
            let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
            if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        }
        throw BridgeError.message("未找到 \(name) 命令，请先安装对应的 Agent CLI。")
    }
}
