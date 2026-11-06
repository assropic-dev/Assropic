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
    var isEnabled: Bool
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
    /// Thinking levels kiro2cc accepts on Kiro's Claude models (Vendor/Kiro2ccFreeOpus.patch adds xhigh and max).
    static let kiroEfforts = ["low", "medium", "high", "xhigh", "max"]

    /// The core's Kiro plugin lists Claude models without thinking levels, so a merged model's picker
    /// treated Kiro as unable to think and switched to another provider as soon as a level was chosen.
    static func kiroThinking(_ capability: ModelCapability?, owner: String, name: String) -> ModelCapability? {
        guard owner.lowercased() == "kiro", name.lowercased().hasPrefix("claude-") else { return capability }
        var value = capability ?? ModelCapability()
        if value.reasoningEfforts?.isEmpty != false { value.reasoningEfforts = kiroEfforts }
        return value
    }

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
            let capability = kiroThinking(workModel?.capability ?? cursorRoute?.capability ?? capability(for: raw, settings: settings, definitions: definitions)
                ?? ModelCapability(definition: raw.metadata), owner: raw.owner, name: name)
            if let capability {
                metadata.merge(capability.catalogFields) { current, provided in cursorRoute == nil ? current : provided }
                if let efforts = capability.reasoningEfforts, raw.owner.lowercased() == "kiro" {
                    // The core's Kiro definitions omit thinking; publish what kiro2cc accepts.
                    var fields = metadata["capabilities"] as? [String: Any] ?? [:]
                    fields["reasoning_effort"] = efforts; fields["supports_reasoning"] = true
                    metadata["capabilities"] = fields
                }
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

        /// 实际可选的思考档位；"none" 只表示“沿用默认”，不算一档。
        var effortOptions: [String] {
            if let cursor = model.cursorRoute, !cursor.variants.isEmpty {
                return ModelCapability.sortedEfforts(cursor.variants.compactMap { $0.parameters["reasoning"] }).filter { $0 != "none" }
            }
            return (capability?.reasoningEfforts ?? []).filter { $0 != "none" }
        }

        /// 本供应商不支持的档位 → 实际生效值（"" 表示按供应商默认），供 Cursor 标注。
        func effectiveMap(efforts: [String], contexts: [Int], fast: Bool) -> [String: [String: String]] {
            var result: [String: [String: String]] = [:]
            let reasoning = efforts.filter { $0 != "none" && !effortOptions.contains($0) }
            if !reasoning.isEmpty {
                result["reasoning"] = Dictionary(uniqueKeysWithValues: reasoning.map { ($0, ModelPublishing.nearestEffort($0, in: effortOptions) ?? "") })
            }
            let context = contexts.filter { !contextOptions.contains($0) }
            if !context.isEmpty {
                result["context"] = Dictionary(uniqueKeysWithValues: context.map {
                    (String($0), ModelPublishing.nearestContext($0, in: contextOptions).map(String.init) ?? "")
                })
            }
            if fast, !supportsFast { result["fast"] = ["true": "false"] }
            return result
        }

        /// 把客户端选的参数换算成本供应商真正支持的值；每处换算记一条，供响应头和诊断使用。
        func resolve(_ values: [String: String]) -> (values: [String: String], adjustments: [ParameterAdjustment]) {
            var result = values
            var adjustments: [ParameterAdjustment] = []
            if let effort = values["reasoning"], effort != "none", !effortOptions.contains(effort) {
                let nearest = ModelPublishing.nearestEffort(effort, in: effortOptions)
                result["reasoning"] = nearest
                adjustments.append(ParameterAdjustment(id: "reasoning", requested: effort, effective: nearest ?? ""))
            }
            if let text = values["context"] {
                let size = Int(text)
                if size.map(contextOptions.contains) != true {
                    let nearest = size.flatMap { ModelPublishing.nearestContext($0, in: contextOptions) }
                    result["context"] = nearest.map(String.init)
                    adjustments.append(ParameterAdjustment(id: "context", requested: text, effective: nearest.map(String.init) ?? ""))
                }
            }
            if let fast = values["fast"], !supportsFast {
                result.removeValue(forKey: "fast")
                if fast == "true" { adjustments.append(ParameterAdjustment(id: "fast", requested: "true", effective: "false")) }
            }
            // Cursor 账号只接受上游列出的组合：逐项换算后仍无此组合时，取最接近的一组。
            if let cursor = model.cursorRoute, !cursor.variants.isEmpty {
                let base = cursor.defaultParameters
                var wanted = base
                for (key, value) in result where base[key] != nil { wanted[key] = value }
                if !cursor.variants.contains(where: { $0.parameters == wanted }),
                   let closest = cursor.variants.min(by: { Self.distance($0.parameters, wanted) < Self.distance($1.parameters, wanted) }) {
                    for (key, value) in closest.parameters where wanted[key] != value && result[key] != nil {
                        let requested = values[key] ?? wanted[key] ?? ""
                        adjustments.removeAll { $0.id == key }
                        if requested != value { adjustments.append(ParameterAdjustment(id: key, requested: requested, effective: value)) }
                        result[key] = value
                    }
                    for (key, value) in closest.parameters where result[key] == nil && wanted[key] != value { result[key] = value }
                }
            }
            return (result, adjustments)
        }

        /// 思考档位差得最多扣分，其次是快速模式，最后是上下文。
        static func distance(_ variant: [String: String], _ wanted: [String: String]) -> Int {
            let rank = { (value: String?) in value.flatMap { ModelCapability.effortOrder.firstIndex(of: $0) } ?? 0 }
            var score = abs(rank(variant["reasoning"]) - rank(wanted["reasoning"])) * 4
            if variant["fast"] != wanted["fast"] { score += 2 }
            if variant["context"] != wanted["context"] { score += 1 }
            return score
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
        // 每个供应商对全部档位都给出实际生效值：选中它不支持的档位时，Cursor 仍留在这个供应商，
        // 由网关按这里的映射降到最接近的档位，而不是悄悄换成另一个供应商。
        let entries: [[String: Any]] = providers.map { provider in
            var entry = provider.catalogEntry
            let effective = provider.effectiveMap(efforts: efforts, contexts: contexts, fast: providers.contains(where: \.supportsFast))
            if !effective.isEmpty { entry["effective"] = effective }
            return entry
        }
        value["bridgedock_parameters"] = ["version": 2, "definitions": definitions, "providers": entries] as [String: Any]
        return value
    }

    /// 档位按 `ModelCapability.effortOrder` 排序；取不高于所请求档位的最高一档，没有就取最低一档。
    static func nearestEffort(_ requested: String, in options: [String]) -> String? {
        let order = ModelCapability.effortOrder
        let rank = { (value: String) in order.firstIndex(of: value) ?? -1 }
        guard !options.isEmpty, rank(requested) >= 0 else { return nil }
        if options.contains(requested) { return requested }
        let sorted = options.sorted { rank($0) < rank($1) }
        return sorted.last { rank($0) <= rank(requested) } ?? sorted.first
    }

    /// 取不超过所请求预算的最大档，没有就取最小一档。
    static func nearestContext(_ requested: Int, in options: [Int]) -> Int? {
        let sorted = options.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted.last { $0 <= requested } ?? sorted.first
    }

    /// 合并模型里各供应商能力不一致之处。选到某供应商没有的档位时会按最接近的档位生效。
    struct CapabilityGap: Equatable, Identifiable {
        let publicID: String
        let provider: String
        let detail: String
        var id: String { publicID + "|" + provider + "|" + detail }
    }

    static func capabilityGaps(_ catalog: [PublishedModel]) -> [CapabilityGap] {
        var seen: Set<String> = []
        var gaps: [CapabilityGap] = []
        for model in catalog where model.isEnabled && seen.insert(model.publicID).inserted {
            let members = providers(in: catalog, publicID: model.publicID)
            guard members.count > 1 else { continue }
            let efforts = ModelCapability.sortedEfforts(members.flatMap(\.effortOptions))
            let contexts = Array(Set(members.flatMap(\.contextOptions))).sorted()
            let fast = members.contains(where: \.supportsFast)
            for member in members {
                let missing = efforts.filter { !member.effortOptions.contains($0) }
                if !missing.isEmpty {
                    let detail: String
                    if member.effortOptions.isEmpty { detail = "未声明思考强度，选任何档位都按该供应商默认" }
                    else {
                        let pairs = missing.map { "\($0)→\(nearestEffort($0, in: member.effortOptions) ?? "默认")" }
                        detail = "思考强度 " + pairs.joined(separator: "、")
                    }
                    gaps.append(CapabilityGap(publicID: model.publicID, provider: member.name, detail: detail))
                }
                let lacking = contexts.filter { !member.contextOptions.contains($0) }
                if !lacking.isEmpty, !member.contextOptions.isEmpty {
                    let pairs = lacking.map { "\(tokenLabel($0))→\(nearestContext($0, in: member.contextOptions).map(tokenLabel) ?? "默认")" }
                    gaps.append(CapabilityGap(publicID: model.publicID, provider: member.name, detail: "上下文 " + pairs.joined(separator: "、")))
                } else if !lacking.isEmpty {
                    gaps.append(CapabilityGap(publicID: model.publicID, provider: member.name, detail: "上下文档位未验证，选任何档位都按该供应商默认"))
                }
                if fast, !member.supportsFast {
                    gaps.append(CapabilityGap(publicID: model.publicID, provider: member.name, detail: "不支持快速模式，开启后按标准速度"))
                }
            }
        }
        return gaps
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


/// 一处参数换算：客户端选了 `requested`，本次实际按 `effective`（"" 表示供应商默认）。
struct ParameterAdjustment: Equatable, Codable {
    let id: String
    let requested: String
    let effective: String

    var summary: String {
        let name = ["reasoning": "思考强度", "context": "上下文", "fast": "快速模式"][id] ?? id
        let show = { (value: String) -> String in
            if value.isEmpty { return "默认" }
            if self.id == "context", let size = Int(value) { return ModelPublishing.tokenLabel(size) }
            if self.id == "fast" { return value == "true" ? "开" : "关" }
            return value
        }
        return "\(name) \(show(requested))→\(show(effective))"
    }
}

/// 参数实测的一条用例：指定供应商与参数发一条小请求，核对实际落到的供应商和生效档位。
struct ParameterProbeCase: Identifiable, Equatable {
    let providerKey: String
    let providerName: String
    let parameters: [String: String]
    /// 网关应生效的参数（只含 reasoning / fast）与应发生的换算。
    let expected: [String: String]
    let expectedAdjustments: [ParameterAdjustment]

    var id: String { providerKey + "|" + parameters.keys.sorted().map { $0 + "=" + parameters[$0]! }.joined(separator: ",") }
    var title: String {
        if parameters.isEmpty { return "默认" }
        var parts: [String] = []
        if let effort = parameters["reasoning"] { parts.append("思考 " + effort) }
        if parameters["fast"] == "true" { parts.append("快速") }
        return parts.joined(separator: " · ")
    }
    /// 中等及以上档位应能看到思考内容。
    var expectsThinking: Bool { ["medium", "high", "xhigh", "max"].contains(expected["reasoning"] ?? "") }
}

extension ModelPublishing {
    /// 每个供应商：默认一条、并集里的每个思考档位各一条、有快速模式时再加一条。上下文档位不在这里测（长上下文实测另有入口）。
    static func parameterProbePlan(_ catalog: [PublishedModel], publicID: String) -> [ParameterProbeCase] {
        let members = providers(in: catalog, publicID: publicID)
        let efforts = ModelCapability.sortedEfforts(members.flatMap(\.effortOptions))
        let fast = members.contains(where: \.supportsFast)
        var cases: [ParameterProbeCase] = []
        for member in members {
            var requests: [[String: String]] = [[:]]
            requests += efforts.map { ["reasoning": $0] }
            if fast { requests.append(["fast": "true"]) }
            for request in requests {
                let resolved = member.resolve(request)
                cases.append(ParameterProbeCase(providerKey: member.key, providerName: member.name, parameters: request,
                                                expected: resolved.values.filter { ["reasoning", "fast"].contains($0.key) },
                                                expectedAdjustments: resolved.adjustments))
            }
        }
        return cases
    }

    /// 解析 `X-BridgeDock-Parameters`（`reasoning=high;fast=false`，值经百分号编码）。
    static func parameterHeader(_ text: String?) -> [String: String] {
        var result: [String: String] = [:]
        for pair in (text ?? "").split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return result
    }
}

/// 参数实测的一条结果。
struct ParameterProbeResult: Identifiable, Equatable {
    let probe: ParameterProbeCase
    var status: Int?
    var servedProviderKey: String?
    var servedProviderName: String?
    var effective: [String: String] = [:]
    var adjusted: String?
    var thinkingCharacters = 0
    var firstText: TimeInterval?
    var failure: String?

    var id: String { probe.id }
    var landedOnChosen: Bool { servedProviderKey == probe.providerKey }
    var parametersMatch: Bool { effective.filter { ["reasoning", "fast"].contains($0.key) } == probe.expected }
    var missingThinking: Bool { probe.expectsThinking && thinkingCharacters == 0 }
    var passed: Bool { status == 200 && failure == nil && landedOnChosen && parametersMatch }
    var verdict: String {
        if let failure { return failure }
        guard status == 200 else { return "HTTP \(status.map(String.init) ?? "无响应")" }
        if !landedOnChosen { return "换到了 " + (servedProviderName ?? "未知供应商") }
        if !parametersMatch { return "生效参数与预期不符" }
        if missingThinking { return "正常 · 未回传思考原文" }
        return "正常"
    }
}
