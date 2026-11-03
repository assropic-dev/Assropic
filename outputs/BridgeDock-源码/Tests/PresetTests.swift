import Foundation

@main
struct PresetTests {
    static var count = 0
    static var failures: [String] = []

    static func check(_ condition: Bool, _ message: String) {
        count += 1
        if !condition { failures.append(message) }
    }

    static func rejects(_ message: String, _ operation: () throws -> Void) {
        count += 1
        do { try operation(); failures.append(message) } catch {}
    }

    static func preset(_ id: String) -> Preset {
        Preset.all.first { $0.id == id }!
    }

    static func channel(_ id: String) -> Channel {
        preset(id).makeChannel(existing: [])
    }

    static func main() throws {
        let expectedIDs: Set<String> = ["relay", "claude", "codex", "kimi-code", "kimi-code-ai", "kimi", "kimi-ai", "zcode", "zai", "deepseek", "grok"]
        check(Preset.all.count == 11 && Set(Preset.all.map(\.id)) == expectedIDs, "The catalog contains each of the eleven provider presets exactly once")
        check(Set(Preset.all.map(\.prefix)).count == Preset.all.count, "Default routing prefixes do not collide across providers")

        var created: [Channel] = []
        for entry in Preset.all {
            let first = entry.makeChannel(existing: created)
            check(!first.name.isEmpty && first.kind == first.name && !first.prefix.isEmpty, "Preset \(entry.id) pre-fills the channel identity")
            check(first.apiKey.isEmpty && first.enabled, "Preset \(entry.id) leaves credentials for the account holder and enables the channel")
            check(first.balanceMode == entry.balanceMode, "Preset \(entry.id) selects its balance adapter")
            if entry.id == "relay" {
                check(first.baseURL.isEmpty && first.modelLines.isEmpty && first.balanceMode == .auto, "A custom relay does not invent an upstream or model catalog")
            } else {
                check(first.baseURL.hasPrefix("https://") && !first.models.isEmpty && !entry.sourceURL.isEmpty, "Known provider \(entry.id) pre-fills its endpoint, models and source")
                check(Preset.matching(first)?.id == entry.id, "Known endpoint \(entry.id) resolves to its own provider")
                var configured = first
                configured.apiKey = "mock-provider-key"
                check(try configured.validated().models.count == first.models.count, "Known provider \(entry.id) is usable after supplying its key")
            }
            created.append(first)
            let second = entry.makeChannel(existing: created)
            created.append(second)
            let third = entry.makeChannel(existing: created)
            created.append(third)
            check(first.id != second.id && second.id != third.id, "Repeated \(entry.id) channels keep separate identities")
            check(Set([first.prefix, second.prefix, third.prefix]).count == 3, "Repeated \(entry.id) channels get unique routing prefixes")
        }
        check(Set(created.map(\.prefix)).count == created.count, "All automatically created channels remain independently addressable")
        check(preset("kimi-code").balanceMode == .kimi && preset("kimi").balanceMode == .moonshot,
              "Kimi membership quota and Moonshot cash balance use separate adapters")
        check(!preset("zcode").supportsModelDiscovery && !preset("zai").supportsModelDiscovery,
              "Coding Plan presets do not require an undocumented model-list endpoint")
        check(Set(channel("zai").models.compactMap { $0["name"] }) == ["glm-5.3", "glm-5.3-flash"],
              "GLM Coding Plan defaults expose the two documented current model IDs")

        var candidate = channel("kimi-code")
        for badURL in [
            "https://api.kimi.com.attacker.invalid/coding/v1",
            "https://evil-api.kimi.com/coding/v1",
            "https://attacker.invalid/api.kimi.com/coding/v1",
            "https://api.kimi.com@attacker.invalid/coding/v1",
            "https://name:password@api.kimi.com/coding/v1",
            "http://api.kimi.com/coding/v1",
            "https://api.kimi.com:8443/coding/v1",
            "https://api.kimi.com/coding/v1?other=1",
            "https://api.kimi.com/coding/v1#other",
            "https://api.kimi.com/coding/other",
            "https://api.kimi.com/coding/v1/models",
            "https://api.kimi.com/not-coding/v1",
            "https://my-kimi-proxy.example.invalid/coding/v1"
        ] {
            candidate.baseURL = badURL
            check(Preset.matching(candidate) == nil, "Provider recognition rejects a non-official origin or path: \(badURL)")
        }
        candidate.baseURL = "https://API.KIMI.COM:443/coding/v1/"
        check(Preset.matching(candidate)?.id == "kimi-code", "Provider recognition accepts an equivalent HTTPS origin and trailing slash")
        candidate = channel("kimi")
        candidate.baseURL = "https://custom.example.invalid/v1"
        candidate.kind = preset("kimi-code").title
        candidate.name = preset("kimi-code").title
        check(Preset.matching(candidate) == nil && ModelListRequest.kimiAlternative(for: candidate) == nil,
              "A user-named relay is never redirected to an official service")

        for pair in [("codex", "api.openai.com"), ("kimi", "api.moonshot.cn"), ("kimi-ai", "api.moonshot.ai"), ("grok", "api.x.ai")] {
            var root = channel(pair.0)
            root.baseURL = "https://\(pair.1)/"
            root.apiKey = "mock-normalization-key"
            root.name = "Custom account name"
            root.prefix = "custom-route"
            root.proxyURL = "socks5://127.0.0.1:1080"
            let normalized = ModelListRequest.normalized(root)
            check(normalized.baseURL == "https://\(pair.1)/v1", "Official \(pair.0) root URL is expanded to its v1 API base")
            check(try ModelListRequest(channel: root).url == "https://\(pair.1)/v1/models", "Model discovery from the \(pair.0) root includes v1")
            check(normalized.id == root.id && normalized.apiKey == root.apiKey && normalized.name == root.name && normalized.prefix == root.prefix && normalized.proxyURL == root.proxyURL,
                  "URL normalization does not change account identity or routing")
            check(ModelListRequest.normalized(normalized) == normalized, "Official URL normalization is idempotent")
        }
        var spacedRoot = channel("codex")
        spacedRoot.baseURL = "  https://api.openai.com/  "
        spacedRoot.apiKey = "mock-key"
        check(try ModelListRequest(channel: spacedRoot).url == "https://api.openai.com/v1/models", "Trimming user input does not skip official root normalization")
        var customRoot = channel("relay")
        customRoot.baseURL = "https://relay.example.invalid"
        customRoot.apiKey = "mock-key"
        let customRootRequest = try ModelListRequest(channel: customRoot)
        check(ModelListRequest.normalized(customRoot) == customRoot && customRootRequest.url == "https://relay.example.invalid/models",
              "A custom relay root is not forced to use the official v1 path")

        for pair in [("kimi-code", "api.kimi.com"), ("kimi-code-ai", "api.kimi.ai")] {
            for wire in [WireProtocol.chat, .anthropic, .responses] {
                var code = channel(pair.0)
                code.wire = wire
                code.apiKey = "  mock-kimi-key  "
                code.baseURL = "https://\(pair.1)/coding" + (wire == .anthropic ? "/" : "/v1/")
                let request = try ModelListRequest(channel: code)
                check(request.url == "https://\(pair.1)/coding/v1/models", "Kimi \(pair.0) \(wire.rawValue) model discovery uses the same v1 endpoint")
                check(request.headers["Authorization"] == "Bearer mock-kimi-key" && request.headers["x-api-key"] == nil,
                      "Kimi model discovery uses Bearer regardless of the inference protocol")
                check(request.headers["User-Agent"]?.hasPrefix("BridgeDock/") == true,
                      "Model discovery identifies the actual application")
                var codingRoot = code
                codingRoot.baseURL = "https://\(pair.1)/coding"
                let normalized = ModelListRequest.normalized(codingRoot)
                let expectedBase = "https://\(pair.1)/coding" + (wire == .anthropic ? "" : "/v1")
                check(normalized.baseURL == expectedBase, "Kimi \(wire.rawValue) inference keeps the protocol's expected base path")
                check(try ModelListRequest(channel: codingRoot).url == "https://\(pair.1)/coding/v1/models",
                      "All Kimi coding base variants discover models at v1/models")
                check(ModelListRequest.normalized(normalized) == normalized, "Kimi base normalization cannot duplicate v1")
            }
        }
        var anthropic = channel("claude")
        anthropic.apiKey = "mock-anthropic-key"
        let anthropicRequest = try ModelListRequest(channel: anthropic)
        check(anthropicRequest.url == "https://api.anthropic.com/v1/models" && anthropicRequest.headers["x-api-key"] == "mock-anthropic-key",
              "Kimi's model-list authentication does not replace Anthropic's native authentication")
        var invalidRequest = channel("kimi-code")
        invalidRequest.apiKey = "mock\ninjected-header"
        rejects("Header-injection characters in a model discovery key are rejected") { _ = try ModelListRequest(channel: invalidRequest) }
        invalidRequest.apiKey = "mock"
        invalidRequest.baseURL += "?redirect=other"
        rejects("A query-bearing URL cannot be used for model discovery") { _ = try ModelListRequest(channel: invalidRequest) }

        for pair in [("kimi", "kimi-code"), ("kimi-code", "kimi"), ("kimi-ai", "kimi-code-ai"), ("kimi-code-ai", "kimi-ai")] {
            var source = channel(pair.0)
            source.name = "My named account"
            source.apiKey = "mock-private-key"
            source.prefix = "account-pool-2"
            source.proxyURL = "socks5://127.0.0.1:1080"
            source.modelLines = "user-model = preferred"
            source.enabled = false
            guard let switched = ModelListRequest.kimiAlternative(for: source) else {
                check(false, "Kimi \(pair.0) has a compatible alternative")
                continue
            }
            let target = preset(pair.1)
            check(switched.baseURL == target.url && switched.wire == target.wire && switched.kind == target.title,
                  "Kimi fallback switches the correct regional connection type")
            check(switched.id == source.id && switched.apiKey == source.apiKey && switched.prefix == source.prefix && switched.proxyURL == source.proxyURL,
                  "Kimi fallback preserves credential identity and user routing")
            check(switched.name == source.name && switched.modelLines == source.modelLines && switched.enabled == source.enabled,
                  "Kimi fallback preserves custom names, model edits and enablement")
            check(switched.balanceMode == target.balanceMode, "Kimi fallback updates the default balance adapter")
            source.balanceMode = .custom
            source.balancePath = "/my-balance"
            let custom = ModelListRequest.kimiAlternative(for: source)!
            check(custom.balanceMode == .custom && custom.balancePath == source.balancePath, "Kimi fallback preserves custom balance configuration")
        }
        var defaultNamed = channel("kimi")
        let renamed = ModelListRequest.kimiAlternative(for: defaultNamed)!
        check(renamed.name == preset("kimi-code").title, "An untouched default name follows the corrected Kimi endpoint type")
        defaultNamed.name = "Personal Kimi"
        check(ModelListRequest.kimiAlternative(for: defaultNamed)?.name == "Personal Kimi", "A user name is not replaced by automatic endpoint correction")
        check(ModelListRequest.kimiAlternative(for: channel("deepseek")) == nil, "Other official providers never fall back to a Kimi endpoint")

        let names = ModelListRequest.names(in: ["data": [
            ["id": " beta "], ["id": "alpha"], ["id": "beta"], ["slug": "gamma"],
            ["id": "\n"], ["id": 12], ["other": "ignored"]
        ]])
        check(names == ["alpha", "beta", "gamma"], "Model discovery trims, deduplicates, sorts and skips unusable rows")
        check(ModelListRequest.names(in: ["models": [["slug": "one"], ["id": "two"], ["id": "one"]]]) == ["one", "two"],
              "Both supported upstream model-list envelopes are parsed")
        check(ModelListRequest.names(in: ["error": ["message": "not a model list"]]).isEmpty, "Error payloads cannot create fictitious model IDs")
        check(ModelListRequest.names(in: ["data": [["id": "live"]], "models": [["id": "stale"]]]) == ["live"],
              "The primary model response takes precedence over unrelated fallback data")

        if failures.isEmpty {
            print("PASS \(count) preset, official-origin, model-discovery and Kimi correction assertions")
        } else {
            for failure in failures { print("FAIL: \(failure)") }
            print("FAILED \(failures.count) of \(count) preset assertions")
            exit(1)
        }
    }
}
