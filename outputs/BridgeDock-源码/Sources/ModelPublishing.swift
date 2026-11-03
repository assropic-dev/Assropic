import Foundation
import CryptoKit

struct PublishedModel: Identifiable {
    /// The core's stable, unmodified routing identifier; persisted selections use this value.
    let id: String
    let publicID: String
    let sourceID: String
    let sourceName: String
    let modelName: String
    let owner: String
    let isEnabled: Bool
    let metadata: [String: Any]
    var capability: ModelCapability? = nil
}

struct ModelPublicationGroup: Identifiable {
    let id: String
    let name: String
    let models: [PublishedModel]
}

enum ModelPublishing {
    private struct Source {
        let key: String
        let name: String
        let prefix: String
    }

    /// Core definition sets by `owned_by`. Account models use their own vendor's set
    /// first, since the same model name can carry different limits through Kiro.
    static let definitionChannel = ["openai": "codex", "anthropic": "claude", "moonshot": "kimi", "google": "gemini"]

    /// Channel records win over core definitions; both are keyed by the upstream model
    /// name. An alias line `upstream = alias` keeps the upstream name's capability.
    static func capability(for raw: ModelItem, settings: AppSettings, definitions: [String: [String: ModelCapability]]) -> ModelCapability? {
        let routed = raw.id.contains("/") ? String(raw.id.split(separator: "/", maxSplits: 1)[1]) : raw.id
        func lookup(_ name: String, in set: [String: ModelCapability]?) -> ModelCapability? {
            guard let found = set?[name] ?? set?[name.lowercased()], found.contextLength != nil else { return nil }
            return found
        }
        func anywhere(_ name: String) -> ModelCapability? {
            for key in definitions.keys.sorted() { if let found = lookup(name, in: definitions[key]) { return found } }
            return nil
        }
        if let channel = settings.channels.first(where: { $0.enabled && raw.id.hasPrefix($0.prefix + "/") }) {
            let upstream = channel.models.first { $0["alias"] == routed }?["name"] ?? routed
            if let recorded = channel.capabilities[upstream] ?? channel.capabilities[routed] { return recorded }
            return lookup(upstream, in: definitions[channel.wire.configKey]) ?? anywhere(upstream)
        }
        let owner = raw.owner.lowercased()
        return lookup(routed, in: definitions[definitionChannel[owner] ?? owner]) ?? anywhere(routed)
    }

    static func catalog(rawModels: [ModelItem], settings: AppSettings, accounts: [Account],
                        definitions: [String: [String: ModelCapability]] = [:]) -> [PublishedModel] {
        var sources = settings.channels.filter(\.enabled).map { Source(key: "channel:" + $0.id, name: $0.name, prefix: $0.prefix) }
        // Accounts sharing a routing prefix form one upstream pool in the core.
        for account in accounts.filter({ !$0.disabled }).sorted(by: { $0.id < $1.id }) {
            guard !account.prefix.isEmpty, !sources.contains(where: { $0.prefix == account.prefix }) else { continue }
            let name = account.note.isEmpty ? account.providerTitle : account.note
            sources.append(Source(key: "account:" + account.id, name: name, prefix: account.prefix))
        }
        let sortedRaw = rawModels.sorted { $0.id < $1.id }
        // Older plugins may omit a prefix in their credential metadata. Keep the
        // actual core route as the identity and use its prefix as a display fallback.
        var assignments: [String: String] = [:]
        for raw in sortedRaw {
            if let existing = sources.filter({ !$0.prefix.isEmpty && raw.id.hasPrefix($0.prefix + "/") }).max(by: { $0.prefix.count < $1.prefix.count }) {
                assignments[raw.id] = existing.key
                continue
            }
            let hasPrefix = raw.id.contains("/")
            let prefix = hasPrefix ? String(raw.id.split(separator: "/", maxSplits: 1)[0]) : ""
            let key = hasPrefix ? "route:" + prefix : "provider:" + raw.owner
            if !sources.contains(where: { $0.key == key }) {
                let label = hasPrefix ? prefix : (SubscriptionProvider.find(raw.owner)?.title ?? (raw.owner.isEmpty ? "订阅渠道" : raw.owner))
                sources.append(Source(key: key, name: label, prefix: prefix))
            }
            assignments[raw.id] = key
        }
        func stem(_ name: String) -> String {
            let safe = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            return String((safe.isEmpty ? "渠道" : safe).prefix(4))
        }
        let groups = Dictionary(grouping: sources, by: { stem($0.name) })
        var prefixes: [String: String] = [:]
        for source in sources {
            let base = stem(source.name)
            // Resolve collisions by source, even if two sources currently expose
            // different models, so adding a model cannot silently rename the other.
            let suffix = groups[base, default: []].count > 1 ? "-" + SHA256.hash(data: Data(source.key.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined() : ""
            prefixes[source.key] = base + suffix
        }
        let selection = settings.publishedModelIDs.map(Set.init)
        var used: Set<String> = []
        return sortedRaw.compactMap { raw in
            guard used.insert(raw.id).inserted else { return nil }
            let source = sources.first { $0.key == assignments[raw.id] }
            let name: String
            if let source, !source.prefix.isEmpty, raw.id.hasPrefix(source.prefix + "/") { name = String(raw.id.dropFirst(source.prefix.count + 1)) }
            else { name = raw.id }
            let publicPrefix = source.flatMap { prefixes[$0.key] } ?? stem(raw.owner)
            var metadata = raw.metadata
            let capability = capability(for: raw, settings: settings, definitions: definitions)
            if let capability { metadata.merge(capability.catalogFields) { current, _ in current } }
            return PublishedModel(id: raw.id, publicID: publicPrefix + "/" + name,
                                  sourceID: source?.key ?? "provider:" + raw.owner,
                                  sourceName: source?.name ?? raw.owner, modelName: name, owner: raw.owner,
                                  isEnabled: selection?.contains(raw.id) ?? true, metadata: metadata, capability: capability)
        }.sorted { $0.publicID.localizedStandardCompare($1.publicID) == .orderedAscending }
    }

    /// Same labels as the Cursor picker in runtime.js.
    static func tokenLabel(_ value: Int) -> String {
        if value % 1_048_576 == 0 { return "\(value / 1_048_576)M" }
        if value % 1_000_000 == 0 { return "\(value / 1_000_000)M" }
        if value % 1024 == 0 && value < 1_048_576 { return "\(value / 1024)K" }
        return value >= 1_000_000 ? String(format: "%.1fM", Double(value) / 1_000_000) : "\(Int((Double(value) / 1000).rounded()))K"
    }

    static func capabilitySummary(_ capability: ModelCapability?) -> String {
        guard let capability else { return "上下文与思考强度未知 · Cursor 中不显示剩余上下文" }
        let context = capability.contextLength.map { "上下文 " + tokenLabel($0) } ?? "上下文未知"
        let efforts = capability.reasoningEfforts?.filter { $0 != "none" } ?? []
        return context + " · " + (efforts.isEmpty ? "不支持思考强度" : "思考 " + efforts.joined(separator: " / "))
    }

    static func groups(in catalog: [PublishedModel], search: String = "", selected: Set<String>? = nil) -> [ModelPublicationGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = catalog.filter { model in
            (selected?.contains(model.id) ?? true) &&
                (query.isEmpty || [model.sourceName, model.publicID, model.modelName, model.id].contains {
                    $0.localizedCaseInsensitiveContains(query)
                })
        }
        return Dictionary(grouping: visible, by: \.sourceID).map { id, models in
            ModelPublicationGroup(id: id, name: models[0].sourceName, models: models.sorted {
                $0.modelName.localizedStandardCompare($1.modelName) == .orderedAscending
            })
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
