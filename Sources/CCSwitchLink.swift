import Foundation

/// 中转站“导入 CC Switch”按钮生成的链接：ccswitch://v1/import?resource=provider&app=…&endpoint=…&apiKey=…
/// 参数按 CC Switch 的 deeplink/parser.rs 解析；Assropic 只取能变成一条 API 渠道的部分。
struct CCSwitchLink {
    let resource: String
    let app: String
    let name: String
    let endpoint: String
    let apiKey: String
    let homepage: String
    let model: String
    let apiFormat: String
    let usageEnabled: Bool
    let usageScript: String

    init(_ url: URL) throws {
        guard url.scheme?.lowercased() == "ccswitch",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.host?.lowercased() == "v1", parts.path == "/import" else {
            throw BridgeError.message("无法识别这个 CC Switch 链接，只支持 ccswitch://v1/import。")
        }
        let query = Self.formValues(parts.percentEncodedQuery ?? "")
        resource = query["resource"] ?? ""
        app = (query["app"] ?? "").lowercased()
        apiFormat = (query["apiFormat"] ?? "").lowercased()
        homepage = query["homepage"] ?? ""
        usageEnabled = query["usageEnabled"].map { $0.lowercased() != "false" } ?? true
        usageScript = query["usageScript"].map(Self.base64Text) ?? ""
        let config = Self.embeddedConfig(query)
        name = (query["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        endpoint = query["endpoint"].flatMap { $0.isEmpty ? nil : $0 } ?? config["endpoint"] ?? ""
        apiKey = (query["apiKey"].flatMap { $0.isEmpty ? nil : $0 } ?? config["apiKey"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        model = (query["model"].flatMap { $0.isEmpty ? nil : $0 } ?? config["model"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// URLSearchParams 把空格写成 +，base64 里的 + 则写成 %2B，所以先换 + 再解码。
    static func formValues(_ encoded: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in encoded.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: "%20").removingPercentEncoding ?? String($0)
            }
            guard let key = parts.first, !key.isEmpty, result[key] == nil else { continue }
            result[key] = parts.count == 2 ? parts[1] : ""
        }
        return result
    }

    static func base64Text(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text), let decoded = String(data: data, encoding: .utf8) else { return value }
        return decoded
    }

    /// 只给 endpoint/apiKey、改用 config 传配置的链接：Claude 的 env JSON，或 Codex 的 auth + TOML。
    private static func embeddedConfig(_ query: [String: String]) -> [String: String] {
        guard let raw = query["config"], !raw.isEmpty else { return [:] }
        let text = base64Text(raw)
        var result: [String: String] = [:]
        var toml = text
        if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let env = object["env"] as? [String: Any] ?? [:]
            result["endpoint"] = env["ANTHROPIC_BASE_URL"] as? String
            result["apiKey"] = env["ANTHROPIC_AUTH_TOKEN"] as? String ?? env["ANTHROPIC_API_KEY"] as? String
                ?? (object["auth"] as? [String: Any])?["OPENAI_API_KEY"] as? String
            result["model"] = env["ANTHROPIC_MODEL"] as? String
            toml = object["config"] as? String ?? ""
        }
        func tomlValue(_ key: String) -> String? {
            guard let range = toml.range(of: "(?m)^\\s*" + key + "\\s*=\\s*\"([^\"]+)\"", options: .regularExpression) else { return nil }
            return toml[range].split(separator: "\"", omittingEmptySubsequences: false).dropFirst().first.map(String.init)
        }
        result["endpoint"] = result["endpoint"] ?? tomlValue("base_url")
        result["model"] = result["model"] ?? tomlValue("model")
        return result.compactMapValues { $0 }
    }

    var appTitle: String {
        switch app {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "grokbuild": return "Grok"
        case "opencode": return "OpenCode"
        case "openclaw": return "OpenClaw"
        case "hermes": return "Hermes"
        case "pi": return "Pi"
        default: return app
        }
    }

    /// apiFormat 写明时以它为准，否则按目标客户端的原生协议。
    var wire: WireProtocol? {
        switch apiFormat {
        case "anthropic": return .anthropic
        case "openai_chat": return .chat
        case "openai_responses": return .responses
        case "gemini_native": return nil
        default: break
        }
        switch app {
        case "claude": return .anthropic
        case "codex": return .responses
        case "grokbuild": return .xai
        case "opencode", "openclaw", "hermes", "pi": return .chat
        default: return nil
        }
    }

    /// Anthropic 客户端会自己拼 /v1/messages，地址里的 v1 段要去掉；OpenAI 系的根地址补上 /v1。
    static func baseURL(_ endpoint: String, wire: WireProtocol) -> String {
        var value = endpoint.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        while value.hasSuffix("/") { value.removeLast() }
        guard var parts = URLComponents(string: value), parts.host != nil else { return value }
        let segments = parts.path.split(separator: "/").map(String.init)
        if wire == .anthropic {
            let kept = segments.filter { $0.lowercased() != "v1" }
            parts.path = kept.isEmpty ? "" : "/" + kept.joined(separator: "/")
        } else if segments.isEmpty {
            parts.path = "/v1"
        }
        return parts.string ?? value
    }

    static func prefix(forHost host: String) -> String {
        var labels = host.lowercased().split(separator: ".").map(String.init)
        if labels.count > 2, ["api", "www", "gateway", "gw", "relay", "open"].contains(labels[0]) { labels.removeFirst() }
        let cleaned = String((labels.first ?? "").filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(24))
        return cleaned.isEmpty ? "relay" : cleaned
    }

    var balanceMode: BalanceMode {
        guard usageEnabled else { return .auto }
        if usageScript.contains("/v1/usage") { return .sub2api }
        if usageScript.contains("/api/usage/token") || usageScript.contains("/api/user/self") { return .newAPI }
        return .auto
    }

    /// 链接不带后台地址。homepage 指向接口域名时，按站点域名推断：Sub2API 的令牌管理页固定为 /keys。
    func manageURL(baseURL: String) -> String {
        let given = URLComponents(string: homepage.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil ? $0 : nil }
        guard var page = given ?? URLComponents(string: baseURL), var host = page.host?.lowercased() else { return "" }
        page.user = nil
        page.password = nil
        let path = page.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard given == nil || path.isEmpty || path == "v1" else { return page.string ?? "" }
        if host.hasPrefix("api."), host.split(separator: ".").count > 2 { host.removeFirst(4) }
        page.host = host
        page.path = balanceMode == .sub2api ? "/keys" : ""
        page.query = nil
        page.fragment = nil
        return page.string ?? ""
    }

    func channelImport(existing: [Channel], accounts: [Account]) throws -> ChannelImport {
        guard resource == "provider" else {
            throw BridgeError.message("Assropic 只导入服务商链接；这个链接的类型是 \(resource.isEmpty ? "未知" : resource)。")
        }
        guard let wire else {
            throw BridgeError.message(app == "gemini" || app == "agy" || apiFormat == "gemini_native"
                ? "Assropic 暂不支持 Gemini 原生协议的渠道。请在中转站选择 Claude Code 或 Codex 客户端后重新导入。"
                : "无法识别链接的目标客户端“\(app)”。请在中转站选择 Claude Code 或 Codex 客户端后重新导入。")
        }
        guard !apiKey.isEmpty, !apiKey.contains("\n"), !apiKey.contains("\r") else {
            throw BridgeError.message("导入链接没有带有效的 API Key，请在中转站重新点击导入。")
        }
        let base = Self.baseURL(endpoint, wire: wire)
        guard let url = URLComponents(string: base), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil else {
            throw BridgeError.message("导入链接里的接口地址无效，请在中转站重新点击导入。")
        }
        let site = name.isEmpty ? host : String(name.prefix(40))
        let modelLine = model.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
        if let found = existing.first(where: { $0.apiKey == apiKey && $0.wire == wire && $0.baseURL == base }) {
            var channel = found
            if channel.relaySite.isEmpty { channel.relaySite = site }
            if channel.manageURL.isEmpty { channel.manageURL = manageURL(baseURL: base) }
            return ChannelImport(channel: channel, site: site, existingName: found.name)
        }
        var channel = Channel()
        channel.name = site + " · " + appTitle
        channel.kind = "中转站导入 · " + site
        channel.wire = wire
        channel.baseURL = base
        channel.apiKey = apiKey
        channel.modelLines = modelLine
        channel.balanceMode = balanceMode
        channel.relaySite = site
        channel.manageURL = manageURL(baseURL: base)
        channel.prefix = Channel.unusedPrefix(Self.prefix(forHost: host), channels: existing, accounts: accounts)
        return ChannelImport(channel: channel, site: site, existingName: nil)
    }
}

struct ChannelImport: Identifiable {
    let id = UUID()
    let channel: Channel
    let site: String
    /// 同一中转站、同一 Key、同一协议已经接入过时，保存会更新这条渠道。
    let existingName: String?
}
