import Foundation
import CryptoKit

enum ClientTool: String, CaseIterable, Identifiable {
    case cursor = "Cursor", claudeDesktop = "Claude", claude = "Claude Code", codex = "Codex CLI", kimi = "Kimi Code", zcode = "ZCode", kiro = "Kiro", generic = "其他工具"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .cursor: return "cursorarrow.rays"
        case .claudeDesktop: return "desktopcomputer"
        case .claude: return "terminal"
        case .codex: return "curlybraces"
        case .kimi: return "moon.stars"
        case .zcode: return "chevron.left.forwardslash.chevron.right"
        case .kiro: return "sparkles"
        case .generic: return "app.connected.to.app.below.fill"
        }
    }
    var file: String? {
        switch self {
        case .claude: return ".claude/settings.json"
        case .codex: return ".codex/config.toml"
        case .kimi: return ".kimi-code/config.toml"
        default: return nil
        }
    }
}

struct ConnectionProfile {
    let tool: ClientTool
    let baseURL: String
    let key: String
    let model: String
    var contextSize = 32768

    var claudeEnvironment: [String: String] {
        ["ANTHROPIC_BASE_URL": baseURL, "ANTHROPIC_AUTH_TOKEN": key,
         "ANTHROPIC_MODEL": model, "ANTHROPIC_DEFAULT_OPUS_MODEL": model,
         "ANTHROPIC_DEFAULT_SONNET_MODEL": model, "ANTHROPIC_DEFAULT_HAIKU_MODEL": model]
    }

    var snippet: String {
        switch tool {
        case .cursor:
            return "在 Cursor 接入页打开“使用 BD 反代”开关即可使用 BridgeDock 模型；关闭开关后使用原来的 Cursor 官方账号。切换时会正常重启 Cursor。"
        case .claudeDesktop:
            return """
            Inference provider    Gateway
            Credential kind       Static API key
            Gateway base URL      \(baseURL)
            Gateway API key       \(key)
            Gateway auth scheme   Bearer
            Model ID              \(model)
            """
        case .claude:
            return String(decoding: try! jsonData(["env": claudeEnvironment]), as: UTF8.self)
        case .codex:
            return """
            model = \(tomlQuote(model))
            model_provider = "bridgedock"

            [model_providers.bridgedock]
            name = "BridgeDock"
            base_url = \(tomlQuote(baseURL + "/v1"))
            wire_api = "responses"
            requires_openai_auth = false
            supports_websockets = false
            experimental_bearer_token = \(tomlQuote(key))
            """
        case .kimi:
            return """
            default_model = "bridgedock"

            [providers.bridgedock]
            type = "openai"
            base_url = \(tomlQuote(baseURL + "/v1"))
            api_key = \(tomlQuote(key))

            [models.bridgedock]
            provider = "bridgedock"
            model = \(tomlQuote(model))
            max_context_size = \(contextSize)
            capabilities = ["tool_use"]
            """
        case .kiro:
            return "Kiro 的官方客户端当前使用其内置模型目录。\n\n您可以在“订阅账号”中接入 Kiro 账号，再通过本地接口供 Claude Code、Codex CLI 等工具调用。\n\n若要在 Kiro 编辑器中使用其他渠道，请使用支持自定义 Base URL 的扩展，并填入“其他工具”页提供的连接信息。"
        case .zcode, .generic:
            return """
            服务商类型    OpenAI 兼容
            Base URL      \(baseURL)/v1
            API Key       \(key)
            模型 ID        \(model)

            Anthropic 兼容工具的 Base URL
            \(baseURL)
            """
        }
    }

    var command: String {
        launchCommand(executable: nil)
    }

    func launchCommand(executable: String?) -> String {
        let selectedExecutable = executable.map(shellQuote)
        switch tool {
        case .claude:
            return "env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY " + claudeEnvironment.sorted { $0.key < $1.key }.map { $0.key + "=" + shellQuote($0.value) }.joined(separator: " ") + " " + (selectedExecutable ?? "claude")
        case .codex:
            let values = ["model=" + tomlQuote(model), "model_provider=\"bridgedock\"",
                          "model_providers.bridgedock.name=\"BridgeDock\"",
                          "model_providers.bridgedock.base_url=" + tomlQuote(baseURL + "/v1"),
                          "model_providers.bridgedock.wire_api=\"responses\"",
                          "model_providers.bridgedock.requires_openai_auth=false",
                          "model_providers.bridgedock.supports_websockets=false",
                          "model_providers.bridgedock.experimental_bearer_token=" + tomlQuote(key)]
            return (selectedExecutable ?? "codex") + " " + values.map { "-c " + shellQuote($0) }.joined(separator: " ")
        case .kimi: return (selectedExecutable ?? "kimi") + " -m bridgedock"
        default: return ""
        }
    }

    func merged(with original: Data?) throws -> Data {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BridgeError.message("请先选择模型。") }
        switch tool {
        case .claude:
            var root: [String: Any] = [:]
            if let original, !original.isEmpty {
                guard let object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                    throw BridgeError.message("Claude 配置不是 JSON 对象。")
                }
                root = object
            }
            if let env = root["env"], !(env is [String: Any]) { throw BridgeError.message("Claude 配置的 env 字段格式不正确。") }
            var environment = root["env"] as? [String: Any] ?? [:]
            for name in ["ANTHROPIC_API_KEY", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] { environment.removeValue(forKey: name) }
            for (key, value) in claudeEnvironment { environment[key] = value }
            root["env"] = environment
            return try jsonData(root)
        case .codex:
            let old = try decodeText(original)
            let table = snippet.components(separatedBy: "\n").dropFirst(3).joined(separator: "\n")
            let text = try mergeTOML(old, rootValues: ["model": tomlQuote(model), "model_provider": "\"bridgedock\""], managedTables: table,
                                     tableNames: ["model_providers.bridgedock"])
            return Data(text.utf8)
        case .kimi:
            let old = try decodeText(original)
            let table = snippet.components(separatedBy: "\n").dropFirst(2).joined(separator: "\n")
            let text = try mergeTOML(old, rootValues: ["default_model": "\"bridgedock\""], managedTables: table,
                                     tableNames: ["providers.bridgedock", "models.bridgedock"])
            return Data(text.utf8)
        default: throw BridgeError.message("请在目标工具的设置中粘贴连接信息。")
        }
    }
}

private func decodeText(_ data: Data?) throws -> String {
    guard let data else { return "" }
    guard let text = String(data: data, encoding: .utf8) else { throw BridgeError.message("配置文件不是 UTF-8 文本。") }
    return text
}

func mergeTOML(_ original: String, rootValues: [String: String], managedTables: String, tableNames: [String]) throws -> String {
    let begin = "# BEGIN BRIDGEDOCK MANAGED"
    let end = "# END BRIDGEDOCK MANAGED"
    guard !original.contains("\"\"\""), !original.contains("'''"), !original.contains("\0") else {
        throw BridgeError.message("该配置含多行字符串，需要手动合并。请复制配置片段或使用临时启动命令。")
    }
    var lines = original.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    let starts = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == begin }
    let ends = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == end }
    guard starts.count == ends.count, starts.count <= 1 else { throw BridgeError.message("BridgeDock 配置标记不完整，请检查文件。") }
    if let start = starts.first, let finish = ends.first {
        guard finish > start else { throw BridgeError.message("BridgeDock 配置标记顺序不正确。") }
        lines.removeSubrange(start...finish)
    }
    for line in lines {
        let compact = line.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        if tableNames.contains(where: { compact.hasPrefix("[" + $0 + "]") || compact.hasPrefix("[" + $0 + ".") || compact.hasPrefix($0 + "=") || compact.hasPrefix($0 + ".") }) {
            throw BridgeError.message("文件中已有手工编写的 bridgedock 配置，请先改名或手动合并。")
        }
    }
    let firstTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
    var rootLines = Array(lines.prefix(firstTable))
    for (key, value) in rootValues.sorted(by: { $0.key < $1.key }) {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern = "^\\s*(?:" + escaped + "|\"" + escaped + "\"|'" + escaped + "')\\s*="
        let indices = rootLines.indices.filter { rootLines[$0].range(of: pattern, options: .regularExpression) != nil }
        guard indices.count <= 1 else { throw BridgeError.message("配置中存在重复的 \(key)，请先修复后再应用。") }
        if let index = indices.first { rootLines[index] = key + " = " + value }
        else { rootLines.insert(key + " = " + value, at: 0) }
    }
    let remaining = Array(lines.dropFirst(firstTable))
    let result = (rootLines + remaining).joined(separator: "\n").trimmingCharacters(in: .newlines)
    return result + "\n\n" + begin + "\n" + managedTables + "\n" + end + "\n"
}

struct BackupEntry: Codable {
    let destination: String
    let backup: String?
    let appliedDigest: String
    let date: Date
}

struct ConfigurationInstaller {
    let directory: URL
    var manifest: URL { directory.appendingPathComponent("backups.json") }
    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func history() throws -> [BackupEntry] {
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        return try JSONDecoder().decode([BackupEntry].self, from: Data(contentsOf: manifest))
    }

    func apply(_ profile: ConnectionProfile, to destination: URL) throws {
        let files = FileManager.default
        if let values = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw BridgeError.message("配置文件是符号链接，请选择真实目标文件或手动合并。")
        }
        let existed = files.fileExists(atPath: destination.path)
        let before = existed ? try Data(contentsOf: destination) : nil
        let after = try profile.merged(with: before)
        // An unchanged file needs no new backup; repeated launches would otherwise bury the original.
        if before == after { return }
        var entries = try history()
        var backup: URL?
        if let before {
            backup = directory.appendingPathComponent("backups/" + UUID().uuidString + "-" + destination.lastPathComponent)
            try privateWrite(before, to: backup!)
        }
        // Refuse to overwrite an edit made while preview/backup was being prepared.
        if existed {
            guard try Data(contentsOf: destination) == before else { throw BridgeError.message("配置已被其他程序修改，请重试。") }
        } else if files.fileExists(atPath: destination.path) { throw BridgeError.message("目标文件刚刚被其他程序创建，请重试。") }
        let entry = BackupEntry(destination: destination.path, backup: backup?.path, appliedDigest: digest(after), date: Date())
        entries.append(entry)
        // Journal the backup before replacing the user's file, so a crash cannot
        // leave a completed write with no discoverable recovery record.
        try privateWrite(JSONEncoder().encode(entries), to: manifest)
        do { try privateWrite(after, to: destination) }
        catch {
            entries.removeLast()
            try? privateWrite(JSONEncoder().encode(entries), to: manifest)
            throw error
        }
    }

    func restore(_ destination: URL) throws {
        var entries = try history()
        guard let index = entries.lastIndex(where: { $0.destination == destination.path }) else {
            throw BridgeError.message("该文件还没有 BridgeDock 备份。")
        }
        let entry = entries[index]
        guard let current = try? Data(contentsOf: destination), digest(current) == entry.appliedDigest else {
            throw BridgeError.message("配置在应用后又被修改。请从数据目录的 backups 文件夹手动合并，避免覆盖新改动。")
        }
        if let path = entry.backup { try privateWrite(Data(contentsOf: URL(fileURLWithPath: path)), to: destination) }
        else { try FileManager.default.removeItem(at: destination) }
        entries.remove(at: index)
        try privateWrite(JSONEncoder().encode(entries), to: manifest)
    }
}
