import Foundation

@main
struct GatewayTestServer {
    static func main() async throws {
        let history: [String: Any] = ["messages": [
            ["role": "user", "content": "hi"],
            ["role": "assistant", "content": ""],
            ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "call"]]],
            ["role": "assistant", "content": [["type": "text", "text": " "]]],
            ["role": "assistant", "content": NSNull(), "tool_calls": []],
            ["role": "assistant", "content": "ok"],
        ]]
        let cleaned = ModelGateway.droppingEmptyAssistantMessages(history)["messages"] as! [[String: Any]]
        precondition(cleaned.count == 3 && cleaned[1]["tool_calls"] != nil && cleaned[2]["content"] as? String == "ok",
                     "空 assistant 消息被移除，工具调用消息保留")
        let port = Int(CommandLine.arguments[1])!
        let corePort = Int(CommandLine.arguments[2])!
        let kiroPort = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) : nil
        // Optional: a Kiro worker that always answers 429, and a port nothing listens on.
        let busyKiroPort = CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4]) : nil
        let deadKiroPort = CommandLine.arguments.count > 5 ? Int(CommandLine.arguments[5]) : nil
        var settings = AppSettings()
        var channel = Channel()
        channel.id = "fixture-channel"; channel.name = "测试渠道一"; channel.prefix = "fixture"
        channel.modelLines = "upstream-model = model-a\nsecond-model = model-b"
        settings.channels = [channel]
        settings.publishedModelIDs = ["fixture/model-a"]
        let raw = [ModelItem(id: "fixture/model-a", owner: "mock", metadata: ["context_length": 32768]), ModelItem(id: "fixture/model-b", owner: "mock")]
        let catalog = ModelPublishing.catalog(rawModels: raw, settings: settings, accounts: [])
        precondition(catalog[0].publicID == "model-a")
        precondition(catalog[0].isEnabled && !catalog[1].isEnabled)
        precondition(catalog[0].metadata["context_length"] as? Int == 32768)
        settings.publishedModelIDs = []
        precondition(ModelPublishing.catalog(rawModels: raw, settings: settings, accounts: []).allSatisfy { !$0.isEnabled })
        var second = channel; second.id = "second"; second.prefix = "other"; second.name = "测试渠道二"
        settings.channels.append(second)
        settings.publishedModelIDs = nil
        let collision = ModelPublishing.catalog(rawModels: raw + [ModelItem(id: "other/model-a", owner: "mock")], settings: settings, accounts: [])
        precondition(Set(collision.map(\.publicID)) == ["model-a", "model-b"])
        let mergedA = ModelPublishing.providers(in: collision, publicID: "model-a")
        precondition(mergedA.map(\.key) == ["channel:fixture-channel", "channel:second"], "同名模型按渠道合并，顺序稳定")
        let mergedEntry = ModelPublishing.catalogEntry(mergedA)!["bridgedock_parameters"] as! [String: Any]
        precondition((mergedEntry["providers"] as! [[String: Any]]).count == 2)
        precondition(ModelPublishing.catalogEntries(collision).count == 2, "/v1/models 每个公开 ID 只出一条")
        let groups = ModelPublishing.groups(in: collision)
        precondition(groups.count == 2 && groups.map { $0.models.count }.sorted() == [1, 2])
        precondition(ModelPublishing.groups(in: collision, search: "  MODEL-B\n").flatMap(\.models).map(\.id) == ["fixture/model-b"])
        precondition(ModelPublishing.groups(in: collision, search: "测试渠道二").flatMap(\.models).map(\.id) == ["other/model-a"])
        precondition(ModelPublishing.groups(in: collision, selected: ["fixture/model-b", "unavailable/model"]).flatMap(\.models).map(\.id) == ["fixture/model-b"])
        precondition(ModelPublishing.groups(in: collision, selected: []).isEmpty)
        // Separate channels with identical display names must stay separate.
        settings.channels[1].name = channel.name
        let sameNames = ModelPublishing.catalog(rawModels: raw + [ModelItem(id: "other/model-a", owner: "mock")], settings: settings, accounts: [])
        precondition(ModelPublishing.groups(in: sameNames).count == 2)
        let sharedAccounts = [
            Account(["name": "cursor-fixture.json", "provider": "cursor-agent-v1", "runtime_profile": "agent_v1", "prefix": "cursor"]),
            Account(["name": "grok-bot-fixture.json", "provider": "cursor-agent-v1", "runtime_profile": "sand", "prefix": "grok-bot"])
        ]
        let sharedCatalog = ModelPublishing.catalog(rawModels: [
            ModelItem(id: "cursor/shared-model", owner: "cursor-agent-v1"),
            ModelItem(id: "grok-bot/shared-model", owner: "cursor-agent-v1")
        ], settings: AppSettings(), accounts: sharedAccounts)
        precondition(Set(sharedCatalog.map(\.sourceName)) == ["Cursor", "Grok Bot"])
        precondition(Set(sharedCatalog.map(\.publicID)) == ["shared-model"])
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        precondition(legacy.publishedModelIDs == nil)
        precondition(legacy.coreClientKey != legacy.clientKey)
        let gateway = ModelGateway()
        precondition(ModelGateway.preferredImageModel(["gpt/gpt-image-1.5", "gpt/gpt-image-2.5-flare", "gpt/gpt-image-2.5", "gpt/gpt-image-2", "gpt/gpt-6"]) == "gpt/gpt-image-2.5")
        precondition(ModelGateway.preferredImageModel(["gpt/gpt-image-10", "gpt/gpt-image-9.9"]) == "gpt/gpt-image-10")
        precondition(ModelGateway.preferredImageModel(["fixture/model-a", "grok-imagine-image-2.0"]) == nil)
        let converted = ModelGateway.gptImageBody(["model": "grok-imagine-image-2.0", "prompt": "p", "aspect_ratio": "16:9", "resolution": "1k", "response_format": "b64_json"], model: "gpt/gpt-image-2.5")
        precondition(converted["model"] as? String == "gpt/gpt-image-2.5" && converted["size"] as? String == "1536x1024")
        precondition(converted["aspect_ratio"] == nil && converted["resolution"] == nil && converted["response_format"] == nil)
        precondition(converted["quality"] as? String == "high")
        precondition(ModelGateway.gptImageBody(["size": "1024x1024", "quality": "low"], model: "m")["quality"] as? String == "low")
        let kiroAccount = Account(["name": "kiro-fixture.json", "provider": "kiro", "prefix": "kiro"])
        let kiroCatalog = ModelPublishing.catalog(rawModels: [ModelItem(id: "kiro/claude-opus-5.5", owner: "kiro"),
                                                              ModelItem(id: "claude-sonnet-5.5", owner: "kiro")],
                                                  settings: AppSettings(), accounts: [kiroAccount],
                                                  definitions: ["kiro": ["claude-opus-5.5": ModelCapability(contextLength: 200000)]])
        let claudeCatalog = ModelPublishing.catalog(rawModels: [ModelItem(id: "claude-opus-5-5", owner: "anthropic")],
                                                    settings: AppSettings(), accounts: [],
                                                    definitions: ["claude": ["claude-opus-5-5": ModelCapability(contextLength: 1000000, reasoningEfforts: ["low", "high"])]])
        let opusProviders = ModelPublishing.providers(in: claudeCatalog + kiroCatalog, publicID: "claude-opus-5-5")
        precondition(opusProviders.map(\.name) == ["Claude", "Kiro"], "点号与短横线版本号归并到同一个 Claude 模型")
        precondition(opusProviders.map { $0.model.id } == ["claude-opus-5-5", "kiro/claude-opus-5.5"], "真实路由 ID 保持不变")
        precondition(opusProviders.allSatisfy { $0.contextOptions.isEmpty }, "未做长上下文检测时普通渠道不提供上下文档位")
        var forcedKiroParameters: [String: String]? = ["provider": "provider:anthropic", "reasoning": "high"]
        let forcedKiro = try ModelGateway.resolve("claude-opus-5-5", in: claudeCatalog + kiroCatalog,
                                                  parameters: &forcedKiroParameters, preferKiro: true)
        precondition(forcedKiro?.provider.name == "Kiro" && forcedKiroParameters?["reasoning"] == "high",
                     "Cursor 请求优先保持在 Kiro 池，即使缓存了 Claude 供应商参数")
        var verified = AppSettings(); verified.verifiedContexts = ["claude-opus-5-5": [262144, 200000]]
        let verifiedOpus = ModelPublishing.catalog(rawModels: [ModelItem(id: "claude-opus-5-5", owner: "anthropic")], settings: verified, accounts: [],
                                                   definitions: ["claude": ["claude-opus-5-5": ModelCapability(contextLength: 1000000)]])
        precondition(ModelPublishing.providers(in: verifiedOpus, publicID: "claude-opus-5-5")[0].contextOptions == [200000, 262144], "上下文档位来自检测结果")

        // Kimi Code：能力一致的 -highspeed 并入基础模型作为快速模式；能力不同的保持独立。
        var kimi = Channel(); kimi.id = "kimi"; kimi.name = "Kimi Code 国内"; kimi.prefix = "kimi"
        kimi.modelLines = "k3.1-pro\nk3.1-pro-highspeed\nkimi-for-coding\nkimi-for-coding-highspeed"
        let kimiRows: [[String: Any]] = [
            ["id": "k3.1-pro", "context_length": 1048576, "think_efforts": ["support": true, "valid_efforts": ["low", "high", "max"], "default_effort": "high"]],
            ["id": "k3.1-pro-highspeed", "context_length": 1048576, "think_efforts": ["support": true, "valid_efforts": ["low", "high", "max"], "default_effort": "high"]],
            ["id": "kimi-for-coding", "context_length": 1048576, "think_efforts": ["support": true, "valid_efforts": ["low", "high", "max"]]],
            ["id": "kimi-for-coding-highspeed", "context_length": 262144]
        ]
        kimi.capabilities = ModelListRequest.capabilities(in: ["data": kimiRows])
        precondition(kimi.capabilities["k3.1-pro"]?.defaultEffort == "high", "读取官方默认档位")
        var kimiSettings = AppSettings(); kimiSettings.channels = [kimi]
        kimiSettings.publishedModelIDs = ["kimi/k3.1-pro-highspeed", "kimi/kimi-for-coding-highspeed"]
        let kimiCatalog = ModelPublishing.catalog(rawModels: kimi.models.map { ModelItem(id: "kimi/" + $0["name"]!, owner: "moonshot") },
                                                  settings: kimiSettings, accounts: [])
        precondition(kimiCatalog.map(\.publicID) == ["k3.1-pro", "kimi-for-coding", "kimi-for-coding-highspeed"], "\(kimiCatalog.map(\.publicID))")
        precondition(kimiCatalog[0].isEnabled && kimiCatalog[0].fastModelID == "kimi/k3.1-pro-highspeed", "只发布过高速版时基础模型仍开放")
        let kimiEntry = ModelPublishing.catalogEntry(ModelPublishing.providers(in: kimiCatalog, publicID: "k3.1-pro"))!["bridgedock_parameters"] as! [String: Any]
        let kimiDefinitions = kimiEntry["definitions"] as! [[String: Any]]
        precondition(kimiDefinitions.map { $0["id"] as! String } == ["fast", "reasoning", "provider"], "无检测结果时不出上下文：\(kimiDefinitions)")
        precondition(((kimiDefinitions[1]["values"] as! [[String: String]]).map { $0["label"]! }) == ["low", "high", "max"], "无官方名称时用档位原名")
        precondition((kimiEntry["providers"] as! [[String: Any]])[0]["reasoning_default"] as? String == "high")
        let kimiRoute = kimiCatalog[0]
        let fastBody = try ModelGateway.routedBody(["model": "k3.1-pro"], route: kimiRoute, path: "/v1/chat/completions", parameters: ["fast": "true", "reasoning": "max"])
        precondition(fastBody["model"] as? String == "kimi/k3.1-pro-highspeed" && fastBody["reasoning_effort"] as? String == "max", "快速模式改走 highspeed")
        let slowBody = try ModelGateway.routedBody(["model": "k3.1-pro"], route: kimiRoute, path: "/v1/chat/completions", parameters: ["fast": "false"])
        precondition(slowBody["model"] as? String == "kimi/k3.1-pro")
        var oldHighspeed: [String: String]? = nil
        let oldRoute = try ModelGateway.provider(for: "k3.1-pro-highspeed", in: kimiCatalog, parameters: &oldHighspeed)
        precondition(oldRoute?.id == "kimi/k3.1-pro" && oldHighspeed == ["fast": "true"], "旧的 highspeed ID 改为快速模式")

        // Work 档位使用官方中文名。
        let work = KimiWorkModel(displayName: "K3.1 Pro", capability: ModelCapability(contextLength: 1000000, reasoningEfforts: ["low", "high", "max"],
                                 reasoningLabels: ["low": "标准", "high": "进阶", "max": "极致"]),
                                 speeds: [], defaultSpeed: "", contexts: [], defaultContext: nil, defaultEffort: "high")
        precondition(work.capability.label(ofEffort: "high") == "进阶" && work.capability.label(ofEffort: "max") == "极致")
        let workReasoning = (work.pickerMetadata["definitions"] as! [[String: Any]]).first { $0["id"] as? String == "reasoning" }!
        precondition((workReasoning["values"] as! [[String: String]]).map { $0["label"]! } == ["标准", "进阶", "极致"])
        precondition(ModelPublishing.contextBudgets(1048576) == [200000, 262144, 524288, 1048576])
        precondition(ModelPublishing.contextBudgets(0).isEmpty)
        precondition(ModelPublishing.publicModelID("claude-opus-4.5-20251101") == "claude-opus-4-5-20251101")
        precondition(ModelPublishing.publicModelID("muse-spark-1.3") == "muse-spark-1.3", "不改写其他模型的版本号")
        var claudeSelection = AppSettings(); claudeSelection.publishedModelIDs = ["kiro/claude-opus-5.5"]
        claudeSelection.selectedModels = ["Cursor": "claude-opus-5.5"]
        precondition(ModelPublishing.migrateStoredIDs(&claudeSelection) && claudeSelection.selectedModels["Cursor"] == "claude-opus-5-5")
        precondition(claudeSelection.publishedModelIDs == ["kiro/claude-opus-5.5"], "迁移不改变原来的供应商发布选择")
        let filtered = ModelPublishing.catalog(rawModels: [ModelItem(id: "claude-opus-5-5", owner: "anthropic"), ModelItem(id: "kiro/claude-opus-5.5", owner: "kiro")],
                                              settings: claudeSelection, accounts: [kiroAccount])
        precondition(ModelPublishing.providers(in: filtered, publicID: "claude-opus-5-5").map(\.name) == ["Kiro"], "归并不开放未勾选的供应商")
        let cursorAccount = Account(["name": "cursor.json", "provider": "cursor-agent-v1", "prefix": "cursor-fixture"])
        var cursorRoute = CursorModelRoute(defaultModelID: "cursor-fixture/gpt-low",
                                          modelsByEffort: ["low": "cursor-fixture/gpt-low", "high": "cursor-fixture/gpt-high"],
                                          defaultEffort: "low", capability: ModelCapability(contextLength: 272000, reasoningEfforts: ["low", "high"]),
                                          variants: [
                                            CursorParameterVariant(modelID: "cursor-fixture/gpt-low", parameters: ["reasoning": "low", "fast": "false"]),
                                            CursorParameterVariant(modelID: "cursor-fixture/gpt-high", parameters: ["reasoning": "high", "fast": "false"]),
                                            CursorParameterVariant(modelID: "cursor-fixture/gpt-high-fast", parameters: ["reasoning": "high", "fast": "true"])
                                          ])
        cursorRoute.memberModelIDs = ["cursor-fixture/gpt-low", "cursor-fixture/gpt-high", "cursor-fixture/gpt-high-fast"]
        var cursorSettings = AppSettings()
        cursorSettings.publishedModelIDs = ["cursor-fixture/gpt-low"]
        let cursorCatalog = ModelPublishing.catalog(rawModels: cursorRoute.memberModelIDs.map { ModelItem(id: $0, owner: "cursor-agent-v1") },
                                                    settings: cursorSettings, accounts: [cursorAccount],
                                                    cursorRoutes: ["cursor-fixture/gpt": cursorRoute])
        precondition(cursorCatalog.map(\.publicID) == ["gpt"] && cursorCatalog[0].isEnabled)
        // 同名 gpt 由另一个普通渠道提供，用于验证 provider 选路与能力降级。
        var gptChannel = Channel()
        gptChannel.id = "gpt-relay"; gptChannel.name = "中转站"; gptChannel.prefix = "relay"; gptChannel.modelLines = "gpt"
        gptChannel.capabilities = ["gpt": ModelCapability(contextLength: 128000, reasoningEfforts: ["medium"])]
        var relaySettings = AppSettings(); relaySettings.channels = [gptChannel]
        let relayCatalog = ModelPublishing.catalog(rawModels: [ModelItem(id: "relay/gpt", owner: "mock")], settings: relaySettings, accounts: [])
        var routedParameters: [String: String]? = ["provider": "channel:gpt-relay", "reasoning": "high", "context": "272000"]
        let relay = try ModelGateway.provider(for: "gpt", in: cursorCatalog + relayCatalog, parameters: &routedParameters)
        precondition(relay?.id == "relay/gpt" && routedParameters == ["reasoning": "medium"],
                     "provider 选中渠道，不支持的 effort 降到最接近的一档，未验证的上下文回到默认")
        var traced: [String: String]? = ["provider": "channel:gpt-relay", "reasoning": "high", "context": "272000"]
        let resolution = try ModelGateway.resolve("gpt", in: cursorCatalog + relayCatalog, parameters: &traced)
        precondition(resolution?.provider.name == "中转站"
                     && resolution?.adjustments == [ParameterAdjustment(id: "reasoning", requested: "high", effective: "medium"),
                                                    ParameterAdjustment(id: "context", requested: "272000", effective: "")],
                     "每一处换算都被记下")
        let headers = ModelGateway.resolutionHeaders(provider: resolution!.provider, parameters: traced, adjustments: resolution!.adjustments)
        precondition(headers["X-BridgeDock-Provider"] == "%E4%B8%AD%E8%BD%AC%E7%AB%99" && headers["X-BridgeDock-Provider-Id"] == "channel%3Agpt-relay"
                     && headers["X-BridgeDock-Parameters"] == "reasoning=medium" && headers["X-BridgeDock-Adjusted"] == "reasoning:high>medium;context:272000>",
                     "响应头写明实际供应商、生效参数和换算")
        // Cursor 账号只接受列出的组合：low + 快速不存在，取最接近的 low + 标准速度。
        var cursorCombo: [String: String]? = ["provider": cursorCatalog[0].sourceID, "reasoning": "low", "fast": "true"]
        let combo = try ModelGateway.resolve("gpt", in: cursorCatalog + relayCatalog, parameters: &cursorCombo)
        precondition(cursorCombo == ["reasoning": "low", "fast": "false"]
                     && combo?.adjustments == [ParameterAdjustment(id: "fast", requested: "true", effective: "false")],
                     "Cursor 不存在的组合换成最接近的一组：\(String(describing: cursorCombo))")
        var cursorMax: [String: String]? = ["provider": cursorCatalog[0].sourceID, "reasoning": "max"]
        _ = try ModelGateway.resolve("gpt", in: cursorCatalog + relayCatalog, parameters: &cursorMax)
        precondition(cursorMax?["reasoning"] == "high", "Cursor 账号没有 max 时按 high")
        precondition(ModelPublishing.nearestEffort("max", in: ["low", "high"]) == "high"
                     && ModelPublishing.nearestEffort("minimal", in: ["low", "high"]) == "low"
                     && ModelPublishing.nearestEffort("medium", in: ["low", "high"]) == "low"
                     && ModelPublishing.nearestEffort("bogus", in: ["low"]) == nil
                     && ModelPublishing.nearestEffort("high", in: []) == nil, "思考档位取不高于所选的最高一档")
        precondition(ModelPublishing.nearestContext(1_000_000, in: [200_000, 262_144]) == 262_144
                     && ModelPublishing.nearestContext(100_000, in: [200_000]) == 200_000
                     && ModelPublishing.nearestContext(1, in: []) == nil, "上下文取不超过所选的最大一档")
        let merged = ModelPublishing.catalogEntries(cursorCatalog + relayCatalog).first { $0["id"] as? String == "gpt" }
        let entries = (merged?["bridgedock_parameters"] as? [String: Any])?["providers"] as? [[String: Any]] ?? []
        let relayEffective = entries.first { $0["id"] as? String == "channel:gpt-relay" }?["effective"] as? [String: [String: String]]
        precondition(relayEffective?["reasoning"] == ["low": "medium", "high": "medium"] && relayEffective?["fast"] == ["true": "false"],
                     "发布给 Cursor 的映射表写明每个不支持的档位实际按哪档：\(String(describing: relayEffective))")
        let cursorEffective = entries.first { $0["id"] as? String == cursorCatalog[0].sourceID }?["effective"] as? [String: [String: String]]
        precondition(cursorEffective?["reasoning"] == ["medium": "low"], "Cursor 账号缺的 medium 按 low")
        let gaps = ModelPublishing.capabilityGaps(cursorCatalog + relayCatalog)
        precondition(gaps.contains(ModelPublishing.CapabilityGap(publicID: "gpt", provider: "中转站", detail: "思考强度 low→medium、high→medium"))
                     && gaps.contains(ModelPublishing.CapabilityGap(publicID: "gpt", provider: "中转站", detail: "不支持快速模式，开启后按标准速度"))
                     && gaps.contains { $0.provider != "中转站" && $0.detail == "思考强度 medium→low" },
                     "发布时列出合并模型里各供应商能力不一致之处：\(gaps.map(\.detail))")
        precondition(ModelPublishing.capabilityGaps(relayCatalog).isEmpty, "只有一个供应商时没有不一致")
        let plan = ModelPublishing.parameterProbePlan(cursorCatalog + relayCatalog, publicID: "gpt")
        let relayPlan = plan.filter { $0.providerName == "中转站" }
        precondition(plan.count == 2 * 5 && relayPlan.map(\.title) == ["默认", "思考 low", "思考 medium", "思考 high", "快速"],
                     "参数实测：每个供应商测默认、并集里的每个思考档位和快速模式：\(plan.map(\.title))")
        precondition(relayPlan[3].expected == ["reasoning": "medium"]
                     && relayPlan[3].expectedAdjustments == [ParameterAdjustment(id: "reasoning", requested: "high", effective: "medium")]
                     && relayPlan[3].expectsThinking && relayPlan[0].expected.isEmpty && !relayPlan[0].expectsThinking
                     && relayPlan[4].expectedAdjustments == [ParameterAdjustment(id: "fast", requested: "true", effective: "false")],
                     "实测用例带着网关应生效的档位与换算")
        precondition(ModelPublishing.parameterHeader("fast=false;reasoning=high;x=%E4%B8%AD") == ["fast": "false", "reasoning": "high", "x": "中"],
                     "解析网关回写的生效参数头")
        var result = ParameterProbeResult(probe: relayPlan[3], status: 200, servedProviderKey: "channel:gpt-relay",
                                          servedProviderName: "中转站", effective: ["reasoning": "medium"], thinkingCharacters: 0)
        precondition(result.passed && result.verdict == "正常 · 未回传思考原文", "落点与档位都对，没有思考原文时只作说明（部分上游不回传）")
        result.servedProviderKey = "account:other"; result.servedProviderName = "Claude"
        precondition(!result.passed && result.verdict == "换到了 Claude", "换了供应商时判为失败")
        var defaultParameters: [String: String]? = ["reasoning": "high"]
        let first = try ModelGateway.provider(for: "gpt", in: cursorCatalog + relayCatalog, parameters: &defaultParameters)
        precondition(first?.id == "cursor-fixture/gpt"
                     && defaultParameters == ["reasoning": "high"], "缺省选第一个渠道并保留其支持的参数")
        var qualifiedParameters: [String: String]? = nil
        let qualified = try ModelGateway.provider(for: "Cursor/gpt", in: cursorCatalog + relayCatalog, parameters: &qualifiedParameters)
        precondition(qualified?.id == "cursor-fixture/gpt" && qualifiedParameters == [:],
                     "历史的供应商限定模型名仍解析到已发布的供应商")
        for legacyID in ["gpt-high", "Curs-f3e5cf18/gpt-high"] {
            var legacyParameters: [String: String]? = nil
            let legacy = try ModelGateway.provider(for: legacyID, in: cursorCatalog + relayCatalog, parameters: &legacyParameters)
            precondition(legacy?.id == "cursor-fixture/gpt" && legacyParameters == ["reasoning": "high"],
                         "旧的带后缀 ID 仍走原 Cursor 供应商并保留其思考强度：\(legacyID)")
        }
        var missing: [String: String]? = ["provider": "gone"]
        do { _ = try ModelGateway.provider(for: "gpt", in: cursorCatalog, parameters: &missing); preconditionFailure("unknown provider") } catch {}
        gateway.update(port: port, corePort: corePort, clientKey: "public-test-key", coreKey: "internal-test-key", catalog: catalog + claudeCatalog + kiroCatalog + cursorCatalog + relayCatalog,
                       coreModels: ["fixture/model-a", "fixture/model-b", "gpt/gpt-image-2", "gpt/gpt-image-2.5", "gpt/gpt-image-2.5-flare"])
        if let kiroPort {
            var workers = [KiroWorkerRoute(id: "2", port: kiroPort, key: "kiro-pool-key", prefix: "kiro", pooled: false),
                           KiroWorkerRoute(id: "4", port: kiroPort, key: "kiro-default-key", prefix: "", pooled: false)]
            if let busyKiroPort { workers.append(KiroWorkerRoute(id: "1", port: busyKiroPort, key: "kiro-busy-key", prefix: "kiro", pooled: false)) }
            if let deadKiroPort { workers.append(KiroWorkerRoute(id: "3", port: deadKiroPort, key: "kiro-dead-key", prefix: "kiro", pooled: false)) }
            gateway.updateKiro(KiroGatewayRoute(workers: workers))
        }
        try await gateway.start()
        print("READY", terminator: "\n")
        fflush(stdout)
        // Keep the fixture process alive; the harness owns its cleanup.
        try await Task.sleep(nanoseconds: 180_000_000_000)
        gateway.stop()
    }
}
