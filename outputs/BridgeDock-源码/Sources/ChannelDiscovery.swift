import Foundation

private struct ModelHTTPFailure: Error {
    let status: Int
}

extension BridgeStore {
    func discoverModels(for channel: Channel) async throws -> ModelDiscovery {
        guard running else { throw BridgeError.message("请先启动本地服务。") }
        if channel.isKimiWork {
            let (models, capabilities) = try await kimiWorkCatalog(channel)
            return ModelDiscovery(channel: channel, modelLines: models.joined(separator: "\n"),
                                  notice: "已从 Kimi Work 独立网关查询到 \(models.count) 个模型" + Self.capabilityNotice(capabilities, total: models.count),
                                  capabilities: capabilities)
        }
        let channel = ModelListRequest.normalized(channel)
        let preset = Preset.matching(channel)
        if let preset, !preset.supportsModelDiscovery {
            _ = try ModelListRequest(channel: channel) // Validate inputs without sending the key.
            return ModelDiscovery(channel: channel, modelLines: preset.defaultModelLines,
                                  notice: "已填入官方 Coding Plan 模型。服务商没有公开模型列表接口，可用权限仍需实际调用确认。")
        }
        do {
            let (models, capabilities) = try await loadModelNames(channel)
            return ModelDiscovery(channel: channel, modelLines: models.joined(separator: "\n"),
                                  notice: "已查询到 \(models.count) 个模型" + Self.capabilityNotice(capabilities, total: models.count),
                                  capabilities: capabilities)
        } catch let error as ModelHTTPFailure {
            if error.status == 401, let alternative = ModelListRequest.kimiAlternative(for: channel),
               let (models, capabilities) = try? await loadModelNames(alternative) {
                let title = Preset.matching(alternative)?.title ?? "Kimi"
                return ModelDiscovery(channel: alternative, modelLines: models.joined(separator: "\n"),
                                      notice: "已识别此 Key 属于\(title)，已修正地址、协议和余额类型，并查询到 \(models.count) 个模型" + Self.capabilityNotice(capabilities, total: models.count),
                                      capabilities: capabilities)
            }
            let reason: String
            switch error.status {
            case 401: reason = "Key 无效、已过期或与所选服务不匹配。Kimi 会员订阅 Key 和开放平台 Key 不能混用。"
            case 403: reason = "此 Key 没有接口权限或请求被服务商限制，请检查账户权限。"
            case 404, 405: reason = "这个地址没有提供模型列表接口。已预填的官方模型可以保留，也可核对 Base URL。"
            case 429: reason = "模型列表查询过于频繁，请稍后重试。"
            default: reason = "服务商暂时无法返回模型列表，请稍后重试。"
            }
            throw BridgeError.message("获取模型失败（HTTP \(error.status)）· " + reason)
        }
    }

    static func capabilityNotice(_ capabilities: [String: ModelCapability], total: Int) -> String {
        let context = capabilities.values.filter { $0.contextLength != nil }.count
        let reasoning = capabilities.values.filter { $0.reasoningEfforts != nil }.count
        guard context + reasoning > 0 else { return "。服务商未返回上下文和思考强度，将按内核模型资料补充。" }
        return "，其中 \(context) 个带上下文长度、\(reasoning) 个带思考强度，已写入渠道记录。"
    }

    /// Channels saved before capabilities were recorded are queried once per launch.
    /// Only the capability record is written; models, aliases and other fields stay.
    func backfillChannelCapabilities() async {
        let pending = settings.channels.filter {
            $0.enabled && $0.capabilities.isEmpty && !capabilityBackfillAttempted.contains($0.id)
                && (Preset.matching($0)?.supportsModelDiscovery ?? true)
        }
        guard running, !pending.isEmpty else { return }
        for channel in pending {
            capabilityBackfillAttempted.insert(channel.id)
            guard let result = try? await discoverModels(for: channel), !result.capabilities.isEmpty,
                  !busy, !workSyncing, let index = settings.channels.firstIndex(where: { $0.id == channel.id }) else { continue }
            var next = settings
            next.channels[index].capabilities = result.capabilities
            do {
                try await update(next)
                record("已记录 \(channel.name) 的模型上下文与思考强度 · \(result.capabilities.count) 个模型")
            } catch { capabilityBackfillAttempted.remove(channel.id) }
        }
    }

    /// The common vendors are always read: API channels to Claude, OpenAI, Kimi or xAI
    /// reuse those definitions. Other sets are read only when an account uses them.
    nonisolated static func expectedDefinitionSets(_ accounts: [Account], owners: [String] = []) -> Set<String> {
        let providers = Set(accounts.map { $0.provider.lowercased() } + owners.map { $0.lowercased() })
        let optional = ["kiro", "zcode", "gemini", "antigravity", "vertex", "aistudio", CursorAccountProfile.providerID]
        return Set(["claude", "codex", "kimi", "xai"] + optional.filter(providers.contains))
    }

    /// Core definitions keyed by upstream model ID; feeds context and reasoning for
    /// subscription accounts and channels whose provider omits them from /models.
    func loadModelDefinitions() async -> [String: [String: ModelCapability]] {
        var result: [String: [String: ModelCapability]] = [:]
        for name in Self.expectedDefinitionSets(accounts, owners: modelOwners).sorted() {
            guard let value = try? await object("/v8/management/routing/model-definitions/" + Self.query(name)),
                  let rows = value["models"] as? [[String: Any]] else { continue }
            var set: [String: ModelCapability] = [:]
            for row in rows {
                guard let id = row["id"] as? String, let capability = ModelCapability(definition: row) else { continue }
                set[id] = capability
                if set[id.lowercased()] == nil { set[id.lowercased()] = capability }
            }
            result[name] = set
        }
        return result
    }

    private func loadModelNames(_ channel: Channel) async throws -> ([String], [String: ModelCapability]) {
        let request = try ModelListRequest(channel: channel)
        var url = request.url
        var seenPages = Set<String>()
        var names = Set<String>()
        var capabilities: [String: ModelCapability] = [:]
        for _ in 0..<20 {
            try Task.checkCancellation()
            let result = try await object("/v8/management/requests/api-call", method: "POST", value: [
                "method": "GET", "url": url, "header": request.headers, "proxy_url": channel.proxyURL
            ])
            guard let status = result["status_code"] as? Int else { throw BridgeError.message("模型接口未返回有效状态。") }
            guard (200..<300).contains(status) else { throw ModelHTTPFailure(status: status) }
            guard let text = result["body"] as? String, let data = text.data(using: .utf8),
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BridgeError.message("模型接口没有返回有效的 JSON 列表，请核对 Base URL。")
            }
            names.formUnion(ModelListRequest.names(in: value))
            capabilities.merge(ModelListRequest.capabilities(in: value)) { current, _ in current }
            guard value["has_more"] as? Bool == true else {
                guard !names.isEmpty else { throw BridgeError.message("服务商未返回可用模型。已填写的模型会保留，请检查账号权限。") }
                return (names.sorted(), capabilities)
            }
            guard let last = value["last_id"] as? String, !last.isEmpty, seenPages.insert(last).inserted,
                  var components = URLComponents(string: request.url) else {
                throw BridgeError.message("模型列表分页不完整，请稍后重试。")
            }
            components.queryItems = [URLQueryItem(name: "after_id", value: last)]
            guard let next = components.string else { throw BridgeError.message("模型分页地址无效。") }
            url = next
        }
        throw BridgeError.message("模型列表分页过多，请手动缩小模型范围。")
    }
}
