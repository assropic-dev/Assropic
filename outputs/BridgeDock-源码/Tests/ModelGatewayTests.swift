import Foundation

@main
struct GatewayTestServer {
    static func main() async throws {
        let port = Int(CommandLine.arguments[1])!
        let corePort = Int(CommandLine.arguments[2])!
        var settings = AppSettings()
        var channel = Channel()
        channel.id = "fixture-channel"; channel.name = "测试渠道一"; channel.prefix = "fixture"
        channel.modelLines = "upstream-model = model-a\nsecond-model = model-b"
        settings.channels = [channel]
        settings.publishedModelIDs = ["fixture/model-a"]
        let raw = [ModelItem(id: "fixture/model-a", owner: "mock", metadata: ["context_length": 32768]), ModelItem(id: "fixture/model-b", owner: "mock")]
        let catalog = ModelPublishing.catalog(rawModels: raw, settings: settings, accounts: [])
        precondition(catalog[0].publicID == "测试渠道/model-a")
        precondition(catalog[0].isEnabled && !catalog[1].isEnabled)
        precondition(catalog[0].metadata["context_length"] as? Int == 32768)
        settings.publishedModelIDs = []
        precondition(ModelPublishing.catalog(rawModels: raw, settings: settings, accounts: []).allSatisfy { !$0.isEnabled })
        var second = channel; second.id = "second"; second.prefix = "other"; second.name = "测试渠道二"
        settings.channels.append(second)
        settings.publishedModelIDs = nil
        let collision = ModelPublishing.catalog(rawModels: raw + [ModelItem(id: "other/model-a", owner: "mock")], settings: settings, accounts: [])
        precondition(Set(collision.map(\.publicID)).count == 3)
        precondition(collision.allSatisfy { $0.publicID.hasPrefix("测试渠道-") })
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
        precondition(Set(sharedCatalog.map(\.publicID)).count == 2)
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
        gateway.update(port: port, corePort: corePort, clientKey: "public-test-key", coreKey: "internal-test-key", catalog: catalog,
                       coreModels: ["fixture/model-a", "fixture/model-b", "gpt/gpt-image-2", "gpt/gpt-image-2.5", "gpt/gpt-image-2.5-flare"])
        try await gateway.start()
        print("READY", terminator: "\n")
        fflush(stdout)
        // Keep the fixture process alive; the harness owns its cleanup.
        try await Task.sleep(nanoseconds: 180_000_000_000)
        gateway.stop()
    }
}
