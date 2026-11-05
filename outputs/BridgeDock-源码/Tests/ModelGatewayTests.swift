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
        precondition(relay?.id == "relay/gpt" && routedParameters == [:], "provider 选中渠道，不支持的 effort/context 降为默认")
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
        if let kiroPort { gateway.updateKiro(KiroGatewayRoute(port: kiroPort, keys: ["kiro": "kiro-pool-key", "": "kiro-default-key"])) }
        try await gateway.start()
        print("READY", terminator: "\n")
        fflush(stdout)
        // Keep the fixture process alive; the harness owns its cleanup.
        try await Task.sleep(nanoseconds: 180_000_000_000)
        gateway.stop()
    }
}
