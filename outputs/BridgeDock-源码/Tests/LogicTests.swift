import Foundation

@main
struct LogicTests {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ label: String) {
            guard condition else { fatalError("FAILED: " + label) }
            count += 1
        }
        func rejects(_ label: String, _ action: () throws -> Void) {
            do { try action(); fatalError("SHOULD REJECT: " + label) } catch { count += 1 }
        }
        let scratch = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var channel = Channel()
        channel.name = "Mock channel"
        channel.baseURL = "http://127.0.0.1:19419/v1/"
        channel.apiKey = "mock-upstream-key"
        channel.prefix = "mock"
        channel.modelLines = "upstream-model = test-model\nsecond-model"
        channel = try channel.validated()
        check(!channel.baseURL.hasSuffix("/"), "base URL normalized")
        check(channel.models.count == 2, "two model mappings")
        check(channel.models[0]["alias"] == "test-model", "model alias")
        var bad = channel
        bad.prefix = "../anything"
        rejects("invalid prefix") { _ = try bad.validated() }
        bad = channel; bad.baseURL = "https://user:password@example.org"
        rejects("credentials in URL") { _ = try bad.validated() }
        bad = channel; bad.apiKey = "foo\nbar"
        rejects("header injection") { _ = try bad.validated() }
        bad = channel; bad.modelLines = ""
        rejects("empty models") { _ = try bad.validated() }

        // An older state.json without newer fields must still load.
        let oldState = Data(#"{"port":18500,"clientKey":"bd-old","managementKey":"m-old","channels":[{"name":"Old","baseURL":"https://x.example","apiKey":"k","prefix":"old","modelLines":"a"}]}"#.utf8)
        let loaded = try JSONDecoder().decode(AppSettings.self, from: oldState)
        check(loaded.port == 18500 && loaded.clientKey == "bd-old", "old state keeps saved values")
        check(loaded.kiroRegion == "us-east-1" && loaded.selectedModels.isEmpty, "old state gets new defaults")
        check(loaded.channels.first?.enabled == true && loaded.channels.first?.wire == .chat, "old channel gets defaults")
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(loaded))
        check(roundTrip.channels == loaded.channels && roundTrip.managementKey == "m-old", "state round trip")

        let claude = ConnectionProfile(tool: .claude, baseURL: "http://127.0.0.1:19417", key: "local-key", model: "mock/test-model")
        let existing = Data(#"{"env":{"OTHER":"preserve","ANTHROPIC_API_KEY":"old"},"permissions":{"allow":["Read"]},"custom":{"nested":true}}"#.utf8)
        let merged = try JSONSerialization.jsonObject(with: claude.merged(with: existing)) as! [String: Any]
        let env = merged["env"] as! [String: String]
        check(env["OTHER"] == "preserve", "preserve unrelated env")
        check(env["ANTHROPIC_API_KEY"] == nil, "remove competing API key")
        check(env["ANTHROPIC_AUTH_TOKEN"] == "local-key", "local token configured")
        check(merged["permissions"] != nil && merged["custom"] != nil, "preserve extra JSON")
        check(claude.command.contains("env -u ANTHROPIC_API_KEY"), "temporary command overrides competing key")
        rejects("broken JSON") { _ = try claude.merged(with: Data("{".utf8)) }

        let codex = ConnectionProfile(tool: .codex, baseURL: "http://127.0.0.1:19417", key: "local-key", model: "mock/test-model")
        let old = "# user note\nmodel = \"old\"\nmodel_provider = \"custom\"\n\n[mcp_servers.keep]\ncommand = \"test\"\n\n[model_providers.custom]\nname = \"Keep\"\n"
        let first = try codex.merged(with: Data(old.utf8))
        let text = String(decoding: first, as: UTF8.self)
        check(text.contains("[mcp_servers.keep]"), "preserve MCP settings")
        check(text.contains("[model_providers.custom]"), "preserve other providers")
        check(text.contains("model = \"mock/test-model\""), "replace top-level model")
        check(text.contains("[model_providers.bridgedock]"), "provider section header retained")
        check(text.contains("wire_api = \"responses\""), "Responses configured")
        check(try codex.merged(with: first) == first, "idempotent TOML application")
        rejects("conflicting hand-edited table") { _ = try codex.merged(with: Data("[model_providers.bridgedock]\nname=\"Manual\"".utf8)) }
        rejects("duplicate root key") { _ = try codex.merged(with: Data("model=\"one\"\nmodel=\"two\"".utf8)) }
        rejects("multi-line strings") { _ = try codex.merged(with: Data("value=\"\"\"\n[looks_like_table]\n\"\"\"".utf8)) }
        let kimi = ConnectionProfile(tool: .kimi, baseURL: "http://127.0.0.1:19417", key: "local-key", model: "mock/test-model")
        let kimiText = String(decoding: try kimi.merged(with: nil), as: UTF8.self)
        check(kimiText.contains("[providers.bridgedock]"), "Kimi provider")
        check(kimiText.contains("[models.bridgedock]"), "Kimi model")
        check(shellQuote("x'$(touch bad)") == "'x'\\''$(touch bad)'", "shell-safe quoting")

        let installer = ConfigurationInstaller(directory: scratch.appendingPathComponent("state"))
        let destination = scratch.appendingPathComponent("client/config.toml")
        try privateWrite(Data(old.utf8), to: destination)
        try installer.apply(codex, to: destination)
        check(try Data(contentsOf: destination) == first, "apply configuration")
        try installer.restore(destination)
        check(try Data(contentsOf: destination) == Data(old.utf8), "restore exact original")
        try installer.apply(codex, to: destination)
        try privateWrite(Data("changed by other app".utf8), to: destination)
        rejects("concurrent changes preserved") { try installer.restore(destination) }
        check(try String(contentsOf: destination, encoding: .utf8) == "changed by other app", "external edits retained")
        let fresh = scratch.appendingPathComponent("new.json")
        try installer.apply(claude, to: fresh)
        try installer.restore(fresh)
        check(!FileManager.default.fileExists(atPath: fresh.path), "restore initially absent file")
        let permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int
        check(permissions == 0o600, "private file permissions")

        var settings = AppSettings()
        settings.port = 19417
        settings.clientKey = "local-test-key"
        settings.managementKey = "management-test-key"
        settings.channels = [channel]
        let config = settings.coreConfig(dataDirectory: scratch, pluginDirectory: scratch.appendingPathComponent("plugins"))
        try privateWrite(jsonData(config), to: scratch.appendingPathComponent("config.yaml"))
        try first.write(to: scratch.appendingPathComponent("codex-output.toml"))
        try Data(kimiText.utf8).write(to: scratch.appendingPathComponent("kimi-output.toml"))
        print("PASS \(count) logic, merge, quoting, backup and permission assertions")
    }
}
