import Foundation

/// 一次网页登录取得的令牌。Sub2API 每次刷新都会换发新的 refresh_token，旧的随即作废。
struct RelaySession: Codable, Equatable {
    var siteID: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    /// 登录令牌有效期为 24 小时；剩余不到 2 小时就刷新，刷新令牌也随之续期。
    func needsRefresh(now: Date = Date()) -> Bool { expiresAt.timeIntervalSince(now) < 2 * 3600 }
}

struct RelaySessionStore {
    let directory: URL

    init(dataDirectory: URL) { directory = dataDirectory.appendingPathComponent("relay-sites") }

    private func file(_ siteID: String) throws -> URL {
        guard siteID.range(of: "^[a-z0-9-]{8,64}$", options: .regularExpression) != nil else {
            throw BridgeError.message("中转站标识无效，请重新登录。")
        }
        return directory.appendingPathComponent(siteID + ".json")
    }

    func read(_ siteID: String) throws -> RelaySession {
        let url = try file(siteID)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.intValue ?? Int.max < 1_000_000,
              let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(RelaySession.self, from: data),
              session.siteID == siteID, !session.accessToken.isEmpty, !session.refreshToken.isEmpty else {
            throw BridgeError.message("Assropic 没有这个中转站的登录，请重新网页登录。")
        }
        return session
    }

    func save(_ session: RelaySession) throws {
        try privateWrite(JSONEncoder().encode(session), to: file(session.siteID))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    func delete(_ siteID: String) {
        guard let url = try? file(siteID) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

struct RelayGroup: Identifiable, Equatable {
    let id: Int
    let name: String
    let platform: String
    let models: [String]
    let rateMultiplier: Double?
    let description: String
    let active: Bool

    init?(_ object: [String: Any]) {
        guard let id = Sub2API.int(object["id"]), id > 0 else { return nil }
        self.id = id
        name = object["name"] as? String ?? "分组 \(id)"
        platform = (object["platform"] as? String ?? "").lowercased()
        models = (object["models"] as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        rateMultiplier = Sub2API.double(object["rate_multiplier"])
        description = object["description"] as? String ?? ""
        active = (object["status"] as? String ?? "active") == "active"
    }

    var wire: WireProtocol? { Sub2API.wire(platform: platform) }
    var title: String {
        var text = name
        if let rateMultiplier { text += " · ×" + Sub2API.amount(rateMultiplier) }
        return text
    }
}

struct RelayKey: Identifiable, Equatable {
    let id: Int
    let name: String
    let key: String
    let status: String
    let groupID: Int
    let group: RelayGroup?
    let quota: Double
    let quotaUsed: Double
    let expiresAt: Date?
    let lastUsedAt: Date?

    init?(_ object: [String: Any]) {
        guard let id = Sub2API.int(object["id"]), id > 0 else { return nil }
        self.id = id
        name = object["name"] as? String ?? ""
        key = (object["key"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        status = (object["status"] as? String ?? "").lowercased()
        groupID = Sub2API.int(object["group_id"]) ?? 0
        group = (object["group"] as? [String: Any]).flatMap(RelayGroup.init)
        quota = Sub2API.double(object["quota"]) ?? 0
        quotaUsed = Sub2API.double(object["quota_used"]) ?? 0
        expiresAt = Sub2API.date(object["expires_at"])
        lastUsedAt = Sub2API.date(object["last_used_at"])
    }

    /// 明文 Key 才能接入；有的站点会把列表里的 Key 打码。
    var usable: Bool { key.hasPrefix("sk-") && !key.contains("*") && !key.contains(where: \.isWhitespace) }
    var managedByBridgeDock: Bool { Sub2API.isManagedKeyName(name) }

    /// 停用、到期或额度用完的 Key 已不能调用。
    func exhausted(now: Date = Date()) -> Bool {
        if status != "active" { return true }
        if let expiresAt, expiresAt <= now { return true }
        return quota > 0 && quotaUsed >= quota
    }
}

struct RelayAccount: Equatable {
    var balance: Double?
    var frozen: Double?
    var totalRecharged: Double?
    var concurrency: Int?
    var status = ""
    var todayCost: Double?
    var totalCost: Double?
    var todayRequests: Int?
}

/// 一次请求的计费记录（GET /usage），用于和模型接口返回的 usage 对账。
struct RelayUsageLog: Equatable {
    let model: String
    let createdAt: Date?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let rateMultiplier: Double?
    let totalCost: Double?

    init?(_ object: [String: Any]) {
        guard let model = object["model"] as? String else { return nil }
        self.model = model
        createdAt = Sub2API.date(object["created_at"])
        inputTokens = Sub2API.int(object["input_tokens"]) ?? 0
        outputTokens = Sub2API.int(object["output_tokens"]) ?? 0
        cacheReadTokens = Sub2API.int(object["cache_read_tokens"]) ?? 0
        cacheCreationTokens = Sub2API.int(object["cache_creation_tokens"]) ?? 0
        rateMultiplier = Sub2API.double(object["rate_multiplier"])
        totalCost = Sub2API.double(object["total_cost"])
    }

    var promptTokens: Int { inputTokens + cacheReadTokens + cacheCreationTokens }
}

/// Sub2API 用户端接口（/api/v1）的解析与渠道构造。只包含纯逻辑，便于单独测试。
enum Sub2API {
    /// New keys use the Assropic brand; the legacy prefix remains managed so
    /// existing installations continue to rotate their previously issued keys.
    static let managedKeyPrefix = "Assropic"
    static let legacyManagedKeyPrefix = "BridgeDock"
    static func isManagedKeyName(_ name: String) -> Bool {
        name.hasPrefix(managedKeyPrefix) || name.hasPrefix(legacyManagedKeyPrefix)
    }

    /// 用户输入的站点地址只保留 scheme + host + port，例如 “aiportx.com/dashboard” → https://aiportx.com。
    static func origin(_ text: String) throws -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "https://" + value }
        guard var parts = URLComponents(string: value), let host = parts.host?.lowercased(), !host.isEmpty,
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""), parts.user == nil, parts.password == nil else {
            throw BridgeError.message("请填写中转站后台地址，例如 https://www.aiportx.com。")
        }
        guard parts.scheme?.lowercased() == "https" || ["localhost", "127.0.0.1"].contains(host) else {
            throw BridgeError.message("中转站登录只支持 HTTPS 地址。")
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? value
    }

    /// Sub2API 的响应统一为 {code, message, data}；code 不为 0 视为失败。
    static func data(_ payload: [String: Any]) throws -> Any {
        if let code = int(payload["code"]), code != 0 {
            let message = payload["message"] as? String ?? "请求未成功"
            throw BridgeError.message("中转站返回：" + String(message.prefix(200)))
        }
        return payload["data"] ?? payload
    }

    /// settings/public 带 site_name / version 等字段且含 Sub2API 特有的登录开关，才按 Sub2API 处理。
    static func looksLikeSub2API(_ settings: [String: Any]) -> Bool {
        settings["turnstile_enabled"] != nil && (settings["site_name"] != nil || settings["version"] != nil)
            && (settings["linuxdo_oauth_enabled"] != nil || settings["registration_email_suffix_whitelist"] != nil || settings["passkey_enabled"] != nil)
    }

    static func keys(_ data: Any) -> (keys: [RelayKey], pages: Int) {
        let object = data as? [String: Any] ?? [:]
        let items = object["items"] as? [[String: Any]] ?? (data as? [[String: Any]] ?? [])
        return (items.compactMap(RelayKey.init), int(object["pages"]) ?? 1)
    }

    static func groups(_ data: Any) -> [RelayGroup] {
        let items = data as? [[String: Any]] ?? ((data as? [String: Any])?["items"] as? [[String: Any]] ?? [])
        return items.compactMap(RelayGroup.init)
    }

    static func usageLogs(_ data: Any) -> [RelayUsageLog] {
        ((data as? [String: Any])?["items"] as? [[String: Any]] ?? []).compactMap(RelayUsageLog.init)
    }

    static func account(me: [String: Any], stats: [String: Any]?) -> RelayAccount {
        RelayAccount(balance: double(me["balance"]), frozen: double(me["frozen_balance"]),
                     totalRecharged: double(me["total_recharged"]), concurrency: int(me["concurrency"]),
                     status: me["status"] as? String ?? "",
                     todayCost: double(stats?["today_actual_cost"]), totalCost: double(stats?["total_actual_cost"]),
                     todayRequests: int(stats?["today_requests"]))
    }

    /// 分组平台 → Assropic 渠道协议。与站点“导入 CC Switch”按钮一致：Claude 走 Messages，GPT 走 Responses。
    static func wire(platform: String) -> WireProtocol? {
        switch platform.lowercased() {
        case "anthropic", "claude", "antigravity": return .anthropic
        case "openai", "codex": return .responses
        case "grok", "xai": return .xai
        default: return nil
        }
    }

    /// 新建 Key 的请求体，字段与站点前端一致。
    static func createBody(name: String, groupID: Int, quota: Double?, expiresInDays: Int?) -> [String: Any] {
        var body: [String: Any] = ["name": name, "group_id": groupID]
        if let quota, quota > 0 { body["quota"] = quota }
        if let expiresInDays, expiresInDays > 0 { body["expires_in_days"] = expiresInDays }
        return body
    }

    static func managedKeyName(now: Date = Date()) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "MMdd-HHmmss"
        return managedKeyPrefix + "-" + format.string(from: now)
    }

    /// 把一个 Key 变成 Assropic 渠道；同一 Key 已接入时返回更新后的原渠道。
    static func channel(for key: RelayKey, group explicitGroup: RelayGroup?, site: RelaySite,
                        existing: [Channel], accounts: [Account]) throws -> Channel {
        guard key.usable else { throw BridgeError.message("这个 Key 在列表中被打码或无效，无法接入。请在站点上复制完整 Key 后手动添加。") }
        let group = explicitGroup ?? key.group
        guard let group else { throw BridgeError.message("这个 Key 没有分组，无法判断协议。") }
        guard let wire = group.wire else {
            throw BridgeError.message("分组“\(group.name)”的平台是 \(group.platform.isEmpty ? "未知" : group.platform)，Assropic 暂不支持这种协议。")
        }
        let endpoint = site.apiBaseURL.isEmpty ? site.origin : site.apiBaseURL
        let base = CCSwitchLink.baseURL(endpoint, wire: wire)
        // 优先用站点 + Key ID 定位；旧版本没有写 ID 时，再在同一站点按 Key 回退。
        // 最后的空站点回退只兼容早期通过 CC Switch 导入的渠道，避免同一 Key 在不同站点间串线。
        var channel = existing.first { $0.relaySiteID == site.id && $0.relayKeyID == key.id && !site.id.isEmpty }
            ?? existing.first { $0.relaySiteID == site.id && $0.relayKeyID == 0 && $0.apiKey == key.key && $0.wire == wire }
            ?? existing.first { $0.relaySiteID.isEmpty && $0.apiKey == key.key && $0.wire == wire }
            ?? Channel()
        let isNew = channel.apiKey.isEmpty
        if isNew {
            channel.name = site.title + " · " + group.name
            channel.prefix = Channel.unusedPrefix(CCSwitchLink.prefix(forHost: URLComponents(string: base)?.host ?? site.host),
                                                  channels: existing, accounts: accounts)
            channel.proxyURL = site.proxyURL
        }
        channel.kind = "中转站登录 · " + site.title
        channel.wire = wire
        channel.baseURL = base
        channel.apiKey = key.key
        if !group.models.isEmpty {
            // 保留用户写过的别名，只补上分组新增的模型。
            let known = Set(channel.models.compactMap { $0["name"] })
            let added = group.models.filter { !known.contains($0) }
            let current = channel.modelLines.trimmingCharacters(in: .whitespacesAndNewlines)
            channel.modelLines = ([current].filter { !$0.isEmpty } + added).joined(separator: "\n")
        }
        channel.balanceMode = .sub2api
        channel.relaySite = String(site.title.prefix(60))
        channel.manageURL = site.keysPage
        channel.relaySiteID = site.id
        channel.relayKeyID = key.id
        channel.relayGroupID = group.id
        return channel
    }

    // MARK: - Value parsing

    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double, value.isFinite { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    /// Sub2API 的时间带微秒和时区，例如 2026-11-06T22:26:16.367075+08:00；先去掉小数秒再解析。
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let trimmed = text.replacingOccurrences(of: "\\.[0-9]+", with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }

    /// 站点 Logo 可能是相对路径或 data: 地址；只保留能安全加载的 https 地址。
    static func logoURL(_ value: Any?, origin: String) -> String {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count < 2000 else { return "" }
        let absolute = text.hasPrefix("/") && !text.hasPrefix("//") ? origin + text : text
        guard let parts = URLComponents(string: absolute), parts.scheme == "https", parts.host != nil, parts.user == nil else { return "" }
        return absolute
    }

    static func amount(_ value: Double) -> String {
        let text = String(format: "%.4f", value)
        var result = text
        while result.contains("."), result.hasSuffix("0") { result.removeLast() }
        if result.hasSuffix(".") { result.removeLast() }
        return result
    }
}
