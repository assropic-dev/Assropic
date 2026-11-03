import Foundation

@main
struct ModelCapabilityTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ label: String) {
            guard condition else { fatalError("FAILED: " + label) }
            count += 1
        }

        let codex = ModelCapability(definition: ["id": "gpt-6-astra", "context_length": 272000, "max_completion_tokens": 128000,
                                                 "thinking": ["levels": ["max", "low", "high", "medium", "xhigh"]],
                                                 "supportedInputModalities": ["text", "image"]])
        check(codex?.contextLength == 272000 && codex?.maxOutputTokens == 128000, "core definition context and output")
        check(codex?.reasoningEfforts == ["low", "medium", "high", "xhigh", "max"], "levels are ordered by strength")
        check(codex?.supportsVision == true, "image input implies vision")

        let budget = ModelCapability(definition: ["id": "claude-haiku", "context_length": 200000, "thinking": ["min": 1024, "max": 128000, "zero_allowed": true]])
        check(budget?.reasoningEfforts == ["none", "low", "medium", "high"], "budget-only thinking maps to standard levels with off")

        let gemini = ModelCapability(definition: ["id": "gemini-2.5-pro", "inputTokenLimit": 1048576, "outputTokenLimit": 65536])
        check(gemini?.contextLength == 1048576 && gemini?.maxOutputTokens == 65536, "Gemini-style token limits")
        check(gemini?.reasoningEfforts == nil, "no thinking field means no reasoning levels")

        let kimi = ModelCapability(definition: ["id": "k3", "context_length": 1048576, "supports_reasoning": true,
                                                "think_efforts": ["support": true, "valid_efforts": ["low", "high", "max"]]])
        check(kimi?.reasoningEfforts == ["low", "high", "max"], "Kimi valid_efforts are recorded")
        check(ModelCapability(definition: ["id": "bare", "object": "model"]) == nil, "rows without capability data stay unknown")
        check(ModelCapability(definition: ["id": "bad", "context_length": -5, "thinking": ["levels": ["Bad Value!"]]]) == nil,
              "invalid limits and effort names are rejected")

        let fields = kimi!.catalogFields
        let nested = fields["capabilities"] as? [String: Any]
        check(fields["context_length"] as? Int == 1048576 && nested?["context_length"] as? Int == 1048576, "published context in both places")
        check(nested?["reasoning_effort"] as? [String] == ["low", "high", "max"] && nested?["supports_reasoning"] as? Bool == true, "published reasoning")
        let offOnly = ModelCapability(contextLength: 1000, reasoningEfforts: ["none"]).catalogFields["capabilities"] as? [String: Any]
        check(offOnly?["reasoning_effort"] == nil, "an off-only level list does not claim reasoning support")

        let rows = ModelListRequest.capabilities(in: ["data": [["id": "k3", "context_length": 262144], ["id": "plain"]]])
        check(rows.keys.sorted() == ["k3"] && rows["k3"]?.contextLength == 262144, "provider /models rows are parsed by id")

        var settings = AppSettings()
        var channel = Channel()
        channel.id = "c"; channel.name = "Kimi Code 国内"; channel.prefix = "kimi"
        channel.modelLines = "k3\nkimi-for-coding = coder"
        channel.capabilities = ["k3": ModelCapability(contextLength: 1048576, reasoningEfforts: ["low", "high"]),
                                "kimi-for-coding": ModelCapability(contextLength: 262144)]
        settings.channels = [channel]
        let definitions = ["codex": ["gpt-6-astra": codex!], "kimi": ["k3": ModelCapability(contextLength: 1)],
                           "kiro": ["claude-opus-4-5": ModelCapability(contextLength: 200000)],
                           "claude": ["claude-opus-4-5": ModelCapability(contextLength: 1000000)]]
        let catalog = ModelPublishing.catalog(rawModels: [
            ModelItem(id: "kimi/k3", owner: "x"), ModelItem(id: "kimi/coder", owner: "x"),
            ModelItem(id: "gpt/gpt-6-astra", owner: "openai"), ModelItem(id: "mystery", owner: "x"),
            ModelItem(id: "kiro/claude-opus-4-5", owner: "kiro"), ModelItem(id: "claude/claude-opus-4-5", owner: "anthropic")
        ], settings: settings, accounts: [], definitions: definitions)
        func model(_ id: String) -> PublishedModel { catalog.first { $0.id == id }! }
        check(model("kimi/k3").capability?.contextLength == 1048576, "channel record wins over core definitions")
        check(model("kimi/coder").capability?.contextLength == 262144, "aliases resolve to the upstream model's record")
        check(model("gpt/gpt-6-astra").capability?.contextLength == 272000, "accounts fall back to core definitions")
        check((model("gpt/gpt-6-astra").metadata["capabilities"] as? [String: Any])?["reasoning_effort"] as? [String] == codex!.reasoningEfforts,
              "published metadata carries reasoning levels")
        check(model("kiro/claude-opus-4-5").capability?.contextLength == 200000, "an account uses its own vendor's definition first")
        check(model("claude/claude-opus-4-5").capability?.contextLength == 1000000, "the same model name through another vendor keeps its own limit")
        check(model("mystery").capability == nil && model("mystery").metadata["capabilities"] == nil, "unknown models publish nothing invented")
        check(ModelPublishing.capabilitySummary(model("kimi/k3").capability) == "上下文 1M · 思考 low / high", "picker summary")

        let encoded = try! JSONEncoder().encode(channel)
        let decoded = try! JSONDecoder().decode(Channel.self, from: encoded)
        check(decoded.capabilities == channel.capabilities, "capabilities persist in state.json")
        let legacy = try! JSONDecoder().decode(Channel.self, from: Data(#"{"name":"old"}"#.utf8))
        check(legacy.capabilities.isEmpty, "older state files load without capabilities")
        print("PASS \(count) model capability, publishing and persistence assertions")
    }
}
