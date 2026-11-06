import Foundation

enum KimiWorkCatalog {
    static let endpoint = "https://www.kimi.com/apiv2/kimi.gateway.config.v1.ConfigService/DescribeKimiWorkConfig"

    /// Accepts the current Work configuration, the older /models payload, and the
    /// official desktop's normalized cache during one-time migration.
    static func parse(_ payload: [String: Any]) throws -> [String: KimiWorkModel] {
        let rows = (payload["models"] as? [[String: Any]] ?? payload["data"] as? [[String: Any]] ?? [])
            + (payload["moreModels"] as? [[String: Any]] ?? [])
        var result: [String: KimiWorkModel] = [:]
        for row in rows {
            let request = row["requestParams"] as? [String: Any] ?? row
            let config = row["daimonModelConfig"] as? [String: Any] ?? [:]
            let display = row["display"] as? [String: Any] ?? row
            guard let id = request["modelId"] as? String ?? row["id"] as? String,
                  id.range(of: "^[a-zA-Z0-9._-]{1,128}$", options: .regularExpression) != nil,
                  result[id] == nil else { continue }
            if let mode = request["agentMode"] as? String, !["TYPE_NORMAL", "TYPE_UNSPECIFIED"].contains(mode) { continue }
            let maximum = (config["maxContextSize"] as? Int) ?? (row["context_length"] as? Int)
            let options = request["reasoningEffortOptions"] as? [[String: Any]] ?? []
            let efforts = options.compactMap { ($0["effort"] as? String)?.replacingOccurrences(of: "REASONING_EFFORT_", with: "").lowercased() }
            var labels: [String: String] = [:]
            for (option, effort) in zip(options.filter { $0["effort"] is String }, efforts) {
                if let name = option["displayName"] as? String, !name.isEmpty { labels[effort] = name }
            }
            let validEfforts = ModelCapability.sortedEfforts(efforts.isEmpty ? config["supportEfforts"] as? [String] ?? [] : efforts)
            let advertisedDefault = (request["defaultReasoningEffort"] as? String)?.replacingOccurrences(of: "REASONING_EFFORT_", with: "").lowercased()
                ?? config["defaultEffort"] as? String
            let defaultEffort = advertisedDefault.flatMap { validEfforts.contains($0) ? $0 : nil } ?? validEfforts.first
            let speedOptions = row["speedOptions"] as? [[String: Any]] ?? []
            let speeds = speedOptions.filter { $0["available"] as? Bool == true }.compactMap { $0["speedValue"] as? String }
                .filter { ["standard", "fast"].contains($0) }
            let defaultSpeed = row["defaultSpeedValue"] as? String ?? ""
            var contexts: [Int] = []
            for option in request["contextLengthOptions"] as? [[String: Any]] ?? [] where option["available"] as? Bool == true {
                switch option["contextLength"] as? String {
                case "CONTEXT_LENGTH_L": if let maximum, maximum > 0 { contexts.append(min(262144, maximum)) }
                case "CONTEXT_LENGTH_XL": if let maximum, maximum > 0 { contexts.append(maximum) }
                default: break
                }
            }
            // Unknown context controls are not advertised. The maximum alone is
            // still useful capability information, but is not a request default.
            contexts = Array(Set(contexts)).sorted()
            let defaultContext = request["defaultContextLength"] as? String == "CONTEXT_LENGTH_XL" ? contexts.last : contexts.first
            let capabilities = config["capabilities"] as? [String] ?? []
            let capability = ModelCapability(contextLength: contexts.max() ?? maximum,
                                             reasoningEfforts: validEfforts.isEmpty ? nil : validEfforts,
                                             supportsVision: row["supports_image_in"] as? Bool ?? (capabilities.isEmpty ? nil : capabilities.contains("image_in")),
                                             reasoningLabels: labels, defaultEffort: defaultEffort)
            result[id] = KimiWorkModel(displayName: display["displayName"] as? String ?? row["display_name"] as? String ?? id,
                                      capability: capability, speeds: speeds,
                                      defaultSpeed: speeds.contains(defaultSpeed) ? defaultSpeed : speeds.first ?? "",
                                      contexts: contexts, defaultContext: defaultContext, defaultEffort: defaultEffort)
        }
        guard !result.isEmpty else { throw BridgeError.message("Work 未返回可用模型，请重新登录后刷新。") }
        return result
    }

    static func merging(_ names: [String], into lines: String) -> String {
        let existing = Set(lines.components(separatedBy: .newlines).compactMap {
            $0.split(separator: "=", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespaces) }
        })
        let added = names.filter { !existing.contains($0) }.sorted()
        return ([lines.trimmingCharacters(in: .whitespacesAndNewlines)] + added).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func desktopCache(accountHash: String) -> [String: KimiWorkModel]? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/kimi-desktop/kimi-agent/kimi-work-models-cache.json")
        guard let data = try? Data(contentsOf: url), data.count <= KimiWorkSession.maximumFileSize,
              let caches = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for (key, value) in caches where key.hasPrefix("latest:") {
            let userID = String(key.dropFirst(7))
            if KimiWorkSession.digest("kimi-work-account\0" + userID) == accountHash,
               let payload = value as? [String: Any] { return try? parse(payload) }
        }
        return nil
    }
}
