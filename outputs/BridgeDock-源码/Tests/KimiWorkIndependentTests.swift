import Foundation

@main
struct KimiWorkIndependentTests {
    static func main() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("work-independent-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let hash = KimiWorkSession.digest("kimi-work-account\0fixture")
        let store = KimiWorkCredentialStore(dataDirectory: dir)
        let session = KimiWorkSession(apiKey: "work-fixture-key", webToken: "expired-web-token", accountHash: hash)
        try store.save(session)
        var channel = Channel()
        channel.name = "Work"; channel.prefix = "work"; channel.credentialSource = "kimi-work"
        channel.desktopAccountHash = hash; channel.baseURL = KimiWorkSession.baseURL
        channel.modelLines = "k3d1-agent = kimi-k3.1-pro\nk3-agent"
        var settings = AppSettings(); settings.channels = [channel]
        let resolved = KimiWorkRouting.resolve(settings, read: store.read)
        precondition(resolved.channels[0].enabled && resolved.channels[0].apiKey == session.apiKey)
        precondition(settings.channels[0].apiKey.isEmpty)
        let saved = try store.read(hash)
        precondition(saved.refreshToken == nil, "Migration must not copy desktop refresh tokens")
        let attrs = try fm.attributesOfItem(atPath: store.directory.appendingPathComponent(hash + ".json").path)
        precondition((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let encoded = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        precondition(!encoded.contains(session.apiKey) && !encoded.contains(session.webToken))
        let row: [String: Any] = [
            "requestParams": ["modelId": "k3d1-agent", "agentMode": "TYPE_NORMAL", "defaultReasoningEffort": "REASONING_EFFORT_HIGH",
                              "reasoningEffortOptions": [["effort": "REASONING_EFFORT_LOW"], ["effort": "REASONING_EFFORT_HIGH"], ["effort": "REASONING_EFFORT_MAX"]],
                              "contextLengthOptions": [["contextLength": "CONTEXT_LENGTH_L", "available": true], ["contextLength": "CONTEXT_LENGTH_XL", "available": true]]],
            "display": ["displayName": "K3.1 Pro"],
            "daimonModelConfig": ["maxContextSize": 1000000, "capabilities": ["image_in"]],
            "speedOptions": [["speedValue": "standard", "available": true], ["speedValue": "fast", "available": true]],
            "defaultSpeedValue": "standard"
        ]
        let catalog = try KimiWorkCatalog.parse(["models": [row]])
        let work = catalog["k3d1-agent"]!
        precondition(work.supportsFast && work.defaultContext == 262144 && work.contexts == [262144, 1000000])
        precondition(work.capability.reasoningEfforts == ["low", "high", "max"])
        let merged = KimiWorkCatalog.merging(["k3d1-agent", "k3-agent", "k2d8-preview"], into: channel.modelLines)
        precondition(merged == channel.modelLines + "\nk2d8-preview", "Preserve existing aliases and append discoveries")
        var restricted = row
        restricted["speedOptions"] = [["speedValue": "standard", "available": true], ["speedValue": "fast", "available": false]]
        let denied = try KimiWorkCatalog.parse(["models": [restricted]])["k3d1-agent"]!
        precondition(!denied.supportsFast)
        do { _ = try denied.headers(parameters: ["fast": "true"]); fatalError("must reject unavailable fast") } catch {}
        channel.workModels = catalog; channel.capabilities = catalog.mapValues(\.capability); settings.channels = [channel]
        let published = ModelPublishing.catalog(rawModels: [ModelItem(id: "work/kimi-k3.1-pro", owner: "work")], settings: settings, accounts: [])
        let route = published[0]
        precondition(route.workModel?.displayName == "K3.1 Pro")
        precondition(route.metadata["bridgedock_parameters"] != nil)
        for path in ["/v1/chat/completions", "/v1/messages", "/v1/responses"] {
            let params = ["fast": "true", "context": "1000000", "reasoning": "max"]
            let headers = try ModelGateway.routedHeaders([:], route: route, parameters: params)
            precondition(headers["x-kimi-model-speed"] == "fast" && headers["x-kimi-context-length"] == "1000000")
            let body = try ModelGateway.routedBody(["model": route.publicID], route: route, path: path, parameters: params)
            precondition(body["model"] as? String == "work/kimi-k3.1-pro")
            if path.contains("messages") { precondition((body["output_config"] as? [String: Any])?["effort"] as? String == "max") }
            else if path.contains("responses") { precondition((body["reasoning"] as? [String: Any])?["effort"] as? String == "max") }
            else { precondition(body["reasoning_effort"] as? String == "max") }
        }
        let defaults = try ModelGateway.routedHeaders([:], route: route, parameters: nil)
        precondition(defaults["x-kimi-model-speed"] == "standard" && defaults["x-kimi-context-length"] == "262144")
        do { _ = try ModelGateway.routedHeaders(["x-kimi-model-speed": "turbo"], route: route, parameters: nil); fatalError("reject invented speed") } catch {}
        do { _ = try work.headers(parameters: ["context": "2000000"]); fatalError("reject excessive context") } catch {}
        do { _ = try work.headers(parameters: ["reasoning": "medium"]); fatalError("reject invented effort") } catch {}
        let reread = try JSONDecoder().decode(Channel.self, from: JSONEncoder().encode(channel))
        precondition(reread.workModels == catalog)
        print("PASS Work independent credentials, catalogue, Fast, context and three-protocol routing")
        if CommandLine.arguments.count > 2 {
            let gateway = ModelGateway()
            gateway.update(port: Int(CommandLine.arguments[1])!, corePort: Int(CommandLine.arguments[2])!, clientKey: "work-public-test", coreKey: "work-core-test", catalog: published)
            try await gateway.start()
            print("READY"); fflush(stdout)
            try await Task.sleep(nanoseconds: 180_000_000_000)
            gateway.stop()
        }
    }
}
