import Foundation

// Run with: xcrun swiftc -swift-version 5 Sources/Models.swift Sources/SubscriptionAccounts.swift Sources/Quotas.swift Sources/CCSwitchLink.swift Tests/CCSwitchLinkTests.swift -o /tmp/bridgedock-ccswitch-tests && /tmp/bridgedock-ccswitch-tests
@main
struct CCSwitchLinkTests {
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

    /// 与 Sub2API 前端 KeysView 的生成方式一致：URLSearchParams + btoa(usageScript)。
    static func sub2apiLink(app: String, endpoint: String, model: String? = nil, name: String = "AIportX") -> URL {
        let script = #"({ request: { url: "{{baseUrl}}".replace(/\/+$/, "").replace(/\/v1$/i, "") + "/v1/usage", method: "GET" } })"#
        var items = [("resource", "provider"), ("app", app), ("name", name), ("homepage", "https://api.aiportx.com/v1"),
                     ("endpoint", endpoint), ("apiKey", "sk-mock+key/1=="), ("configFormat", "json"), ("usageEnabled", "true"),
                     ("usageScript", Data(script.utf8).base64EncodedString()), ("usageAutoInterval", "30")]
        if let model { items.insert(("model", model), at: 2) }
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._*")
        let query = items.map { key, value in
            key + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed.union(CharacterSet(charactersIn: " ")))!.replacingOccurrences(of: " ", with: "+")
        }.joined(separator: "&")
        return URL(string: "ccswitch://v1/import?" + query)!
    }

    static func object(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    static func main() throws {
        let claude = try CCSwitchLink(sub2apiLink(app: "claude", endpoint: "https://api.aiportx.com/v1", name: "AIportX Relay"))
        check(claude.apiKey == "sk-mock+key/1==" && claude.name == "AIportX Relay", "Plus signs inside values survive form decoding; + between words is a space")
        check(claude.usageScript.contains("/v1/usage") && claude.balanceMode == .sub2api, "The base64 usage script identifies a Sub2API balance endpoint")
        let claudeImport = try claude.channelImport(existing: [], accounts: [])
        let channel = claudeImport.channel
        check(channel.wire == .anthropic && channel.baseURL == "https://api.aiportx.com", "Claude links become Anthropic channels without a duplicated /v1")
        check(channel.prefix == "aiportx" && channel.relaySite == "AIportX Relay", "The routing prefix comes from the site domain, not the display name")
        check(channel.manageURL == "https://aiportx.com/keys", "The relay's key management page is derived from the API host")
        check(channel.modelLines.isEmpty && claudeImport.existingName == nil, "Without a model the editor queries the relay instead of inventing one")
        rejects("A channel without a model cannot be saved silently") { _ = try channel.validated() }
        var ready = channel; ready.modelLines = "claude-sonnet-5-5"
        check((try? ready.validated())?.manageURL == "https://aiportx.com/keys", "An imported channel validates once it has a model")

        let codex = try CCSwitchLink(sub2apiLink(app: "codex", endpoint: "https://api.aiportx.com", model: "gpt-5.6-sol")).channelImport(existing: [channel], accounts: [])
        check(codex.channel.wire == .responses && codex.channel.baseURL == "https://api.aiportx.com/v1", "Codex links use Responses and gain /v1 at the root")
        check(codex.channel.modelLines == "gpt-5.6-sol" && codex.channel.prefix == "aiportx-2", "The link model is kept and a second import gets its own prefix")

        let again = try claude.channelImport(existing: [channel, codex.channel], accounts: [])
        check(again.channel.id == channel.id && again.existingName == channel.name, "Re-importing the same key updates the existing channel")

        let antigravity = try CCSwitchLink(sub2apiLink(app: "claude", endpoint: "https://api.aiportx.com/v1/antigravity")).channelImport(existing: [], accounts: [])
        check(antigravity.channel.baseURL == "https://api.aiportx.com/antigravity", "Sub-route endpoints keep their path")
        let grok = try CCSwitchLink(sub2apiLink(app: "grokbuild", endpoint: "https://api.aiportx.com/v1")).channelImport(existing: [], accounts: [])
        check(grok.channel.wire == .xai && grok.channel.baseURL == "https://api.aiportx.com/v1", "Grok Build links use the xAI protocol")

        rejects("Gemini-native links are refused with guidance") { _ = try CCSwitchLink(sub2apiLink(app: "gemini", endpoint: "https://api.aiportx.com")).channelImport(existing: [], accounts: []) }
        rejects("Non-import paths are refused") { _ = try CCSwitchLink(URL(string: "ccswitch://v1/other?resource=provider")!) }
        rejects("Other schemes are refused") { _ = try CCSwitchLink(URL(string: "https://v1/import?resource=provider")!) }
        rejects("MCP links are not imported as channels") {
            _ = try CCSwitchLink(URL(string: "ccswitch://v1/import?resource=mcp&apps=claude&config=e30=")!).channelImport(existing: [], accounts: [])
        }
        rejects("Links without a key are refused") {
            _ = try CCSwitchLink(URL(string: "ccswitch://v1/import?resource=provider&app=claude&name=x&endpoint=https%3A%2F%2Fr.example")!).channelImport(existing: [], accounts: [])
        }
        rejects("Credentials in the endpoint are refused") {
            _ = try CCSwitchLink(URL(string: "ccswitch://v1/import?resource=provider&app=claude&name=x&apiKey=k&endpoint=https%3A%2F%2Fu%3Ap%40r.example")!).channelImport(existing: [], accounts: [])
        }

        let config = Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://relay.example/v1","ANTHROPIC_AUTH_TOKEN":"sk-config","ANTHROPIC_MODEL":"claude-opus-5-5"}}"#.utf8).base64EncodedString()
        let configured = try CCSwitchLink(URL(string: "ccswitch://v1/import?resource=provider&app=claude&name=Relay&config=" + config.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!)
        let fromConfig = try configured.channelImport(existing: [], accounts: [])
        check(fromConfig.channel.apiKey == "sk-config" && fromConfig.channel.baseURL == "https://relay.example" && fromConfig.channel.modelLines == "claude-opus-5-5",
              "Links that carry the provider in a base64 config are read too")
        check(fromConfig.channel.manageURL == "https://relay.example" && fromConfig.channel.balanceMode == .auto, "Unknown relays open their site root and keep automatic balance detection")
        let homepage = try CCSwitchLink(URL(string: "ccswitch://v1/import?resource=provider&app=codex&name=R&apiKey=k&endpoint=https%3A%2F%2Fapi.r.example%2Fv1&homepage=https%3A%2F%2Fconsole.r.example%2Ftokens")!)
        check(homepage.manageURL(baseURL: "https://api.r.example/v1") == "https://console.r.example/tokens", "A real homepage is used as the management page")

        check(CCSwitchLink.prefix(forHost: "api.aiportx.com") == "aiportx" && CCSwitchLink.prefix(forHost: "中转.example") == "relay",
              "Prefixes are ASCII and skip API subdomains")

        let wallet = QuotaParser.balance(object(#"{"mode":"unrestricted","isValid":true,"planName":"钱包余额","remaining":12.5,"unit":"USD","balance":12.5,"usage":{"today":{"actual_cost":0.75}}}"#), mode: .sub2api)
        check(wallet.metrics.count == 1 && wallet.metrics[0].remaining == Decimal(string: "12.5") && wallet.plan == "钱包余额", "Sub2API wallet balance")
        check(wallet.details.contains { $0.label == "今日消费" }, "Sub2API daily spend is shown")
        let limited = QuotaParser.balance(object(#"{"mode":"quota_limited","isValid":true,"status":"active","quota":{"limit":50,"used":20,"remaining":30,"unit":"USD"},"remaining":30,"unit":"USD","rate_limits":[{"window":"5h","limit":5,"used":1,"remaining":4,"reset_at":"2026-11-04T12:00:00Z"}],"expires_at":"2026-12-01T00:00:00Z"}"#), mode: .sub2api)
        check(limited.metrics.map(\.id) == ["key-quota", "rate-0"] && limited.metrics[0].limit == 50 && limited.metrics[1].reset != nil, "Sub2API key quota and rate windows")
        check(limited.details.contains { $0.label == "令牌到期" }, "Sub2API key expiry")
        let plan = QuotaParser.balance(object(#"{"mode":"unrestricted","isValid":true,"planName":"Pro","remaining":3,"unit":"USD","subscription":{"daily_usage_usd":2,"daily_limit_usd":5,"weekly_usage_usd":4,"weekly_limit_usd":null,"monthly_usage_usd":9,"monthly_limit_usd":100,"expires_at":"2026-12-01T00:00:00Z"}}"#), mode: .sub2api)
        check(plan.plan == "Pro" && plan.metrics.map(\.id) == ["plan-daily", "plan-monthly"], "Sub2API subscription windows skip unset limits")
        let exhausted = QuotaParser.balance(object(#"{"isValid":false,"status":"quota_exhausted","quota":{"limit":1,"used":1,"remaining":0}}"#), mode: .sub2api)
        check(!exhausted.notes.isEmpty, "An unusable relay key is reported")

        let legacy = try JSONDecoder().decode(Channel.self, from: Data(#"{"id":"old","name":"Old","baseURL":"https://r.example","apiKey":"k","prefix":"old","modelLines":"m"}"#.utf8))
        check(legacy.relaySite.isEmpty && legacy.manageURL.isEmpty, "Channels saved before this version still load")
        let encoded = try JSONDecoder().decode(Channel.self, from: JSONEncoder().encode(ready))
        check(encoded.manageURL == ready.manageURL && encoded.relaySite == ready.relaySite, "Relay site and management page are persisted")

        if failures.isEmpty {
            print("PASS \(count) CC Switch link, relay import and Sub2API balance assertions")
        } else {
            for failure in failures { print("FAIL: \(failure)") }
            print("FAILED \(failures.count) of \(count) assertions")
            exit(1)
        }
    }
}
