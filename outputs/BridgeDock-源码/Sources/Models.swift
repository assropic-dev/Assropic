import Foundation

enum BalanceMode: String, Codable, CaseIterable, Identifiable {
    case auto, deepseek, moonshot, kimi, kimiWork, zhipu, newAPI, sub2api, custom, unavailable
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
        case .sub2api: return "Sub2API 令牌、订阅与钱包额度"
        case .custom: return "自定义余额接口"
        case .unavailable: return "不查询余额"
        }
    }
}

extension Channel {
    /// Resolve the balance adapter without guessing that every custom relay is
    /// a New API installation.  Unknown relays stay unconfigured until the user
    /// selects a known adapter or enters a custom path.
    var effectiveBalanceMode: BalanceMode {
        if isKimiWork { return .kimiWork }
        guard balanceMode == .auto else { return balanceMode }
        guard let host = URLComponents(string: baseURL)?.host?.lowercased() else { return .unavailable }
        switch host {
        case "api.deepseek.com": return .deepseek
        case "api.moonshot.cn", "api.moonshot.ai": return .moonshot
        case "api.kimi.com", "api.kimi.ai": return .kimi
        case "open.bigmodel.cn", "api.z.ai": return .zhipu
        case "api.openai.com", "api.anthropic.com", "api.x.ai": return .unavailable
        default: return .unavailable
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
    /// 从中转站导入链接接入时记录站点名和后台地址；Key 的充值、更换和明细仍在中转站管理。
    var relaySite = ""
    var manageURL = ""
    /// Per upstream model ID, as reported by the provider's /models when last queried.
    var capabilities: [String: ModelCapability] = [:]
    var workModels: [String: KimiWorkModel] = [:]
    var isKimiWork: Bool { ["kimi-work", "kimi-work-desktop"].contains(credentialSource) }

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
                throw BridgeError.message("请先登录 Kimi Work；该通道只能使用独立 Work 网关。")
            }
            value.apiKey = ""
            value.balanceMode = .kimiWork
        } else {
            guard !value.apiKey.isEmpty else { throw BridgeError.message("请填写 API Key。") }
            guard value.balanceMode != .kimiWork else { throw BridgeError.message("Work 会员额度仅用于 Kimi Work 通道。") }
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
        value.relaySite = String(relaySite.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        value.manageURL = manageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.manageURL.isEmpty {
            guard let page = URL(string: value.manageURL), ["http", "https"].contains(page.scheme ?? ""), page.host != nil,
                  page.user == nil, page.password == nil else {
                throw BridgeError.message("中转站管理页请填写完整的 HTTP(S) 地址，也可以留空。")
            }
        }
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
        if isKimiWork {
            value["headers"] = ["User-Agent": "BridgeDock", "X-Kimi-Model-Speed": "$X-Kimi-Model-Speed",
                                "X-Kimi-Context-Length": "$X-Kimi-Context-Length"]
            value["models"] = models.map { model -> [String: Any] in
                var entry: [String: Any] = model
                if let work = workModels[model["name"] ?? ""] {
                    entry["display-name"] = work.displayName
                    entry["max-context-length"] = work.capability.contextLength
                    if let efforts = work.capability.reasoningEfforts { entry["thinking"] = ["levels": efforts] }
                }
                return entry
            }
        }
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
    /// 上游自己给档位起的名字（如 Work 的“标准 / 进阶 / 极致”、Cursor 的 displayName）；没有时界面显示档位 ID。
    var reasoningLabels: [String: String]?
    var defaultEffort: String?

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
        let contextValues: [Any?] = [value["context_length"], value["contextLength"], nested["context_length"], nested["contextLength"],
                                      value["inputTokenLimit"], value["input_token_limit"], value["context_window"], value["contextWindow"],
                                      value["max_context_length"], value["maxContextLength"], value["max_input_tokens"]]
        contextLength = contextValues.compactMap(positive).first
        let outputValues: [Any?] = [value["max_completion_tokens"], value["maxCompletionTokens"], nested["max_output_tokens"],
                                     nested["maxOutputTokens"], value["outputTokenLimit"], value["output_token_limit"], value["max_output_tokens"]]
        maxOutputTokens = outputValues.compactMap(positive).first
        var levels: [String]?
        if let thinking = value["thinking"] as? [String: Any] {
            // 只认明确列出的档位；只有预算范围时不猜 low/medium/high。
            if let named = thinking["levels"] as? [String], !named.isEmpty { levels = named }
            if thinking["zero_allowed"] as? Bool == true, let current = levels, !current.contains("none") { levels = ["none"] + current }
        }
        var preferred: String?
        if let kimi = (value["think_efforts"] as? [String: Any]), kimi["support"] as? Bool != false,
           let valid = kimi["valid_efforts"] as? [String], !valid.isEmpty {
            levels = valid
            preferred = kimi["default_effort"] as? String
        }
        if let effort = (value["reasoning"] as? [String: Any])?["effort"] as? [String: Any] {
            preferred = preferred ?? effort["default"] as? String
        }
        if let advertised = nested["reasoning_effort"] as? [String], !advertised.isEmpty { levels = advertised }
        if let advertised = value["reasoning_effort"] as? [String], !advertised.isEmpty { levels = advertised }
        if let advertised = value["reasoning_effort"] as? String, !advertised.isEmpty { levels = [advertised] }
        if let advertised = value["reasoningEffort"] as? [String], !advertised.isEmpty { levels = advertised }
        if let advertised = value["reasoningEffort"] as? String, !advertised.isEmpty { levels = [advertised] }
        if let options = value["reasoningEffortOptions"] as? [[String: Any]], !options.isEmpty {
            var labels: [String: String] = [:]
            levels = options.compactMap { option in
                guard let effort = (option["effort"] as? String)?.replacingOccurrences(of: "REASONING_EFFORT_", with: "").lowercased() else { return nil }
                if let name = option["displayName"] as? String, !name.isEmpty { labels[effort] = name }
                return effort
            }
            reasoningLabels = labels.isEmpty ? nil : labels
        }
        reasoningEfforts = levels.map(Self.sortedEfforts).flatMap { $0.isEmpty ? nil : $0 }
        defaultEffort = preferred.map { $0.lowercased() }.flatMap { reasoningEfforts?.contains($0) == true ? $0 : nil }
        if let vision = nested["supports_vision"] as? Bool ?? nested["supportsVision"] as? Bool
            ?? value["supports_image_in"] as? Bool ?? value["supportsImages"] as? Bool {
            supportsVision = vision
        }
        else if let inputs = value["supportedInputModalities"] as? [String] ?? (value["modalities"] as? [String: Any])?["input"] as? [String] {
            supportsVision = inputs.contains("image")
        }
        if isEmpty { return nil }
    }

    init(contextLength: Int? = nil, maxOutputTokens: Int? = nil, reasoningEfforts: [String]? = nil, supportsVision: Bool? = nil,
         reasoningLabels: [String: String]? = nil, defaultEffort: String? = nil) {
        self.contextLength = contextLength; self.maxOutputTokens = maxOutputTokens
        self.reasoningEfforts = reasoningEfforts.map(Self.sortedEfforts); self.supportsVision = supportsVision
        self.reasoningLabels = reasoningLabels.flatMap { $0.isEmpty ? nil : $0 }; self.defaultEffort = defaultEffort
    }

    func label(ofEffort effort: String) -> String { reasoningLabels?[effort] ?? effort }

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

/// Work advertises speed and context separately from the model's wire ID.
struct KimiWorkModel: Codable, Equatable {
    var displayName: String
    var capability: ModelCapability
    var speeds: [String]
    var defaultSpeed: String
    var contexts: [Int]
    var defaultContext: Int?
    var defaultEffort: String?

    var supportsFast: Bool { speeds.contains("standard") && speeds.contains("fast") }

    func headers(parameters: [String: String], incoming: [String: String] = [:]) throws -> [String: String] {
        guard Set(parameters.keys).isSubset(of: ["fast", "context", "reasoning"]) else {
            throw BridgeError.message("Kimi Work 不支持所选参数。")
        }
        var speed = incoming["x-kimi-model-speed"] ?? defaultSpeed
        if let fast = parameters["fast"] {
            guard supportsFast, ["true", "false"].contains(fast) else {
                throw BridgeError.message("该 Work 模型或账号不支持 Fast，请刷新模型列表。")
            }
            speed = fast == "true" ? "fast" : "standard"
        }
        var headers: [String: String] = [:]
        if !speed.isEmpty {
            guard speeds.contains(speed) else { throw BridgeError.message("当前 Work 账号不支持所选速度。") }
            headers["x-kimi-model-speed"] = speed
        }
        let context = parameters["context"] ?? incoming["x-kimi-context-length"] ?? defaultContext.map(String.init)
        if let context {
            guard let size = Int(context), contexts.contains(size) else {
                throw BridgeError.message("当前 Work 账号不支持所选上下文长度。")
            }
            headers["x-kimi-context-length"] = String(size)
        }
        if let effort = parameters["reasoning"], capability.reasoningEfforts?.contains(effort) != true {
            throw BridgeError.message("当前 Work 模型不支持思考档位 \(effort)。")
        }
        return headers
    }

    var pickerMetadata: [String: Any] {
        var definitions: [[String: Any]] = []
        var dimensions: [(String, [String], String)] = []
        if supportsFast {
            definitions.append(["id": "fast", "name": "快速模式", "values": [["id": "false", "label": "关"], ["id": "true", "label": "开"]]])
            dimensions.append(("fast", ["false", "true"], defaultSpeed == "fast" ? "true" : "false"))
        }
        if let defaultContext, !contexts.isEmpty {
            definitions.append(["id": "context", "name": "上下文", "values": contexts.map { ["id": String($0), "label": $0 >= 1_000_000 ? "1M" : "\($0 / 1024)K"] }])
            dimensions.append(("context", contexts.map(String.init), String(defaultContext)))
        }
        if let efforts = capability.reasoningEfforts, !efforts.isEmpty {
            definitions.append(["id": "reasoning", "name": "思考强度", "values": efforts.map { ["id": $0, "label": capability.label(ofEffort: $0)] }])
            dimensions.append(("reasoning", efforts, defaultEffort ?? efforts[0]))
        }
        var combinations: [[String: String]] = [[:]]
        for (key, values, _) in dimensions {
            combinations = combinations.flatMap { current in values.map { value in var row = current; row[key] = value; return row } }
        }
        let variants: [[String: Any]] = combinations.map { row in
            let isDefault = dimensions.allSatisfy { row[$0.0] == $0.2 }
            return ["parameterValues": row.keys.sorted().map { ["id": $0, "value": row[$0]!] },
                    "isDefaultNonMaxConfig": isDefault, "isDefaultMaxConfig": isDefault]
        }
        return ["version": 1, "definitions": definitions, "variants": variants]
    }
}

/// Cursor exposes reasoning levels as variants of one model. Keep the exact
/// wire IDs so choosing an effort changes only that parameter on the same account.
struct CursorModelRoute {
    let defaultModelID: String
    let modelsByEffort: [String: String]
    let defaultEffort: String?
    let capability: ModelCapability
    var parameterDefinitions: [[String: Any]] = []
    var variants: [CursorParameterVariant] = []
    /// 合并进这个基础模型的全部真实 slug（含前缀），用于旧 ID 迁移和发布筛选。
    var memberModelIDs: [String] = []

    /// 普通速度下可选的上下文档位（token 数）。
    var contextOptions: [Int] {
        Array(Set(variants.compactMap { $0.parameters["context"].flatMap(Int.init) })).sorted()
    }
    var supportsFast: Bool { Set(variants.compactMap { $0.parameters["fast"] }) == ["false", "true"] }
    var defaultParameters: [String: String] { variants.first { $0.modelID == defaultModelID }?.parameters ?? [:] }

    /// Cursor 原生 version 1 的 variants 描述，放在 provider 级别供运行时按需使用。
    var pickerMetadata: [String: Any]? {
        guard !parameterDefinitions.isEmpty, !variants.isEmpty else { return nil }
        return ["version": 1, "definitions": parameterDefinitions, "variants": variants.map { variant in
            ["parameterValues": variant.parameters.keys.sorted().map { ["id": $0, "value": variant.parameters[$0]!] },
             "isDefaultNonMaxConfig": variant.modelID == defaultModelID,
             "isDefaultMaxConfig": variant.modelID == defaultModelID] as [String: Any]
        }]
    }

    func modelID(parameters: [String: String]) throws -> String {
        guard let current = variants.first(where: { $0.modelID == defaultModelID }) else {
            return try modelID(effort: parameters["reasoning"])
        }
        var requested = current.parameters
        for (key, value) in parameters {
            guard requested[key] != nil else { throw BridgeError.message("此 Cursor 模型不支持参数 \(key)。") }
            requested[key] = value
        }
        let matches = Set(variants.filter { $0.parameters == requested }.map(\.modelID))
        if matches.contains(defaultModelID) { return defaultModelID }
        guard matches.count == 1, let model = matches.first else {
            throw BridgeError.message("此 Cursor 账号不支持所选参数组合，请刷新模型列表后重新选择。")
        }
        return model
    }

    static func normalizedEffort(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "extra-high" ? "xhigh" : value
    }

    func modelID(effort: String?) throws -> String {
        guard let effort, !effort.isEmpty else { return defaultModelID }
        let normalized = Self.normalizedEffort(effort)
        guard let model = modelsByEffort[normalized] else {
            let supported = ModelCapability.sortedEfforts(Array(modelsByEffort.keys)).joined(separator: " / ")
            throw BridgeError.message("此 Cursor 模型不支持思考强度 \(normalized)，可选档位为 \(supported.isEmpty ? "无" : supported)。")
        }
        return model
    }

    func modelID(body: [String: Any], path: String) throws -> String {
        let value: Any?
        if path.hasPrefix("/v1/messages") {
            value = (body["output_config"] as? [String: Any])?["effort"]
        } else if path.hasPrefix("/v1/responses") {
            value = (body["reasoning"] as? [String: Any])?["effort"]
        } else {
            value = body["reasoning_effort"]
        }
        guard value == nil || value is String || value is NSNull else {
            throw BridgeError.message("思考强度必须是有效的档位名称。")
        }
        return try modelID(effort: value as? String)
    }
}

struct CursorParameterVariant {
    let modelID: String
    let parameters: [String: String]
}

struct CursorModelCatalog: Decodable {
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }

    private static func first<T: Decodable>(_ container: KeyedDecodingContainer<Key>, _ keys: [String], _ type: T.Type) -> T? {
        for key in keys { if let value = try? container.decodeIfPresent(type, forKey: Key(key)) { return value } }
        return nil
    }

    private static func firstInt(_ container: KeyedDecodingContainer<Key>, _ keys: [String]) -> Int? {
        if let value = first(container, keys, Int.self) { return value }
        return first(container, keys, String.self).flatMap(Int.init)
    }

    struct Parameter: Decodable {
        let id: String
        let value: String

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            id = CursorModelCatalog.first(c, ["id", "name", "parameter", "key"], String.self) ?? ""
            value = CursorModelCatalog.first(c, ["value", "selectedValue", "selected_value"], String.self) ?? ""
        }
    }

    struct Variant: Decodable {
        let parameterValues: [Parameter]?
        let legacySlug: String?
        let isMaxMode: Bool?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            parameterValues = CursorModelCatalog.first(c, ["parameterValues", "parameter_values", "parameters", "parameter_values_list"], [Parameter].self)
            legacySlug = CursorModelCatalog.first(c, ["legacySlug", "legacy_slug", "modelId", "model_id", "slug", "id", "name"], String.self)
            isMaxMode = CursorModelCatalog.first(c, ["isMaxMode", "is_max_mode", "maxMode", "max_mode", "isMax"], Bool.self)
        }

        var parameters: [String: String] {
            (parameterValues ?? []).reduce(into: [:]) { $0[$1.id] = $1.value }
        }
    }

    struct Model: Decodable {
        let name: String
        let family: String?
        let baseModel: String?
        let contextTokenLimit: Int?
        let supportsImages: Bool?
        let variants: [Variant]?
        let parameterDefinitions: [ParameterDefinition]?

        init(name: String, family: String?, baseModel: String?, contextTokenLimit: Int?, supportsImages: Bool?,
             variants: [Variant]?, parameterDefinitions: [ParameterDefinition]?) {
            self.name = name; self.family = family; self.baseModel = baseModel; self.contextTokenLimit = contextTokenLimit
            self.supportsImages = supportsImages; self.variants = variants; self.parameterDefinitions = parameterDefinitions
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            name = CursorModelCatalog.first(c, ["name", "modelName", "model_name", "id", "modelId", "model_id"], String.self) ?? ""
            family = CursorModelCatalog.first(c, ["family", "modelFamily", "model_family"], String.self)
            baseModel = CursorModelCatalog.first(c, ["baseModel", "base_model", "base", "canonicalName", "canonical_name"], String.self)
            contextTokenLimit = CursorModelCatalog.firstInt(c, ["contextTokenLimit", "context_token_limit", "contextLength", "context_length", "contextWindow", "context_window"])
            supportsImages = CursorModelCatalog.first(c, ["supportsImages", "supports_images", "supportsVision", "supports_vision"], Bool.self)
            variants = CursorModelCatalog.first(c, ["variants", "modelVariants", "model_variants", "configs"], [Variant].self)
            parameterDefinitions = CursorModelCatalog.first(c, ["parameterDefinitions", "parameter_definitions", "parameters", "parameterOptions"], [ParameterDefinition].self)
        }
    }

    struct ParameterDefinition: Decodable {
        struct Choice: Decodable {
            let value: String
            let displayName: String?
            let increasesModelCost: Bool?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Key.self)
                value = CursorModelCatalog.first(c, ["value", "id", "key"], String.self) ?? ""
                displayName = CursorModelCatalog.first(c, ["displayName", "display_name", "label", "name"], String.self)
                increasesModelCost = CursorModelCatalog.first(c, ["increasesModelCost", "increases_model_cost"], Bool.self)
            }
        }
        struct Choices: Decodable {
            let values: [Choice]
            init(from decoder: Decoder) throws {
                if var array = try? decoder.unkeyedContainer() {
                    var result: [Choice] = []
                    while !array.isAtEnd { result.append(try array.decode(Choice.self)) }
                    values = result
                } else {
                    let c = try decoder.container(keyedBy: Key.self)
                    values = CursorModelCatalog.first(c, ["values", "choices", "options"], [Choice].self) ?? []
                }
            }
        }
        struct ParameterType: Decodable {
            let enumParameter: Choices?
            let booleanParameter: Choices?

            init(enumParameter: Choices?, booleanParameter: Choices?) {
                self.enumParameter = enumParameter; self.booleanParameter = booleanParameter
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Key.self)
                enumParameter = CursorModelCatalog.first(c, ["enumParameter", "enum_parameter", "enum", "select"], Choices.self)
                booleanParameter = CursorModelCatalog.first(c, ["booleanParameter", "boolean_parameter", "boolean", "toggle"], Choices.self)
            }
        }
        let id: String
        let name: String?
        let markdownTooltip: String?
        let isCycleableByHotkey: Bool?
        let parameterType: ParameterType

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            id = CursorModelCatalog.first(c, ["id", "name", "parameter"], String.self) ?? ""
            name = CursorModelCatalog.first(c, ["name", "displayName", "display_name", "label"], String.self)
            markdownTooltip = CursorModelCatalog.first(c, ["markdownTooltip", "markdown_tooltip", "tooltip"], String.self)
            isCycleableByHotkey = CursorModelCatalog.first(c, ["isCycleableByHotkey", "is_cycleable_by_hotkey", "cycleable"], Bool.self)
            parameterType = CursorModelCatalog.first(c, ["parameterType", "parameter_type", "type"], ParameterType.self) ?? ParameterType(enumParameter: nil, booleanParameter: nil)
        }

        func metadata(variants: [CursorParameterVariant]) -> [String: Any]? {
            let key = CursorModelCatalog.parameterID(id)
            let allowed = Set(variants.compactMap { $0.parameters[key] })
            let choices = parameterType.enumParameter ?? parameterType.booleanParameter
            let values: [[String: Any]] = (choices?.values ?? []).compactMap { choice in
                let value = CursorModelCatalog.parameterValue(id: key, value: choice.value)
                guard allowed.contains(value) else { return nil }
                var result: [String: Any] = ["value": value]
                if let displayName = choice.displayName { result["displayName"] = displayName }
                if let increasesModelCost = choice.increasesModelCost { result["increasesModelCost"] = increasesModelCost }
                return result
            }
            guard !values.isEmpty else { return nil }
            var result: [String: Any] = ["id": key, "name": name ?? id,
                "parameterType": [parameterType.booleanParameter == nil ? "enumParameter" : "booleanParameter": ["values": values]]]
            if let markdownTooltip { result["markdownTooltip"] = markdownTooltip }
            if let isCycleableByHotkey { result["isCycleableByHotkey"] = isCycleableByHotkey }
            return result
        }
    }

    let models: [Model]
    private static let effortKeys: Set<String> = ["reasoning", "reasoning_effort", "effort"]

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            var result: [Model] = []
            while !array.isAtEnd { result.append(try array.decode(Model.self)) }
            models = result
            return
        }
        let c = try decoder.container(keyedBy: Key.self)
        var result: [Model] = []
        for key in ["models", "data", "items", "results", "availableModels", "available_models", "catalog", "result", "response", "payload"] {
            let rows = try? c.decode([Model].self, forKey: Key(key))
            if let rows { result += rows }
            if rows == nil && ["data", "result", "response", "payload", "catalog"].contains(key),
               let nested = try? c.superDecoder(forKey: Key(key)),
               let catalog = try? CursorModelCatalog(from: nested) {
                result += catalog.models
            }
        }
        if result.isEmpty {
            for key in ["models", "data", "items"] {
                if let map = try? c.decode([String: Model].self, forKey: Key(key)) {
                    result += map.map { name, model in
                        if model.name.isEmpty { return Model(name: name, family: model.family, baseModel: model.baseModel,
                                                             contextTokenLimit: model.contextTokenLimit, supportsImages: model.supportsImages,
                                                             variants: model.variants, parameterDefinitions: model.parameterDefinitions) }
                        return model
                    }
                }
            }
        }
        models = result
    }

    private static func parameterID(_ id: String) -> String { effortKeys.contains(id) ? "reasoning" : id }

    private static func parameterValue(id: String, value: String) -> String {
        if id == "context", let size = contextLength(value) { return String(size) }
        return id == "reasoning" ? CursorModelRoute.normalizedEffort(value) : value
    }

    /// 从 legacySlug 末尾剥掉思考强度、thinking 和 fast 后缀，得到版本号级的基础名。
    static func baseName(ofSlug slug: String) -> String {
        let suffixes = ["-extra-high", "-highspeed", "-high-speed", "-thinking", "-minimal", "-medium", "-xhigh", "-fast", "-none", "-high", "-low", "-max"]
        var name = slug
        while let suffix = suffixes.first(where: { name.lowercased().hasSuffix($0) && name.count > $0.count }) {
            name = String(name.dropLast(suffix.count))
        }
        return name
    }

    /// 每个基础模型只产出一个路由，键为 `前缀/基础名`；各 variant 的真实 slug 保存在路由内部。
    func routes(prefix: String, availableModelIDs: Set<String>) -> [String: CursorModelRoute] {
        func fullID(_ name: String) -> String { prefix.isEmpty ? name : prefix + "/" + name }
        func available(_ name: String) -> Bool {
            let target = fullID(name)
            if availableModelIDs.contains(target) { return true }
            let normalized = name.lowercased().replacingOccurrences(of: "_", with: "-")
            return availableModelIDs.contains { id in
                let tail = String(id.split(separator: "/", maxSplits: 1).last!).lowercased().replacingOccurrences(of: "_", with: "-")
                return tail == normalized
            }
        }
        func actual(_ name: String) -> String {
            let target = fullID(name)
            if availableModelIDs.contains(target) { return target }
            let normalized = name.lowercased().replacingOccurrences(of: "_", with: "-")
            return availableModelIDs.first { id in
                let tail = String(id.split(separator: "/", maxSplits: 1).last!).lowercased().replacingOccurrences(of: "_", with: "-")
                return tail == normalized
            } ?? target
        }
        func effort(of variant: Variant) -> String? {
            variant.parameters.first(where: { Self.effortKeys.contains($0.key) }).map { CursorModelRoute.normalizedEffort($0.value) }
        }
        var result: [String: CursorModelRoute] = [:]
        for model in models {
            let variants = (model.variants ?? []).filter {
                $0.isMaxMode != true && $0.legacySlug.map { available($0) } == true
            }
            guard !variants.isEmpty else {
                let id = fullID(model.family ?? model.baseModel ?? model.name)
                if result[id] == nil, available(model.name) {
                    result[id] = CursorModelRoute(defaultModelID: fullID(model.name), modelsByEffort: [:], defaultEffort: nil,
                                                  capability: ModelCapability(contextLength: model.contextTokenLimit,
                                                                              supportsVision: model.supportsImages),
                                                  memberModelIDs: [fullID(model.name)])
                }
                continue
            }
            let parameterVariants = variants.compactMap { variant -> CursorParameterVariant? in
                guard let slug = variant.legacySlug else { return nil }
                var parameters: [String: String] = [:]
                for (id, value) in variant.parameters {
                    let key = Self.parameterID(id)
                    parameters[key] = Self.parameterValue(id: key, value: value)
                }
                return CursorParameterVariant(modelID: actual(slug), parameters: parameters)
            }
            let parameterDefinitions = (model.parameterDefinitions ?? []).compactMap { $0.metadata(variants: parameterVariants) }
            // 默认 variant：普通速度优先，其次 medium 档，再按档位顺序与 slug 排序，保证结果稳定。
            let rank = { (variant: Variant) -> (Int, Int, String) in
                let fast = variant.parameters["fast"] == "true" ? 1 : 0
                let level = effort(of: variant).map {
                    $0 == "medium" ? -1 : $0 == "none" ? 100 : (ModelCapability.effortOrder.firstIndex(of: $0) ?? 99)
                } ?? -2
                return (fast, level, variant.legacySlug ?? "")
            }
            let primary = variants.min { rank($0) < rank($1) }!
            // Fast、上下文与思考强度互相独立；按思考强度换 slug 时不能顺带改变其他维度。
            let lane = { (variant: Variant) in
                variant.parameters.filter { !Self.effortKeys.contains($0.key) }.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }
            }
            var byEffort: [String: String] = [:]
            var ambiguous: Set<String> = []
            for variant in variants where lane(variant) == lane(primary) {
                guard let slug = variant.legacySlug, let key = effort(of: variant) else { continue }
                if let existing = byEffort[key], existing != actual(slug) { ambiguous.insert(key) }
                byEffort[key] = actual(slug)
            }
            for key in ambiguous { byEffort.removeValue(forKey: key) }
            let efforts = Set(variants.compactMap(effort(of:)))
            let contexts = parameterVariants.compactMap { $0.parameters["context"].flatMap(Int.init) }
            let defaultContext = Self.contextLength(primary.parameters["context"]) ?? model.contextTokenLimit
            let context = contexts.max() ?? defaultContext
            var labels: [String: String] = [:]
            for definition in model.parameterDefinitions ?? [] where Self.parameterID(definition.id) == "reasoning" {
                for choice in definition.parameterType.enumParameter?.values ?? [] {
                    if let name = choice.displayName, !name.isEmpty { labels[CursorModelRoute.normalizedEffort(choice.value)] = name }
                }
            }
            let capability = ModelCapability(contextLength: context.flatMap { $0 > 0 ? $0 : nil },
                                             reasoningEfforts: efforts.isEmpty ? nil : Array(efforts),
                                             supportsVision: model.supportsImages, reasoningLabels: labels)
            let base = model.family ?? model.baseModel ?? Self.baseName(ofSlug: primary.legacySlug!)
            let id = fullID(base)
            guard result[id] == nil else { continue }
            result[id] = CursorModelRoute(defaultModelID: actual(primary.legacySlug!), modelsByEffort: byEffort,
                                          defaultEffort: effort(of: primary), capability: capability,
                                          parameterDefinitions: parameterDefinitions, variants: parameterVariants,
                                          memberModelIDs: parameterVariants.map(\.modelID))
        }
        return result
    }

    /// Cursor's endpoint has changed field names several times.  When the
    /// parameter catalog is unavailable, infer the same standard dimensions
    /// from the executable slugs that the core already exposes.  This keeps a
    /// non-standard name callable while still giving the selector one base
    /// model and separate Fast / reasoning options.
    static func inferredRoutes(prefix: String, availableModelIDs: Set<String>) -> [String: CursorModelRoute] {
        func fullID(_ name: String) -> String { prefix.isEmpty ? name : prefix + "/" + name }
        let names = availableModelIDs.compactMap { id -> String? in
            let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 ? parts[0] == prefix : prefix.isEmpty else { return nil }
            return parts.last
        }
        var grouped: [String: [String]] = [:]
        for name in names {
            let base = baseName(ofSlug: name)
            let lower = name.lowercased()
            let hasDimension = name != base || lower.hasSuffix("-fast") || lower.hasSuffix("-highspeed")
            if hasDimension { grouped[base, default: []].append(name) }
        }
        var result: [String: CursorModelRoute] = [:]
        for (base, values) in grouped where values.count > 1 {
            var variants: [CursorParameterVariant] = []
            var efforts: Set<String> = []
            var hasFast = false
            for name in Set(values).sorted() {
                let lower = name.lowercased()
                var parameters: [String: String] = [:]
                if lower.hasSuffix("-fast") || lower.hasSuffix("-highspeed") || lower.contains("-fast-") || lower.contains("-highspeed-") {
                    parameters["fast"] = "true"; hasFast = true
                } else if hasFast || values.count > 2 { parameters["fast"] = "false" }
                let suffix = String(name.dropFirst(base.count)).lowercased()
                let effort: String?
                if suffix.contains("extra-high") { effort = "xhigh" }
                else if suffix.contains("xhigh") { effort = "xhigh" }
                else if suffix.contains("medium") { effort = "medium" }
                else if suffix.contains("minimal") || suffix.contains("low") { effort = "low" }
                else if suffix.contains("max") { effort = "max" }
                else if suffix.contains("high") || suffix.contains("thinking") { effort = "high" }
                else if suffix.contains("none") { effort = "none" }
                else { effort = nil }
                if let effort { parameters["reasoning"] = effort; efforts.insert(effort) }
                variants.append(CursorParameterVariant(modelID: fullID(name), parameters: parameters))
            }
            guard !variants.isEmpty else { continue }
            // A route with only a Fast pair still needs a default `fast=false`
            // lane so requests can explicitly switch back to the normal model.
            if hasFast {
                variants = variants.map { variant in
                    var value = variant
                    if value.parameters["fast"] == nil {
                        var parameters = value.parameters; parameters["fast"] = "false"
                        value = CursorParameterVariant(modelID: value.modelID, parameters: parameters)
                    }
                    return value
                }
            }
            let preferred = variants.first(where: { $0.modelID == fullID(base) && $0.parameters["fast"] != "true" })
                ?? variants.first(where: { $0.parameters["fast"] != "true" && $0.parameters["reasoning"] == "medium" })
                ?? variants.first(where: { $0.parameters["fast"] != "true" }) ?? variants[0]
            var byEffort: [String: String] = [:]
            for variant in variants where variant.parameters["fast"] == preferred.parameters["fast"] {
                if let effort = variant.parameters["reasoning"] { byEffort[effort] = variant.modelID }
            }
            var definitions: [[String: Any]] = []
            if hasFast { definitions.append(["id": "fast", "name": "快速模式", "parameterType": ["booleanParameter": ["values": [["value": "false", "displayName": "关"], ["value": "true", "displayName": "开"]]]]]) }
            if !efforts.isEmpty {
                definitions.append(["id": "reasoning", "name": "思考强度", "parameterType": ["enumParameter": ["values": ModelCapability.sortedEfforts(Array(efforts)).map { ["value": $0, "displayName": $0] }]]])
            }
            let context = ModelCapability(contextLength: nil, reasoningEfforts: efforts.isEmpty ? nil : Array(efforts))
            result[fullID(base)] = CursorModelRoute(defaultModelID: preferred.modelID, modelsByEffort: byEffort,
                                                    defaultEffort: preferred.parameters["reasoning"], capability: context,
                                                    parameterDefinitions: definitions, variants: variants,
                                                    memberModelIDs: variants.map(\.modelID))
        }
        return result
    }

    private static func contextLength(_ value: String?) -> Int? {
        guard let value = value?.lowercased(), value.count < 16 else { return nil }
        let multiplier = value.hasSuffix("m") ? 1_000_000.0 : value.hasSuffix("k") ? 1_000.0 : 1.0
        let number = multiplier == 1 ? value : String(value.dropLast())
        guard let parsed = Double(number), parsed.isFinite, parsed > 0, parsed * multiplier <= 100_000_000 else { return nil }
        return Int(parsed * multiplier)
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
    /// 内核路由 ID → 长上下文检测实测通过的上下文档位（token）。
    var verifiedContexts: [String: [Int]] = [:]
    /// 把中转站“导入 CC Switch”按钮发出的 ccswitch:// 链接交给 BridgeDock 打开。
    var handlesImportLinks = true

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
            // The core otherwise injects a hidden image_generation tool into chat requests; clients such as
            // Cursor ignore the returned images and treat the turn as empty. /v1/images/* stays enabled.
            "multimedia": ["disable-image-generation": "chat"],
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
        relaySite = try c.decodeIfPresent(String.self, forKey: .relaySite) ?? ""
        manageURL = try c.decodeIfPresent(String.self, forKey: .manageURL) ?? ""
        capabilities = (try? c.decodeIfPresent([String: ModelCapability].self, forKey: .capabilities)) ?? [:]
        workModels = (try? c.decodeIfPresent([String: KimiWorkModel].self, forKey: .workModels)) ?? [:]
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
        verifiedContexts = (try? c.decodeIfPresent([String: [Int]].self, forKey: .verifiedContexts)) ?? [:]
        handlesImportLinks = try c.decodeIfPresent(Bool.self, forKey: .handlesImportLinks) ?? d.handlesImportLinks
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
    let managedByBridgeDock: Bool
    let credentialOrigin: String
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
        // Credentials are stored under BridgeDock's private data directory.
        // Older account files predate this marker, so they are treated as
        // managed when they are already present in the BD account store.
        managedByBridgeDock = value["bridgedock_managed"] as? Bool ?? true
        credentialOrigin = value["bridgedock_origin"] as? String ?? "BridgeDock 账号目录"
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
