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
            headers = ["x-api-key": key, "anthropic-version": "2023-06-01", "User-Agent": "Assropic/1.3.1"]
        } else {
            headers = ["Authorization": "Bearer " + key, "User-Agent": "Assropic/1.3.1"]
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
        let rows = rows(in: value)
        return Array(Set(rows.compactMap(modelID(in:)).filter { !$0.isEmpty })).sorted()
    }
    static func capabilities(in value: [String: Any]) -> [String: ModelCapability] {
        let rows = rows(in: value)
        var result: [String: ModelCapability] = [:]
        for row in rows {
            guard let id = modelID(in: row), !id.isEmpty else { continue }
            var definition = row
            // A number of providers put capabilities under `model`, `metadata`
            // or `capability` while keeping the ID at the outer level.
            for key in ["model", "metadata", "capability"] {
                if let nested = row[key] as? [String: Any] { definition.merge(nested) { current, _ in current } }
            }
            guard let capability = ModelCapability(definition: definition) else { continue }
            result[id] = capability
        }
        return result
    }

    /// OpenAI's `data` array is only one of the shapes returned by model
    /// registries.  Keep this parser deliberately permissive: the raw ID is
    /// preserved for routing, while the surrounding fields are used for the
    /// standard capability model.
    private static func rows(in value: [String: Any]) -> [[String: Any]] {
        let keys = ["data", "models", "items", "results", "model_list", "modelList", "available_models", "availableModels", "catalog"]
        for key in keys {
            if let rows = value[key] as? [[String: Any]], !rows.isEmpty { return rows }
            if let names = value[key] as? [String], !names.isEmpty { return names.map { ["id": $0] } }
            if let map = value[key] as? [String: Any] {
                let reserved = Set(["error", "errors", "message", "detail", "status", "status_code", "code", "success"])
                // Error envelopes sometimes reuse `data` or `models` for a
                // dictionary. Do not turn fields such as `error` and
                // `message` into fake model IDs; a map with other keys may
                // still be a legitimate name-to-definition catalogue.
                if map.keys.allSatisfy({ reserved.contains($0.lowercased()) }) { continue }
                let mapped = map.compactMap { name, entry -> [String: Any]? in
                    if var row = entry as? [String: Any] {
                        if modelID(in: row) == nil { row["id"] = name }
                        return row
                    }
                    return ["id": name]
                }
                if !mapped.isEmpty { return mapped }
            }
        }
        for key in ["result", "response", "payload"] {
            if let nested = value[key] as? [String: Any] {
                let nestedRows = rows(in: nested)
                if !nestedRows.isEmpty { return nestedRows }
            }
        }
        return []
    }

    private static func modelID(in row: [String: Any]) -> String? {
        if let nested = row["model"] as? [String: Any], let id = modelID(in: nested) { return id }
        let keys = ["id", "model", "model_id", "modelId", "slug", "name", "display_name", "displayName",
                    "model_name", "modelName", "canonical_name", "canonicalName", "identifier", "value"]
        for key in keys {
            if let value = row[key] as? String {
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        if let nested = row["model"] as? [String: Any] {
            for key in keys where key != "model" {
                if let value = nested[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
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
