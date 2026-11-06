import Foundation

@main
struct CursorModelCapabilityTests {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            count += 1
        }
        func variant(_ id: String, _ effort: String, fast: Bool = false, maxMode: Bool = false) -> [String: Any] {
            ["legacySlug": id, "isMaxMode": maxMode, "parameterValues": [
                ["id": "context", "value": maxMode ? "1m" : "272k"],
                ["id": "reasoning", "value": effort],
                ["id": "fast", "value": String(fast)]
            ]]
        }
        let payload: [String: Any] = ["models": [[
            "name": "gpt-test", "contextTokenLimit": 1_000_000, "supportsImages": true,
            "parameterDefinitions": [
                ["id": "context", "name": "Context", "parameterType": ["enumParameter": ["values": [
                    ["value": "272k", "displayName": "272K"], ["value": "1m", "displayName": "1M"]]]]],
                ["id": "reasoning", "name": "Effort", "parameterType": ["enumParameter": ["values": [
                    ["value": "none", "displayName": "None"], ["value": "low", "displayName": "Low"],
                    ["value": "high", "displayName": "High"], ["value": "extra-high", "displayName": "Extra High"],
                    ["value": "max", "displayName": "Max"]]]]],
                ["id": "fast", "name": "Fast", "parameterType": ["booleanParameter": ["values": [
                    ["value": "false"], ["value": "true", "displayName": "Fast"]]]]]
            ],
            "variants": [variant("gpt-low", "low"), variant("gpt-high", "high"),
                         variant("gpt-xhigh", "extra-high"), variant("gpt-none", "none"),
                         variant("gpt-low-fast", "low", fast: true), variant("gpt-high-fast", "high", fast: true),
                         variant("gpt-high-max", "high", maxMode: true), variant("not-in-account", "max")]
        ]]]
        let catalog = try JSONDecoder().decode(CursorModelCatalog.self, from: jsonData(payload))
        let names = ["gpt-low", "gpt-high", "gpt-xhigh", "gpt-none", "gpt-low-fast", "gpt-high-fast", "gpt-high-max"]
        let available = Set(names.map { "cursor/" + $0 } + names.map { "other/" + $0 })
        let routes = catalog.routes(prefix: "cursor", availableModelIDs: available)
        check(Set(routes.keys) == ["cursor/gpt"], "每个基础模型只产出一个路由，键为基础名")
        let low = routes["cursor/gpt"]!
        check(low.defaultModelID == "cursor/gpt-low", "默认 variant 取普通速度、非 none 的最低可用档")
        check(Set(low.memberModelIDs) == Set(names.filter { $0 != "gpt-high-max" }.map { "cursor/" + $0 }), "合并路由记录全部真实 slug，Max 模式除外")
        check(low.capability.contextLength == 272000, "The variant's actual context wins over another mode's window")
        check(low.capability.reasoningEfforts == ["none", "low", "high", "xhigh"], "Only supported ordinary-mode efforts are published")
        check(low.defaultEffort == "low", "默认档位来自默认 variant")
        check(low.supportsFast && low.contextOptions == [272000], "Fast 与上下文档位从 variant 推出")
        check(low.capability.supportsVision == true, "Official image capability survives")
        check(try low.modelID(effort: nil) == "cursor/gpt-low", "Absent effort preserves the selected wire model")
        check(try low.modelID(effort: "high") == "cursor/gpt-high", "Chosen effort selects the exact wire model")
        check(try low.modelID(effort: "extra-high") == "cursor/gpt-xhigh", "extra-high is normalized without losing the wire ID")
        check(try low.modelID(effort: "none") == "cursor/gpt-none", "Explicit none maps only to a supported none variant")
        check(try low.modelID(parameters: ["reasoning": "high", "fast": "true"]) == "cursor/gpt-high-fast", "Native Fast and Effort select the exact same-account variant")
        check(try low.modelID(parameters: ["fast": "true"]) == "cursor/gpt-low-fast", "只切 Fast 时保留当前思考档")
        check(try low.modelID(parameters: ["reasoning": "none"]) == "cursor/gpt-none", "Native None is an explicit upstream variant")
        let contextDefinition = low.parameterDefinitions.first { $0["id"] as? String == "context" }!
        let contextType = contextDefinition["parameterType"] as! [String: Any]
        let contextValues = (contextType["enumParameter"] as! [String: Any])["values"] as! [[String: Any]]
        check(contextValues.count == 1 && contextValues[0]["value"] as? String == "272000", "Unavailable context tiers are excluded and native budgets use numeric tokens")
        do {
            _ = try low.modelID(parameters: ["reasoning": "xhigh", "fast": "true"])
            preconditionFailure("An unavailable parameter combination must be rejected")
        } catch { count += 1 }
        check(routes["other/gpt"] == nil, "Another account's prefix stays outside the route")
        for (path, body) in [
            ("/v1/chat/completions", ["reasoning_effort": "high"] as [String: Any]),
            ("/v1/responses", ["reasoning": ["effort": "high"]]),
            ("/v1/messages", ["output_config": ["effort": "high"]])
        ] {
            check(try low.modelID(body: body, path: path) == "cursor/gpt-high", "Every supported protocol honors the effort")
        }
        do {
            _ = try low.modelID(effort: "max")
            preconditionFailure("An unavailable effort must be rejected")
        } catch { count += 1 }

        for (slug, base) in [("kimi-k3-max", "kimi-k3"), ("muse-spark-1.3-high", "muse-spark-1.3"), ("gpt-5.6-sol-extra-high", "gpt-5.6-sol"),
                             ("claude-opus-5.5-thinking-high", "claude-opus-5.5"), ("gpt-6-xhigh-fast", "gpt-6"), ("o4", "o4")] {
            check(CursorModelCatalog.baseName(ofSlug: slug) == base, "从 slug 剥离思考强度后缀：" + slug)
        }
        let family = try JSONDecoder().decode(CursorModelCatalog.self, from: jsonData(["models": [[
            "name": "Kimi K3", "family": "kimi-k3",
            "variants": [["legacySlug": "kimi-k3-thinking", "parameterValues": [["id": "reasoning", "value": "high"]]]]
        ]]]))
        check(family.routes(prefix: "c", availableModelIDs: ["c/kimi-k3-thinking"]).keys.sorted() == ["c/kimi-k3"], "目录里的 family 字段优先作为基础名")
        let irregularCatalog = try JSONDecoder().decode(CursorModelCatalog.self, from: jsonData(["data": [
            ["modelId": "kimi-k3", "modelVariants": [["model_id": "kimi-k3-high", "parameters": [["id": "reasoning", "value": "high"]]]]]
        ]]))
        check(irregularCatalog.models.first?.variants?.first?.legacySlug == "kimi-k3-high", "Cursor aliases are decoded from modelId fields")
        let inferred = CursorModelCatalog.inferredRoutes(prefix: "cursor", availableModelIDs: ["cursor/kimi-k3", "cursor/kimi-k3-high", "cursor/kimi-k3-highspeed"])
        check(inferred["cursor/kimi-k3"]?.supportsFast == true && inferred["cursor/kimi-k3"]?.modelsByEffort["high"] == "cursor/kimi-k3-high",
              "Cursor raw non-standard slugs get standard Fast and reasoning controls")

        var settings = AppSettings()
        settings.publishedModelIDs = ["cursor/gpt-low"]
        let account = Account(["name": "cursor.json", "provider": "cursor-agent-v1", "prefix": "cursor"])
        let raw = names.map { ModelItem(id: "cursor/" + $0, owner: "cursor-agent-v1") }
        let published = ModelPublishing.catalog(rawModels: raw, settings: settings, accounts: [account], cursorRoutes: routes)
        check(published.map(\.publicID) == ["gpt", "gpt-high-max"], "各档位 slug 合并为一个不带前缀的公开 ID；Max 模式不并入")
        let selected = published.first { $0.publicID == "gpt" }!
        check(selected.id == "cursor/gpt" && selected.isEnabled, "旧的带后缀发布选择仍让基础模型保持开放")
        check(!published.first { $0.publicID == "gpt-high-max" }!.isEnabled, "未选中的模型保持关闭")
        let entry = ModelPublishing.catalogEntry(ModelPublishing.providers(in: published, publicID: "gpt"))!
        check(entry["id"] as? String == "gpt", "/v1/models 输出基础 ID")
        let capabilities = entry["capabilities"] as! [String: Any]
        check(capabilities["reasoning_effort"] as? [String] == ["low", "high", "xhigh"], "The public catalog exposes usable selector levels")
        check(capabilities["reasoning_default"] as? String == "low", "The selector receives the current explicit default")
        let picker = entry["bridgedock_parameters"] as! [String: Any]
        check(picker["version"] as? Int == 2, "参数描述为 version 2")
        let definitions = picker["definitions"] as! [[String: Any]]
        check(definitions.map { $0["id"] as! String } == ["fast", "context", "reasoning", "provider"], "定义顺序固定为 fast、context、reasoning、provider")
        let reasoningValues = (definitions[2]["values"] as! [[String: String]]).map { $0["id"]! }
        check(reasoningValues == ["none", "low", "high", "xhigh"], "只列声明支持的档位")
        let providers = picker["providers"] as! [[String: Any]]
        check(providers.count == 1 && providers[0]["id"] as? String == "account:" + account.id && providers[0]["context_length"] as? Int == 272000
              && providers[0]["reasoning_default"] as? String == "low" && providers[0]["variants"] != nil, "供应商条目带能力与原生 variants")
        check(try selected.cursorRoute!.modelID(effort: "high") == "cursor/gpt-high", "Publication retains the executable route mapping")

        var legacy = AppSettings()
        legacy.publishedModelIDs = ["cursor/gpt-low", "cursor/gpt-high", "cursor/gpt-high-max"]
        legacy.selectedModels = ["Cursor": "Curs-f3e5cf18/gpt-high", "Codex CLI": "Curs/gpt-high-max", "Kiro": "kimi-k3"]
        _ = ModelPublishing.migrateStoredIDs(&legacy)
        check(legacy.selectedModels == ["Cursor": "gpt-high", "Codex CLI": "gpt-high-max", "Kiro": "kimi-k3"], "加载设置时去掉旧渠道前缀")
        check(ModelPublishing.migrateStoredIDs(&legacy, catalog: ModelPublishing.catalog(rawModels: raw, settings: legacy, accounts: [account], cursorRoutes: routes)),
              "目录就绪后迁移旧 slug")
        check(legacy.publishedModelIDs == ["cursor/gpt", "cursor/gpt-high-max"], "发布选择迁移到合并后的路由 ID")
        check(legacy.selectedModels["Cursor"] == "gpt" && legacy.selectedModels["Codex CLI"] == "gpt-high-max", "工具所选模型迁移到基础公开 ID")
        check(!ModelPublishing.migrateStoredIDs(&legacy, catalog: published), "迁移可重复执行且不再改动")

        if CommandLine.arguments.count > 2 {
            let captured = try JSONDecoder().decode(CursorModelCatalog.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let data = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
            let rows = data["models"] as! [[String: Any]]
            let ids = Set(rows.filter { $0["maxMode"] as? Bool != true }.compactMap { ($0["modelId"] as? String).map { "cursor/" + $0 } })
            let live = captured.routes(prefix: "cursor", availableModelIDs: ids)
            let gpt = live["cursor/gpt-5.6-sol"]!
            check(try gpt.modelID(effort: "max") == "cursor/gpt-5.6-sol-max", "Captured GPT catalog maps max exactly")
            check(try live["cursor/kimi-k3"]!.modelID(effort: "high") == "cursor/kimi-k3-high", "Captured Kimi catalog maps high exactly")
            print("Captured catalog mapped \(live.count) models with \(live.values.filter { !$0.modelsByEffort.isEmpty }.count) effort controls")
        }
        print("PASS \(count) Cursor catalog, selector metadata and protocol routing assertions")
    }
}
