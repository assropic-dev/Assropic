import Foundation

enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum WireProtocol: String, Codable, CaseIterable, Identifiable {
    case chat, responses, anthropic, xai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chat: return "OpenAI Chat Completions"
        case .responses: return "OpenAI Responses / Codex"
        case .anthropic: return "Anthropic Messages"
        case .xai: return "xAI / Grok"
        }
    }
    var configKey: String {
        switch self {
        case .chat: return "openai-compatibility"
        case .responses: return "codex"
        case .anthropic: return "claude"
        case .xai: return "xai"
        }
    }
}

struct Channel: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.lowercased()
    var name = ""
    var kind = "自定义中转站"
    var wire: WireProtocol = .chat
    var baseURL = ""
    var apiKey = ""
    var prefix = ""
    var modelLines = ""
    var proxyURL = ""
    var enabled = true

    var models: [[String: String]] {
        modelLines.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, !name.isEmpty else { return nil }
            return ["name": name, "alias": parts.count == 2 ? parts[1] : name]
        }
    }

    func validated() throws -> Channel {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.baseURL.hasSuffix("/") { value.baseURL.removeLast() }
        value.prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        value.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty else { throw BridgeError.message("请填写渠道名称。") }
        guard let url = URL(string: value.baseURL), ["http", "https"].contains(url.scheme ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw BridgeError.message("请填写完整的 HTTP(S) Base URL，不要包含密钥、查询参数或片段。")
        }
        guard !value.apiKey.isEmpty else { throw BridgeError.message("请填写 API Key。") }
        guard !value.apiKey.contains("\n"), !value.apiKey.contains("\r") else { throw BridgeError.message("API Key 不能包含换行。") }
        guard value.prefix.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else {
            throw BridgeError.message("渠道前缀请使用英文字母、数字、短横线或下划线。")
        }
        guard !value.models.isEmpty, value.models.allSatisfy({ !($0["alias"] ?? "").isEmpty }) else {
            throw BridgeError.message("请至少填写一个模型 ID，也可以先点击获取模型。")
        }
        try validateProxyURL(value.proxyURL)
        return value
    }

    var coreValue: [String: Any] {
        var value: [String: Any] = ["name": name, "prefix": prefix, "base-url": baseURL,
                                    "models": models, "keys": [["api-key": apiKey]], "request-retry": 1]
        if !proxyURL.isEmpty { value["proxy-url"] = proxyURL }
        return value
    }
}

struct Preset: Identifiable {
    let id: String
    let title: String
    let wire: WireProtocol
    let url: String
    let prefix: String
    static let all: [Preset] = [
        .init(id: "relay", title: "自定义中转站", wire: .chat, url: "", prefix: "relay"),
        .init(id: "claude", title: "Claude API", wire: .anthropic, url: "https://api.anthropic.com", prefix: "claude"),
        .init(id: "codex", title: "OpenAI / Codex API", wire: .responses, url: "https://api.openai.com/v1", prefix: "openai"),
        .init(id: "kimi-code", title: "Kimi Code 订阅 Key", wire: .anthropic, url: "https://api.kimi.com/coding", prefix: "kimi-code"),
        .init(id: "kimi", title: "Kimi 开放平台", wire: .chat, url: "https://api.moonshot.cn/v1", prefix: "kimi"),
        .init(id: "zcode", title: "智谱 GLM Coding Plan", wire: .anthropic, url: "https://open.bigmodel.cn/api/anthropic", prefix: "glm"),
        .init(id: "zai", title: "Z.ai Coding Plan", wire: .anthropic, url: "https://api.z.ai/api/anthropic", prefix: "zai"),
        .init(id: "deepseek", title: "DeepSeek API", wire: .chat, url: "https://api.deepseek.com/v1", prefix: "deepseek"),
        .init(id: "grok", title: "Grok / xAI API", wire: .xai, url: "https://api.x.ai/v1", prefix: "grok")
    ]
}

struct AppSettings: Codable {
    var version = 1
    var port = 18417
    var clientKey = "bd-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var managementKey = UUID().uuidString + UUID().uuidString
    var channels: [Channel] = []
    var proxyURL = ""
    var kiroStartURL = ""
    var kiroRegion = "us-east-1"
    var selectedModels: [String: String] = [:]

    func coreConfig(dataDirectory: URL, pluginDirectory: URL) -> [String: Any] {
        var providers: [String: Any] = [:]
        for wire in WireProtocol.allCases {
            providers[wire.configKey] = channels.filter { $0.enabled && $0.wire == wire }.map(\.coreValue)
        }
        return [
            "config-version": 8,
            "server": ["host": "127.0.0.1", "port": port, "max-request-body-bytes": 33554432],
            "management": ["allow-remote": false, "secret-key": managementKey,
                           "disable-control-panel": true, "disable-auto-update-panel": true],
            "access": ["api-keys": [clientKey]],
            "api-keys": providers,
            "oauth": ["auth-dir": dataDirectory.appendingPathComponent("accounts").path],
            "routing": ["strategy": "round-robin", "force-model-prefix": true, "retry": ["request-retry": 1]],
            "requests": ["proxy-url": proxyURL, "tls-handshake-timeout-seconds": 20],
            "observability": ["logs": ["debug": false, "logging-to-file": true,
                                       "logs-max-total-size-mb": 10, "error-logs-max-files": 0, "request-log": false],
                              "usage": ["usage-statistics-enabled": true]],
            "plugins": ["enabled": true, "dir": pluginDirectory.path,
                        "configs": ["kiro": ["enabled": true, "idc_start_url": kiroStartURL, "idc_region": kiroRegion]]]
        ]
    }
}

// Missing fields fall back to defaults, so a state.json written by an older
// version still loads after new settings are added.
extension Channel {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Channel()
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? d.kind
        wire = try c.decodeIfPresent(WireProtocol.self, forKey: .wire) ?? d.wire
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? d.apiKey
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? d.prefix
        modelLines = try c.decodeIfPresent(String.self, forKey: .modelLines) ?? d.modelLines
        proxyURL = try c.decodeIfPresent(String.self, forKey: .proxyURL) ?? d.proxyURL
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
    }
}

extension AppSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        clientKey = try c.decodeIfPresent(String.self, forKey: .clientKey) ?? d.clientKey
        managementKey = try c.decodeIfPresent(String.self, forKey: .managementKey) ?? d.managementKey
        channels = try c.decodeIfPresent([Channel].self, forKey: .channels) ?? d.channels
        proxyURL = try c.decodeIfPresent(String.self, forKey: .proxyURL) ?? d.proxyURL
        kiroStartURL = try c.decodeIfPresent(String.self, forKey: .kiroStartURL) ?? d.kiroStartURL
        kiroRegion = try c.decodeIfPresent(String.self, forKey: .kiroRegion) ?? d.kiroRegion
        selectedModels = try c.decodeIfPresent([String: String].self, forKey: .selectedModels) ?? d.selectedModels
    }
}

struct Account: Identifiable {
    let name: String
    let provider: String
    let email: String
    let status: String
    let disabled: Bool
    var id: String { name }
    init(_ value: [String: Any]) {
        name = value["name"] as? String ?? value["id"] as? String ?? "unknown"
        provider = value["provider"] as? String ?? value["type"] as? String ?? "unknown"
        email = value["email"] as? String ?? value["label"] as? String ?? name
        status = value["status"] as? String ?? "unknown"
        disabled = value["disabled"] as? Bool ?? false
    }
}

struct ModelItem: Identifiable {
    let id: String
    let owner: String
}

struct Activity: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
    let failed: Bool
}

struct LoginSession: Identifiable {
    let id = UUID()
    let provider: String
    let state: String
    let url: String
    let userCode: String
}

func validateProxyURL(_ text: String) throws {
    if text.isEmpty || text == "direct" { return }
    guard let url = URL(string: text), ["http", "https", "socks5", "socks5h"].contains(url.scheme ?? ""), url.host != nil else {
        throw BridgeError.message("网络代理请填写 http://、https:// 或 socks5:// 地址，也可以留空。")
    }
}

func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
}

func privateWrite(_ data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func tomlQuote(_ text: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])
    let array = String(decoding: data, as: UTF8.self)
    return String(array.dropFirst().dropLast())
}
