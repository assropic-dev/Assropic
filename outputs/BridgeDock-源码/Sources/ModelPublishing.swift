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
    var cursorRoute: CursorModelRoute? = nil
    var workModel: KimiWorkModel? = nil
    /// 同渠道 `X-highspeed` 的路由 ID；开启快速模式时改走它。
    var fastModelID: String? = nil
    /// 长上下文检测通过的档位；未检测为 nil。
    var verifiedContexts: [Int]? = nil
}

struct ModelPublicationGroup: Identifiable {
    let id: String
    let name: String
    let models: [PublishedModel]
}

enum ModelPublishing {
    /// Claude vendors spell the same version as either 5.5 or 5-5. Only the
    /// public identity is normalized; routing IDs and dated releases stay intact.
    static func publicModelID(_ name: String) -> String {
        name.replacingOccurrences(of: "^(claude-(?:opus|sonnet|haiku|fable)-[0-9]+)\\.([0-9]+)(?=-|$)",
                                  with: "$1-$2", options: .regularExpression)
    }

    static let highspeedSuffix = "-highspeed"

    /// Providers use several spellings for the same speed dimension.  Keep the
    /// executable ID untouched, but expose one standard model with a Fast
    /// parameter in the public catalog.
    private static let fastSuffixes = ["-highspeed", "-high-speed", "_highspeed", "-fast", "_fast", "-turbo", "-高速"]

    private static func speedBase(_ id: String) -> (base: String, isFast: Bool)? {
        let lower = id.lowercased()
        for suffix in fastSuffixes where lower.hasSuffix(suffix) && id.count > suffix.count {
            return (String(id.dropLast(suffix.count)), true)
        }
        return nil
    }

    static func fastBase(of id: String) -> String? {
        guard let pair = speedBase(id), pair.isFast else { return nil }
        return pair.base
    }

    private static func compatible(_ fast: ModelCapability?, _ normal: ModelCapability?, kimiLike: Bool) -> Bool {
        guard let fast, let normal else { return kimiLike }
        if let a = fast.contextLength, let b = normal.contextLength, a != b { return false }
        if let a = fast.maxOutputTokens, let b = normal.maxOutputTokens, a != b { return false }
        if let a = fast.reasoningEfforts, let b = normal.reasoningEfforts, a != b { return false }
        if let a = fast.supportsVision, let b = normal.supportsVision, a != b { return false }
        return true
    }

    /// 同一渠道里 `X-highspeed` 与 `X` 的上下文和思考档位一致时，它只是 X 的高速档。
    /// 能力不同的（如 Kimi 的 kimi-for-coding-highspeed 实为另一个模型）保持独立。
    static func highspeedPairs(_ raw: [ModelItem], settings: AppSettings,
                               definitions: [String: [String: ModelCapability]], excluded: Set<String>) -> [String: String] {
        let byID = Dictionary(raw.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byTail = Dictionary(raw.map { (String($0.id.split(separator: "/", maxSplits: 1).last!), $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: String] = [:]
        for item in raw {
            guard let pair = speedBase(item.id), pair.isFast, !excluded.contains(item.id) else { continue }
            let base = pair.base
            let normal = byID[base] ?? byTail[base] ?? raw.first(where: {
                let tail = String($0.id.split(separator: "/", maxSplits: 1).last!)
                return tail == base
            })
            guard let normal, !excluded.contains(normal.id) else { continue }
            let fast = capability(for: item, settings: settings, definitions: definitions) ?? ModelCapability(definition: item.metadata)
            let standard = capability(for: normal, settings: settings, definitions: definitions) ?? ModelCapability(definition: normal.metadata)
            let baseName = String(base.split(separator: "/", maxSplits: 1).last!).lowercased()
            // Kimi has shipped both `kimi-k3.1` and compact names such as
            // `kimiK3.1`; accept either spelling when metadata is absent so a
            // clearly paired high-speed slug still becomes the Fast option.
            let kimiGeneration = baseName.range(of: "k(?:2|3)(?:[.-]|$)", options: .regularExpression) != nil
            let kimiLike = kimiGeneration && !baseName.contains("for-coding")
            guard compatible(fast, standard, kimiLike: kimiLike) else { continue }
            let normalKey = normal.id.contains("/") ? normal.id : base
            result[normalKey] = item.id
        }
        return result
    }

    /// 长上下文检测的候选档位：上限以下最多三档，再加上限本身。
    static func contextBudgets(_ limit: Int) -> [Int] {
        guard limit > 0 else { return [] }
        let steps = [32768, 65536, 131072, 200000, 262144, 524288, 1000000, 2000000]
        let smaller = steps.filter { Double($0) < Double(limit) * 0.9 && $0 >= min(32768, limit / 8) }
        return Array(smaller.suffix(3)) + [limit]
    }

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
            guard let found = set?[name] ?? set?[name.lowercased()], !found.isEmpty else { return nil }
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
                        definitions: [String: [String: ModelCapability]] = [:],
                        cursorRoutes: [String: CursorModelRoute] = [:]) -> [PublishedModel] {
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
        let selection = settings.publishedModelIDs.map(Set.init)
        let sourceOrder = Dictionary(sources.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first })
        // Cursor 的各思考强度 slug 合并为一个基础模型路由，键为 `前缀/基础名`。
        var memberRoute: [String: String] = [:]
        for (key, route) in cursorRoutes { for member in route.memberModelIDs + [key] { memberRoute[member] = key } }
        let fastOf = highspeedPairs(sortedRaw, settings: settings, definitions: definitions, excluded: Set(memberRoute.keys))
        let fastMembers = Set(fastOf.values)
        var used: Set<String> = []
        return sortedRaw.compactMap { original in
            guard !fastMembers.contains(original.id) else { return nil }
            let routeKey = memberRoute[original.id]
            let raw = routeKey.map { ModelItem(id: $0, owner: original.owner, metadata: original.metadata) } ?? original
            guard used.insert(raw.id).inserted else { return nil }
            let members = routeKey.flatMap { cursorRoutes[$0]?.memberModelIDs } ?? []
            let selected = selection.map { chosen in
                chosen.contains(raw.id) || members.contains(where: chosen.contains) || fastOf[raw.id].map(chosen.contains) == true
            } ?? true
            let source = sources.first { $0.key == assignments[original.id] }
            let name: String
            if let source, !source.prefix.isEmpty, raw.id.hasPrefix(source.prefix + "/") { name = String(raw.id.dropFirst(source.prefix.count + 1)) }
            else { name = raw.id }
            var metadata = raw.metadata
            let cursorRoute = cursorRoutes[raw.id]
            let workChannel = settings.channels.first { $0.isKimiWork && $0.enabled && raw.id.hasPrefix($0.prefix + "/") }
            let workName = workChannel?.models.first { $0["alias"] == name }?["name"] ?? name
            let workModel = workChannel?.workModels[workName]
            let capability = workModel?.capability ?? cursorRoute?.capability ?? capability(for: raw, settings: settings, definitions: definitions)
                ?? ModelCapability(definition: raw.metadata)
            if let capability {
                metadata.merge(capability.catalogFields) { current, provided in cursorRoute == nil ? current : provided }
            }
            if let current = cursorRoute?.defaultEffort {
                var fields = metadata["capabilities"] as? [String: Any] ?? [:]
                fields["reasoning_default"] = current
                metadata["capabilities"] = fields
            }
            if let picker = cursorRoute?.pickerMetadata { metadata["bridgedock_parameters"] = picker }
            if let workModel {
                metadata.merge(workModel.capability.catalogFields) { _, fresh in fresh }
                metadata["display_name"] = workModel.displayName
                metadata["bridgedock_parameters"] = workModel.pickerMetadata
                var fields = metadata["capabilities"] as? [String: Any] ?? [:]
                fields["reasoning_default"] = workModel.defaultEffort
                metadata["capabilities"] = fields
            }
            return PublishedModel(id: raw.id, publicID: publicModelID(name),
                                  sourceID: source?.key ?? "provider:" + raw.owner,
                                  sourceName: source?.name ?? raw.owner, modelName: name, owner: raw.owner,
                                  isEnabled: selected, metadata: metadata,
                                  capability: capability, cursorRoute: cursorRoute, workModel: workModel,
                                  fastModelID: fastOf[raw.id], verifiedContexts: settings.verifiedContexts[raw.id])
        }.sorted {
            let order = $0.publicID.localizedStandardCompare($1.publicID)
            if order != .orderedSame { return order == .orderedAscending }
            // 同名模型按设置里渠道、账号的顺序排，第一个即默认供应商。
            let left = sourceOrder[$0.sourceID] ?? Int.max, right = sourceOrder[$1.sourceID] ?? Int.max
            return left == right ? $0.sourceID < $1.sourceID : left < right
        }
    }

    /// 同一公开 ID 下的一个供应商（渠道或账号池）及其声明的能力。
    struct Provider {
        let model: PublishedModel
        var key: String { model.sourceID }
        var name: String { model.sourceName }
        var capability: ModelCapability? { model.capability }

        var reasoningDefault: String? { model.workModel?.defaultEffort ?? model.cursorRoute?.defaultEffort ?? capability?.defaultEffort }
        var supportsFast: Bool { model.workModel?.supportsFast ?? model.cursorRoute?.supportsFast ?? (model.fastModelID != nil) }
        /// Work、Cursor 用上游原生档位；普通 API 只给长上下文检测通过的档位。
        var contextOptions: [Int] {
            if let work = model.workModel { return work.contexts.sorted() }
            if let cursor = model.cursorRoute, !cursor.variants.isEmpty { return cursor.contextOptions }
            return (model.verifiedContexts ?? []).sorted()
        }
        var defaultContext: Int? {
            model.workModel?.defaultContext ?? model.cursorRoute?.defaultParameters["context"].flatMap(Int.init) ?? contextOptions.last
        }

        var catalogEntry: [String: Any] {
            var entry: [String: Any] = ["id": key, "name": name]
            if let length = capability?.contextLength ?? contextOptions.last { entry["context_length"] = length }
            // 空数组也要发出，否则运行时会把其他供应商的档位套到这里。
            entry["context_options"] = contextOptions
            if let defaultContext { entry["context_default"] = defaultContext }
            if let efforts = capability?.reasoningEfforts, !efforts.isEmpty { entry["reasoning_effort"] = efforts }
            if let reasoningDefault { entry["reasoning_default"] = reasoningDefault }
            if supportsFast {
                entry["fast"] = true
                entry["fast_default"] = model.workModel.map { $0.defaultSpeed == "fast" }
                    ?? (model.cursorRoute?.defaultParameters["fast"] == "true")
            }
            if let variants = model.cursorRoute?.pickerMetadata?["variants"] { entry["variants"] = variants }
            return entry
        }
    }

    /// 按公开 ID 归并供应商，顺序与 catalog 一致；第一个即默认供应商。
    static func providers(in catalog: [PublishedModel], publicID: String) -> [Provider] {
        var seen: Set<String> = []
        let canonical = publicModelID(publicID)
        return catalog.filter { $0.isEnabled && $0.publicID == canonical && seen.insert($0.sourceID).inserted }.map(Provider.init)
    }

    /// /v1/models 的一项：顶层字段取默认供应商，`bridgedock_parameters` 为 version 2。
    static func catalogEntry(_ providers: [Provider]) -> [String: Any]? {
        guard let first = providers.first else { return nil }
        var value = first.model.metadata
        value["id"] = first.model.publicID
        value["object"] = "model"
        value["created"] = value["created"] ?? 0
        value["owned_by"] = first.name
        if let fallback = first.reasoningDefault {
            var fields = value["capabilities"] as? [String: Any] ?? [:]
            fields["reasoning_default"] = fallback
            value["capabilities"] = fields
        }
        var definitions: [[String: Any]] = []
        if providers.contains(where: \.supportsFast) {
            definitions.append(["id": "fast", "name": "快速模式", "values": [["id": "false", "label": "关"], ["id": "true", "label": "开"]]])
        }
        let contexts = Array(Set(providers.flatMap(\.contextOptions))).sorted()
        if !contexts.isEmpty {
            definitions.append(["id": "context", "name": "上下文", "values": contexts.map { ["id": String($0), "label": tokenLabel($0)] }])
        }
        let efforts = ModelCapability.sortedEfforts(providers.flatMap { $0.capability?.reasoningEfforts ?? [] })
        if !efforts.isEmpty {
            var labels: [String: String] = [:]
            for provider in providers { for (id, name) in provider.capability?.reasoningLabels ?? [:] where labels[id] == nil { labels[id] = name } }
            definitions.append(["id": "reasoning", "name": "思考强度", "values": efforts.map { ["id": $0, "label": labels[$0] ?? $0] }])
        }
        definitions.append(["id": "provider", "name": "供应商", "values": providers.map { ["id": $0.key, "label": $0.name] }])
        value["bridgedock_parameters"] = ["version": 2, "definitions": definitions, "providers": providers.map(\.catalogEntry)] as [String: Any]
        return value
    }

    static func catalogEntries(_ catalog: [PublishedModel]) -> [[String: Any]] {
        var seen: Set<String> = []
        return catalog.filter(\.isEnabled).compactMap { model in
            guard seen.insert(model.publicID).inserted else { return nil }
            return catalogEntry(providers(in: catalog, publicID: model.publicID))
        }
    }

    /// 旧版公开 ID 形如 `Curs-f3e5cf18/kimi-k3-high`：去掉四字渠道名（可带 8 位哈希）前缀。
    static func migratedPublicID(_ id: String) -> String {
        guard let range = id.range(of: "^[^/]{1,4}(-[0-9a-f]{8})?/", options: .regularExpression) else { return id }
        return String(id[range.upperBound...])
    }

    /// 加载设置时调用：只做不依赖目录的前缀迁移。
    static func migrateStoredIDs(_ settings: inout AppSettings) -> Bool {
        let migrated = settings.selectedModels.mapValues { publicModelID(migratedPublicID($0)) }
        guard migrated != settings.selectedModels else { return false }
        settings.selectedModels = migrated
        return true
    }

    /// 目录就绪后调用：把旧的 Cursor slug（含思考强度后缀）换成合并后的基础路由。
    static func migrateStoredIDs(_ settings: inout AppSettings, catalog: [PublishedModel]) -> Bool {
        var changed = migrateStoredIDs(&settings)
        var routeOf: [String: PublishedModel] = [:]
        var speedRoute: [String: PublishedModel] = [:]
        for model in catalog { for member in model.cursorRoute?.memberModelIDs ?? [] where member != model.id { routeOf[member] = model } }
        for model in catalog {
            if let fast = model.fastModelID {
                speedRoute[fast] = model
                speedRoute[String(fast.split(separator: "/", maxSplits: 1).last!)] = model
            }
        }
        if let ids = settings.publishedModelIDs {
            let next = Array(Set(ids.map { speedRoute[$0]?.id ?? routeOf[$0]?.id ?? $0 })).sorted()
            if next != ids.sorted() || next.count != ids.count { settings.publishedModelIDs = next; changed = true }
        }
        let publicIDs = Set(catalog.map(\.publicID))
        for (tool, selected) in settings.selectedModels where !publicIDs.contains(selected) {
            let match = speedRoute[selected] ?? catalog.first { model in model.cursorRoute?.memberModelIDs.contains { $0.hasSuffix("/" + selected) || $0 == selected } == true }
            if let match { settings.selectedModels[tool] = match.publicID; changed = true }
        }
        return changed
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
        let efforts = capability.reasoningEfforts?.filter { $0 != "none" }.map(capability.label(ofEffort:)) ?? []
        return context + " · " + (efforts.isEmpty ? "不支持思考强度" : "思考 " + efforts.joined(separator: " / "))
    }

    static func groups(in catalog: [PublishedModel], search: String = "", selected: Set<String>? = nil) -> [ModelPublicationGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = catalog.filter { model in
            (selected?.contains(model.id) ?? true) &&
                (query.isEmpty || [model.sourceName, model.publicID, model.modelName, model.id, model.workModel?.displayName ?? ""].contains {
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
