import Foundation

struct ModelDiscovery {
    let channel: Channel
    let modelLines: String
    let notice: String
    var capabilities: [String: ModelCapability] = [:]
}

struct ModelListRequest {
    let url: String
    let headers: [String: String]
    init(channel: Channel) throws {
        let channel = Self.normalized(channel)
        var base = channel.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base), ["http", "https"].contains(url.scheme ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw BridgeError.message("请先填写有效的 Base URL。")
        }
        let key = channel.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw BridgeError.message("请填写有效的 API Key。") }
        let isKimiCode = Preset.matching(channel)?.id.hasPrefix("kimi-code") == true
        let suffix = (isKimiCode || channel.wire == .anthropic) && !base.hasSuffix("/v1") ? "/v1/models" : "/models"
        self.url = base + suffix
        // Kimi's documented model-list endpoint uses Bearer for either inference protocol.
        if channel.wire == .anthropic && !isKimiCode {
            headers = ["x-api-key": key, "anthropic-version": "2023-06-01", "User-Agent": "BridgeDock/1.3.1"]
        } else {
            headers = ["Authorization": "Bearer " + key, "User-Agent": "BridgeDock/1.3.1"]
        }
    }
    static func normalized(_ channel: Channel) -> Channel {
        guard let preset = Preset.matching(channel),
              let url = URLComponents(string: channel.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return channel }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var result = channel
        if path.isEmpty && ["codex", "kimi", "kimi-ai", "grok"].contains(preset.id) {
            result.baseURL = preset.url
        } else if preset.id.hasPrefix("kimi-code"), path == "coding", channel.wire != .anthropic {
            result.baseURL = preset.url
        }
        return result
    }
    static func names(in value: [String: Any]) -> [String] {
        let rows = value["data"] as? [[String: Any]] ?? value["models"] as? [[String: Any]] ?? []
        return Array(Set(rows.compactMap { ($0["id"] as? String ?? $0["slug"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
    static func capabilities(in value: [String: Any]) -> [String: ModelCapability] {
        let rows = value["data"] as? [[String: Any]] ?? value["models"] as? [[String: Any]] ?? []
        var result: [String: ModelCapability] = [:]
        for row in rows {
            guard let id = (row["id"] as? String ?? row["slug"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                  let capability = ModelCapability(definition: row) else { continue }
            result[id] = capability
        }
        return result
    }
    static func kimiAlternative(for channel: Channel) -> Channel? {
        guard let preset = Preset.matching(channel) else { return nil }
        let alternative: String
        switch preset.id {
        case "kimi": alternative = "kimi-code"
        case "kimi-ai": alternative = "kimi-code-ai"
        case "kimi-code": alternative = "kimi"
        case "kimi-code-ai": alternative = "kimi-ai"
        default: return nil
        }
        let target = Preset.all.first { $0.id == alternative }!
        var next = channel
        next.kind = target.title
        if next.name == preset.title || next.name == "Kimi Code 国内" || next.name == "Kimi Code 订阅 Key" { next.name = target.title }
        next.baseURL = target.url; next.wire = target.wire
        if next.balanceMode != .custom { next.balanceMode = target.balanceMode }
        return next
    }
}
