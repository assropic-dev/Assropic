import Foundation

enum BalanceMode: String, Codable, CaseIterable, Identifiable {
    case auto, deepseek, moonshot, kimi, kimiWork, zhipu, newAPI, custom, unavailable
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "自动识别"
        case .deepseek: return "DeepSeek 余额"
        case .moonshot: return "Moonshot 余额"
        case .kimi: return "Kimi Code 额度"
        case .kimiWork: return "Kimi Work 会员共享额度"
        case .zhipu: return "智谱 / Z.ai Coding Plan"
        case .newAPI: return "New API 令牌与账户额度"
        case .custom: return "自定义余额接口"
        case .unavailable: return "不查询余额"
        }
    }
}


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
    var balanceMode: BalanceMode = .auto
    var balancePath = ""
    var credentialSource = "api-key"
    var desktopAccountHash = ""
    /// Per upstream model ID, as reported by the provider's /models when last queried.
    var capabilities: [String: ModelCapability] = [:]
    var isKimiWork: Bool { credentialSource == "kimi-work-desktop" }

    var models: [[String: String]] {
        modelLines.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, !name.isEmpty else { return nil }
            return ["name": name, "alias": parts.count == 2 ? parts[1] : name]
        }
    }

    static func unusedPrefix(_ base: String, channels: [Channel], accounts: [Account]) -> String {
        let used = Set(channels.map(\.prefix) + accounts.map(\.prefix))
        var candidate = base
        var number = 2
        while used.contains(candidate) { candidate = "\(base)-\(number)"; number += 1 }
        return candidate
    }

    func validated(channels: [Channel] = [], accounts: [Account] = []) throws -> Channel {
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
        if value.isKimiWork {
            guard value.baseURL == "https://agent-gw.kimi.com/coding/v1", value.wire == .chat,
                  value.desktopAccountHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw BridgeError.message("Kimi Work 需要连接本机桌面账号，且只能使用独立 Work 网关。")
            }
            value.apiKey = ""
            value.balanceMode = .kimiWork
        } else {
            guard !value.apiKey.isEmpty else { throw BridgeError.message("请填写 API Key。") }
            guard value.balanceMode != .kimiWork else { throw BridgeError.message("Work 会员额度仅用于本机 Kimi Work 通道。") }
        }
        guard !value.apiKey.contains("\n"), !value.apiKey.contains("\r") else { throw BridgeError.message("API Key 不能包含换行。") }
        guard value.prefix.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else {
            throw BridgeError.message("渠道前缀请使用英文字母、数字、短横线或下划线。")
        }
        guard !channels.contains(where: { $0.id != value.id && $0.prefix == value.prefix }) else {
            throw BridgeError.message("该前缀已被其他渠道使用，请换一个前缀。")
        }
        guard !accounts.contains(where: { $0.prefix == value.prefix }) else {
            throw BridgeError.message("该前缀已被订阅账号使用。请使用独立前缀，以免混用模型和计费通道。")
        }
        guard !value.models.isEmpty, value.models.allSatisfy({ !($0["alias"] ?? "").isEmpty }) else {
            throw BridgeError.message("请至少填写一个模型 ID，也可以先点击获取模型。")
        }
        try validateProxyURL(value.proxyURL)
        if value.balanceMode == .custom {
            guard value.balancePath.hasPrefix("/"), !value.balancePath.hasPrefix("//"), !value.balancePath.contains("#") else {
                throw BridgeError.message("自定义余额接口请填写同一服务商下以 / 开头的路径。")
            }
        }
        return value
    }

    var coreValue: [String: Any] {
        var value: [String: Any] = ["name": name, "prefix": prefix, "base-url": baseURL,
                                    "models": models, "keys": [["api-key": apiKey]], "request-retry": isKimiWork ? 0 : 1]
        if !proxyURL.isEmpty { value["proxy-url"] = proxyURL }
        if isKimiWork { value["headers"] = ["User-Agent": "BridgeDock/1.3.2"] }
        return value
    }
}

/// Context window and reasoning levels for one upstream model, as reported by the
/// core's model definitions or the provider's own /models response. Unknown stays nil.
struct ModelCapability: Codable, Equatable {
    var contextLength: Int?
    var maxOutputTokens: Int?
    var reasoningEfforts: [String]?
    var supportsVision: Bool?

    var isEmpty: Bool { contextLength == nil && maxOutputTokens == nil && reasoningEfforts == nil && supportsVision == nil }

    static let effortOrder = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// Accepts the shapes seen in the wild: CLIProxyAPI definitions (`context_length`,
    /// `inputTokenLimit`, `thinking.levels`), Kimi (`think_efforts.valid_efforts`) and
    /// OpenAI-style `capabilities`.
    init?(definition value: [String: Any]) {
        func positive(_ any: Any?) -> Int? {
            guard let number = (any as? NSNumber)?.intValue ?? (any as? String).flatMap(Int.init), number > 0 else { return nil }
            return number
        }
        let nested = value["capabilities"] as? [String: Any] ?? [:]
        contextLength = positive(value["context_length"]) ?? positive(nested["context_length"]) ?? positive(value["inputTokenLimit"])
            ?? positive(value["context_window"]) ?? positive(value["max_context_length"])
        maxOutputTokens = positive(value["max_completion_tokens"]) ?? positive(nested["max_output_tokens"]) ?? positive(value["outputTokenLimit"])
            ?? positive(value["max_output_tokens"])
        var levels: [String]?
        if let thinking = value["thinking"] as? [String: Any] {
            if let named = thinking["levels"] as? [String], !named.isEmpty { levels = named }
            else if thinking["max"] != nil || thinking["dynamic_allowed"] != nil { levels = ["low", "medium", "high"] }
            if thinking["zero_allowed"] as? Bool == true, let current = levels, !current.contains("none") { levels = ["none"] + current }
        }
        if let kimi = (value["think_efforts"] as? [String: Any]), kimi["support"] as? Bool != false,
           let valid = kimi["valid_efforts"] as? [String], !valid.isEmpty { levels = valid }
        if let advertised = nested["reasoning_effort"] as? [String], !advertised.isEmpty { levels = advertised }
        if levels == nil, value["supports_reasoning"] as? Bool == true { levels = ["low", "medium", "high"] }
        reasoningEfforts = levels.map(Self.sortedEfforts).flatMap { $0.isEmpty ? nil : $0 }
        if let vision = nested["supports_vision"] as? Bool ?? value["supports_image_in"] as? Bool { supportsVision = vision }
        else if let inputs = value["supportedInputModalities"] as? [String] ?? (value["modalities"] as? [String: Any])?["input"] as? [String] {
            supportsVision = inputs.contains("image")
        }
        if isEmpty { return nil }
    }

    init(contextLength: Int? = nil, maxOutputTokens: Int? = nil, reasoningEfforts: [String]? = nil, supportsVision: Bool? = nil) {
        self.contextLength = contextLength; self.maxOutputTokens = maxOutputTokens
        self.reasoningEfforts = reasoningEfforts.map(Self.sortedEfforts); self.supportsVision = supportsVision
    }

    static func sortedEfforts(_ values: [String]) -> [String] {
        let clean = values.map { $0.lowercased() }.filter { $0.range(of: "^[a-z][a-z0-9_-]{0,31}$", options: .regularExpression) != nil }
        return Array(Set(clean)).sorted {
            (effortOrder.firstIndex(of: $0) ?? 99, $0) < (effortOrder.firstIndex(of: $1) ?? 99, $1)
        }
    }

    /// The fields Cursor's local runtime reads from /v1/models.
    var catalogFields: [String: Any] {
        var capabilities: [String: Any] = ["supports_tool_use": true, "supports_streaming": true, "output_modalities": ["text"]]
        var value: [String: Any] = [:]
        if let contextLength { capabilities["context_length"] = contextLength; value["context_length"] = contextLength }
        if let maxOutputTokens { capabilities["max_output_tokens"] = maxOutputTokens }
        if let efforts = reasoningEfforts?.filter({ $0 != "none" }), !efforts.isEmpty {
            capabilities["reasoning_effort"] = efforts
            capabilities["supports_reasoning"] = true
        }
        if let supportsVision { capabilities["supports_vision"] = supportsVision }
        value["capabilities"] = capabilities
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
        .init(id: "kimi-code", title: "Kimi Code 国内（订阅 Key）", wire: .chat, url: "https://api.kimi.com/coding/v1", prefix: "kimi-code"),
        .init(id: "kimi-code-ai", title: "Kimi Code 国际（订阅 Key）", wire: .chat, url: "https://api.kimi.ai/coding/v1", prefix: "kimi-code-ai"),
        .init(id: "kimi", title: "Kimi 开放平台", wire: .chat, url: "https://api.moonshot.cn/v1", prefix: "kimi"),
        .init(id: "kimi-ai", title: "Kimi 国际开放平台", wire: .chat, url: "https://api.moonshot.ai/v1", prefix: "kimi-ai"),
        .init(id: "zcode", title: "智谱 GLM Coding Plan", wire: .anthropic, url: "https://open.bigmodel.cn/api/anthropic", prefix: "glm"),
        .init(id: "zai", title: "Z.ai Coding Plan", wire: .anthropic, url: "https://api.z.ai/api/anthropic", prefix: "zai"),
        .init(id: "deepseek", title: "DeepSeek API", wire: .chat, url: "https://api.deepseek.com", prefix: "deepseek"),
        .init(id: "grok", title: "Grok / xAI API", wire: .xai, url: "https://api.x.ai/v1", prefix: "grok")
    ]

    var balanceMode: BalanceMode {
        switch id {
        case "kimi-code", "kimi-code-ai": return .kimi
        case "kimi", "kimi-ai": return .moonshot
        case "zcode", "zai": return .zhipu
        case "deepseek": return .deepseek
        case "relay": return .auto
        default: return .unavailable
        }
    }
    var supportsModelDiscovery: Bool { !["zcode", "zai"].contains(id) }
    var defaultModelLines: String {
        switch id {
        case "claude": return "claude-sonnet-5-5\nclaude-opus-5-5\nclaude-haiku-5-5"
        case "codex": return "gpt-6.1-sol\ngpt-6-luna\ngpt-6-astra"
        case "kimi-code", "kimi-code-ai": return "k3.1-pro\nk3.1-pro-highspeed\nk3\nk3-256k\nkimi-for-coding\nkimi-for-coding-highspeed"
        case "kimi", "kimi-ai": return "kimi-k3\nkimi-k3.1-pro\nkimi-k3.1-pro-highspeed\nkimi-k2.7-code\nkimi-k2.6"
        case "zcode", "zai": return "glm-5.3\nglm-5.3-flash"
        case "deepseek": return "deepseek-flash\ndeepseek-v4-pro"
        case "grok": return "grok-4.7\ngrok-4.6"
        default: return ""
        }
    }
    var sourceURL: String {
        switch id {
        case "claude": return "https://platform.claude.com/docs/en/models/overview"
        case "codex": return "https://developers.openai.com/api/docs/models"
        case "kimi-code", "kimi-code-ai": return "https://www.kimi.com/code/docs/en/kimi-code/models.html"
        case "kimi", "kimi-ai": return "https://platform.kimi.com/docs/api/models-overview"
        case "zcode": return "https://docs.bigmodel.cn/cn/coding-plan/latest-model"
        case "zai": return "https://docs.z.ai/devpack/latest-model"
        case "deepseek": return "https://api-docs.deepseek.com/quick_start/agent_integrations/"
        case "grok": return "https://docs.x.ai/developers/models"
        default: return ""
        }
    }
    var detail: String {
        if ["kimi-code", "kimi-code-ai"].contains(id) { return "使用 Kimi Code 会员订阅 Key；与开放平台 Key 分开。" }
        if ["kimi", "kimi-ai"].contains(id) { return "使用 Moonshot 开放平台 Key，按量计费；会员订阅 Key 请选 Kimi Code。" }
        if !supportsModelDiscovery { return "已按官方文档填入 Coding Plan 模型；服务商没有公开模型列表接口。" }
        return id == "relay" ? "填写中转站给出的地址与模型。" : "已预填官方配置与常用模型，填入 Key 后自动查询可用模型。"
    }
    func makeChannel(existing: [Channel], accounts: [Account] = []) -> Channel {
        var channel = Channel()
        channel.name = title; channel.kind = title; channel.wire = wire
        channel.baseURL = url; channel.balanceMode = balanceMode; channel.modelLines = defaultModelLines
        channel.prefix = Channel.unusedPrefix(prefix, channels: existing, accounts: accounts)
        return channel
    }
    static func matching(_ channel: Channel) -> Preset? {
        guard let parts = URLComponents(string: channel.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443, let host = parts.host?.lowercased() else { return nil }
        let path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return all.first { preset in
            guard preset.id != "relay", URL(string: preset.url)?.host == host else { return false }
            switch preset.id {
            case "kimi-code", "kimi-code-ai": return ["coding", "coding/v1"].contains(path)
            case "zcode", "zai": return path == "api/anthropic"
            default: return ["", "v1"].contains(path)
            }
        }
    }
}

enum EditingAgent: String, Codable, CaseIterable, Identifiable {
    case cursor = "Cursor", claudeDesktop = "Claude", claude = "Claude Code", codex = "Codex CLI", kimi = "Kimi Code", kiro = "Kiro", zcode = "ZCode"
    var id: String { rawValue }
}

struct AppSettings: Codable {
    var version = 1
    var port = 18417
    var clientKey = "bd-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var managementKey = UUID().uuidString + UUID().uuidString
    var channels: [Channel] = []
    // nil keeps the default of publishing all discovered models. An empty list publishes none.
    var publishedModelIDs: [String]? = nil
    var coreClientKey = "bd-internal-" + UUID().uuidString + UUID().uuidString
    var corePort: Int { port <= 65533 ? (port == 18416 ? 18420 : port + 2) : port - 2 }
    var proxyURL = ""
    var kiroStartURL = ""
    var kiroRegion = "us-east-1"
    var kiroUseOrganization = false
    var selectedModels: [String: String] = [:]
    var lastOpenedAgent: EditingAgent = .cursor
    var lastOpenedProject = ""

    func coreConfig(dataDirectory: URL, pluginDirectory: URL) -> [String: Any] {
        var providers: [String: Any] = [:]
        var plugins: [String: Any] = [
            "kiro": ["enabled": true, "idc_start_url": kiroUseOrganization ? kiroStartURL : "", "idc_region": kiroRegion],
            "cursor-agent2api": ["enabled": true, "state_dir": dataDirectory.appendingPathComponent("cursor-upstream").path]
        ]
        if #available(macOS 15.0, *) { plugins["omc-zcode-oauth"] = ["enabled": true, "mode": "own"] }
        for wire in WireProtocol.allCases {
            providers[wire.configKey] = channels.filter { $0.enabled && $0.wire == wire }.map(\.coreValue)
        }
        return [
            "config-version": 8,
            "server": ["host": "127.0.0.1", "port": corePort, "max-request-body-bytes": 33554432],
            "management": ["allow-remote": false, "secret-key": managementKey,
                           "disable-control-panel": true, "disable-auto-update-panel": true],
            "access": ["api-keys": [coreClientKey]],
            "api-keys": providers,
            "oauth": ["auth-dir": dataDirectory.appendingPathComponent("accounts").path],
            "routing": ["strategy": "round-robin", "force-model-prefix": true, "retry": ["request-retry": 1]],
            "requests": ["proxy-url": proxyURL, "tls-handshake-timeout-seconds": 20],
            "observability": ["logs": ["debug": false, "logging-to-file": true,
                                       "logs-max-total-size-mb": 10, "error-logs-max-files": 0, "request-log": false],
                              "usage": ["usage-statistics-enabled": true]],
            "plugins": ["enabled": true, "dir": pluginDirectory.path,
                        "configs": plugins]
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
        balanceMode = try c.decodeIfPresent(BalanceMode.self, forKey: .balanceMode) ?? .auto
        balancePath = try c.decodeIfPresent(String.self, forKey: .balancePath) ?? ""
        credentialSource = try c.decodeIfPresent(String.self, forKey: .credentialSource) ?? "api-key"
        desktopAccountHash = try c.decodeIfPresent(String.self, forKey: .desktopAccountHash) ?? ""
        capabilities = (try? c.decodeIfPresent([String: ModelCapability].self, forKey: .capabilities)) ?? [:]
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
        publishedModelIDs = try c.decodeIfPresent([String].self, forKey: .publishedModelIDs)
        coreClientKey = try c.decodeIfPresent(String.self, forKey: .coreClientKey) ?? d.coreClientKey
        proxyURL = try c.decodeIfPresent(String.self, forKey: .proxyURL) ?? d.proxyURL
        kiroStartURL = try c.decodeIfPresent(String.self, forKey: .kiroStartURL) ?? d.kiroStartURL
        kiroRegion = try c.decodeIfPresent(String.self, forKey: .kiroRegion) ?? d.kiroRegion
        kiroUseOrganization = try c.decodeIfPresent(Bool.self, forKey: .kiroUseOrganization) ?? !kiroStartURL.isEmpty
        selectedModels = try c.decodeIfPresent([String: String].self, forKey: .selectedModels) ?? d.selectedModels
        lastOpenedAgent = try c.decodeIfPresent(EditingAgent.self, forKey: .lastOpenedAgent) ?? .cursor
        lastOpenedProject = try c.decodeIfPresent(String.self, forKey: .lastOpenedProject) ?? ""
    }
}

struct Account: Identifiable {
    let name: String
    let provider: String
    let email: String
    let status: String
    let disabled: Bool
    let authIndex: String
    let accountID: String
    let planName: String?
    let subscriptionUntil: String?
    let runtimeOnly: Bool
    let note: String
    let prefix: String
    let priority: Int
    let statusMessage: String
    let requiresSignIn: Bool
    let oauthProvider: String
    let runtimeProfile: String
    var loginProvider: String { oauthProvider.isEmpty ? provider : oauthProvider }
    var providerTitle: String {
        if provider == CursorAccountProfile.providerID {
            return CursorAccountProfile(rawValue: runtimeProfile)?.title ?? "Cursor"
        }
        return SubscriptionProvider.find(loginProvider)?.title ?? provider
    }
    var displayName: String { note.isEmpty ? email : note }
    var statusText: String {
        if disabled { return "已停用" }
        if requiresSignIn { return "需要重新授权" }
        switch status {
        case "active": return "可用"
        case "error": return "凭据异常"
        case "pending": return "等待生效"
        default: return status
        }
    }
    var id: String { name }
    init(_ value: [String: Any]) {
        name = value["name"] as? String ?? value["id"] as? String ?? "unknown"
        provider = value["provider"] as? String ?? value["type"] as? String ?? "unknown"
        email = value["email"] as? String ?? value["label"] as? String ?? name
        status = value["status"] as? String ?? "unknown"
        disabled = value["disabled"] as? Bool ?? false
        authIndex = value["auth_index"] as? String ?? value["authIndex"] as? String ?? ""
        let claims = value["id_token"] as? [String: Any] ?? [:]
        accountID = claims["chatgpt_account_id"] as? String ?? value["account_id"] as? String ?? ""
        planName = claims["plan_type"] as? String ?? claims["chatgpt_plan_type"] as? String
        subscriptionUntil = claims["subscription_active_until"] as? String ?? claims["chatgpt_subscription_active_until"] as? String
        runtimeOnly = value["runtime_only"] as? Bool ?? false
        note = value["note"] as? String ?? ""
        prefix = value["prefix"] as? String ?? ""
        priority = (value["priority"] as? NSNumber)?.intValue ?? Int(value["priority"] as? String ?? "") ?? 0
        statusMessage = value["status_message"] as? String ?? ""
        requiresSignIn = value["requires_sign_in"] as? Bool ?? false
        oauthProvider = value["oauth_provider"] as? String ?? ""
        runtimeProfile = value["runtime_profile"] as? String ?? ""
    }
}

struct ModelItem: Identifiable {
    let id: String
    let owner: String
    var metadata: [String: Any] = [:]
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
    let expiresAt: Date
    let previousAccount: String?
    var displayName: String {
        provider == CursorAccountProfile.providerID ? "Grok Bot（Cursor 登录）" : (SubscriptionProvider.find(provider)?.title ?? provider)
    }
    var supportsCallback: Bool { SubscriptionProvider.find(provider)?.supportsCallback ?? false }
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
