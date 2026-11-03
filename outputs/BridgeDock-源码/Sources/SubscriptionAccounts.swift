import Foundation

struct SubscriptionProvider: Identifiable {
    let id: String
    let title: String
    let detail: String
    let sourceURL: String
    var importOnly = false
    var available: Bool {
        if id.hasPrefix("zcode-") {
            if #available(macOS 15.0, *) { return true }
            return false
        }
        return true
    }
    var unavailableReason: String { available ? "" : "ZCode 订阅插件需要 macOS 15 或更高版本；仍可使用 API 渠道中的 Coding Plan Key。" }
    var supportsCallback: Bool { ["claude", "codex"].contains(id) }
    var supportsLocalLogin: Bool { ["claude", "codex", "kiro"].contains(id) }
    // Only these handlers bind the refreshed identity to the selected file.
    var supportsRecovery: Bool { ["codex", "kiro", "zcode-bigmodel", "zcode-zai"].contains(id) }
    static let all: [SubscriptionProvider] = [
        .init(id: "claude", title: "Claude", detail: "Claude Pro / Max · 连接本机 Claude Code 登录，或浏览器授权", sourceURL: "https://github.com/router-for-me/CLIProxyAPI"),
        .init(id: "codex", title: "GPT / Codex", detail: "ChatGPT 订阅 · 连接本机 Codex 登录，或浏览器授权", sourceURL: "https://github.com/router-for-me/CLIProxyAPI"),
        .init(id: "kimi", title: "Kimi 国内", detail: "Kimi Code 国内账号 · 设备码授权", sourceURL: "https://github.com/router-for-me/CLIProxyAPI"),
        .init(id: "kimi-ai", title: "Kimi 国际", detail: "Kimi.ai Code 账号 · 设备码授权", sourceURL: "https://github.com/router-for-me/CLIProxyAPI"),
        .init(id: "kiro", title: "Kiro", detail: "连接本机 Kiro 登录（含 Google / GitHub），或使用 Builder ID / 组织授权", sourceURL: "https://github.com/xiaokui-dev/cliproxyapi-kiro-plugin"),
        .init(id: "cursor-agent-v1", title: "Cursor / Grok Bot", detail: "Grok Bot 使用 Cursor 网页授权 · 完成后自动保存账号", sourceURL: "https://github.com/enderzcx/cursor-agent2api"),
        .init(id: "xai", title: "Grok Build / xAI", detail: "Grok Build CLI · 独立设备码授权；Grok Bot 请使用 Cursor / Grok Bot 入口", sourceURL: "https://github.com/router-for-me/CLIProxyAPI"),
        .init(id: "zcode-bigmodel", title: "ZCode 国内", detail: "智谱 BigModel 个人订阅 · 浏览器授权", sourceURL: "https://github.com/WizisCool/omc-zcode-oauth"),
        .init(id: "zcode-zai", title: "ZCode 国际", detail: "Z.ai 个人订阅 · 浏览器授权", sourceURL: "https://github.com/WizisCool/omc-zcode-oauth")
    ]
    static func find(_ provider: String) -> SubscriptionProvider? {
        let normalized = provider == "anthropic" ? "claude" : (provider == "zcode" ? "zcode-zai" : provider)
        return all.first { $0.id == normalized }
    }
}

enum CursorAccountProfile: String, CaseIterable, Identifiable {
    case cursor = "agent_v1"
    case grokBot = "sand"

    static let providerID = "cursor-agent-v1"
    static let dashboardURL = URL(string: "https://cursor.com/dashboard/api")!
    var id: String { rawValue }
    var title: String { self == .cursor ? "Cursor" : "Grok Bot" }
    var prefix: String { self == .cursor ? "cursor" : "grok-bot" }

    func filename(digest: String) -> String {
        // Retain existing Cursor filenames; the same key may also serve Grok Bot.
        prefix + "-" + digest + ".json"
    }

    func credential(label: String, key: String, prefix: String) throws -> [String: Any] {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else {
            throw BridgeError.message("请填写完整的 Cursor 账号 Key，不要包含空格或换行。")
        }
        return ["type": Self.providerID, "api_key": key, "runtime_profile": rawValue,
                "note": label.trimmingCharacters(in: .whitespacesAndNewlines), "prefix": prefix]
    }
}

struct AccountOptions {
    var note: String
    var prefix: String
    var proxyURL: String
    var priority: Int
    init(account: Account, document: [String: Any]) {
        note = document["note"] as? String ?? account.note
        prefix = document["prefix"] as? String ?? ""
        proxyURL = document["proxy_url"] as? String ?? document["proxy-url"] as? String ?? ""
        priority = (document["priority"] as? NSNumber)?.intValue ?? Int(document["priority"] as? String ?? "") ?? account.priority
    }
    func fields(name: String) throws -> [String: Any] {
        let prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.isEmpty || prefix.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else {
            throw BridgeError.message("账号前缀请使用英文字母、数字、短横线或下划线。")
        }
        try validateProxyURL(proxy)
        return ["name": name, "note": note.trimmingCharacters(in: .whitespacesAndNewlines),
                "prefix": prefix, "proxy_url": proxy, "priority": priority]
    }
}

enum OAuthCallback {
    static func payload(_ text: String, session: LoginSession) throws -> [String: String] {
        guard Date() < session.expiresAt else {
            throw BridgeError.message("本次登录已超时，请取消后重新发起授权，不要使用旧页面的授权码。")
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var values: [String: String] = [:]
        if let url = URLComponents(string: text), url.scheme != nil, url.host != nil {
            // An authorization URL also contains state and, for Claude, code=true.
            // Reject it before extracting callback fields or consuming the session.
            let queryNames = Set((url.queryItems ?? []).map(\.name))
            let authorization = URLComponents(string: session.url)
            let sameAuthorizationPage = url.host?.lowercased() == authorization?.host?.lowercased()
                && url.path == authorization?.path
            guard queryNames.isDisjoint(with: ["response_type", "client_id", "code_challenge", "code_challenge_method", "redirect_uri"]),
                  !sameAuthorizationPage else {
                throw BridgeError.message("这是打开登录用的授权页面链接，还不是授权回调结果。请先在网页完成授权；若没有自动返回，再复制完成页面给出的 code#state，或跳转到 localhost 后的完整回调地址。")
            }
            for item in url.queryItems ?? [] where ["code", "state", "error"].contains(item.name) {
                guard values[item.name] == nil else { throw BridgeError.message("回调参数重复，请重新复制完整回调。") }
                values[item.name] = item.value ?? ""
            }
        } else if SubscriptionProvider.find(session.provider)?.id == "claude" {
            let parts = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { values = ["code": String(parts[0]), "state": String(parts[1])] }
        }
        guard values["code"] == nil || values["error"] == nil else {
            throw BridgeError.message("回调同时包含授权码和错误，请重新复制完整回调。")
        }
        guard values["state"] == session.state, !(values["code"] ?? values["error"] ?? "").isEmpty else {
            throw BridgeError.message("回调不属于当前登录会话，或缺少授权码。请复制本次授权返回的完整 URL\(session.provider == "claude" ? " 或 code#state" : "")。")
        }
        if let code = values["code"] {
            guard code.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
                  !["true", "false"].contains(code.lowercased()) else {
                throw BridgeError.message("没有识别到有效授权码。请完成网页授权后重新复制整段 code#state 或完整回调地址。")
            }
        }
        values["provider"] = session.provider
        return values
    }

    static func lifetime(provider: String, advertised: Double?) -> TimeInterval {
        // CLIProxyAPI's Claude and Codex handlers wait at most five minutes.
        let callbackFlow = ["claude", "codex", CursorAccountProfile.providerID].contains(SubscriptionProvider.find(provider)?.id ?? provider)
        guard let advertised, advertised.isFinite, advertised > 0 else { return callbackFlow ? 300 : 900 }
        return callbackFlow ? min(advertised, 300) : advertised
    }
}

enum CredentialImport {
    static func normalized(_ data: Data) throws -> Data {
        guard data.count <= 2_000_000,
              var value = try JSONSerialization.jsonObject(with: data) as? [String: Any], !value.isEmpty else {
            throw BridgeError.message("请选择不超过 2 MB 的账号凭据 JSON 对象。")
        }
        var provider = (value["type"] as? String ?? value["provider"] as? String ?? "").lowercased()
        if value["type"] == nil, value["accessToken"] is String, value["refreshToken"] is String { provider = "kiro" }
        if provider == "anthropic" { provider = "claude" }
        guard !provider.isEmpty else { throw BridgeError.message("凭据缺少 type/provider。请导入 CLIProxyAPI 格式，Kiro 也可导入原始 accessToken/refreshToken JSON。") }
        value["type"] = provider
        if provider == "zcode" {
            if let entry = SubscriptionProvider.find(provider), !entry.available {
                throw BridgeError.message(entry.unavailableReason)
            }
            guard ["zai", "bigmodel"].contains(value["site"] as? String ?? ""),
                  !(value["device"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ["key", "jwt"].contains(where: { !(value[$0] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw BridgeError.message("ZCode 凭据需要 site、device 和 key 或 jwt。建议使用对应门户的浏览器登录。")
            }
            return try jsonData(value)
        }
        if provider == "kiro" {
            if value["access_token"] == nil { value["access_token"] = value["accessToken"] }
            if value["refresh_token"] == nil { value["refresh_token"] = value["refreshToken"] }
            value["accessToken"] = value["access_token"]
            value["refreshToken"] = value["refresh_token"]
        }
        guard ["access_token", "refresh_token", "token", "api_key"].contains(where: { key in
            if let s = value[key] as? String { return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if let token = value[key] as? [String: Any] {
                return ["access_token", "refresh_token"].contains { !(token[$0] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
            return false
        }) else { throw BridgeError.message("凭据不包含可用的令牌。") }
        return try jsonData(value)
    }
}
