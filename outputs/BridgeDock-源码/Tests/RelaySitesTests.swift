import Foundation

// Run with: xcrun swiftc -swift-version 5 Sources/Models.swift Sources/SubscriptionAccounts.swift Sources/Quotas.swift Sources/CCSwitchLink.swift Sources/ModelPublishing.swift Sources/ModelDiagnostics.swift Sources/RelaySites.swift Sources/ModelVerification.swift Tests/RelaySitesTests.swift -o /tmp/bridgedock-relay-tests && /tmp/bridgedock-relay-tests
@main
struct RelaySitesTests {
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

    static func object(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    static func site() -> RelaySite {
        var site = RelaySite()
        site.id = "site-0001"
        site.origin = "https://www.aiportx.com"
        site.name = "AIportX"
        site.apiBaseURL = "https://api.aiportx.com/v1"
        return site
    }

    static func keyJSON(id: Int, name: String, key: String, platform: String, models: [String], status: String = "active",
                        quota: Double = 0, used: Double = 0, expires: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["id": id, "name": name, "key": key, "status": status, "group_id": 24, "quota": quota, "quota_used": used,
                                    "group": ["id": 24, "name": "GPT-稳定", "platform": platform, "models": models, "rate_multiplier": 0.14, "status": "active"]]
        value["expires_at"] = expires ?? NSNull()
        return value
    }

    static func main() throws {
        // 站点地址
        check(try Sub2API.origin("aiportx.com/dashboard") == "https://aiportx.com", "Bare host gets https and loses its path")
        check(try Sub2API.origin(" https://WWW.AiportX.com/login?redirect=/x ") == "https://www.aiportx.com", "Host is lowercased, query dropped")
        rejects("Plain HTTP sites are refused") { _ = try Sub2API.origin("http://example.com") }
        rejects("Credentials in the URL are refused") { _ = try Sub2API.origin("https://user:pass@example.com") }

        // 响应外壳
        check((try Sub2API.data(object(#"{"code":0,"message":"success","data":{"a":1}}"#)) as? [String: Any])?["a"] as? Int == 1, "code 0 unwraps data")
        rejects("Non-zero code throws") { _ = try Sub2API.data(object(#"{"code":40001,"message":"bad"}"#)) }

        // 识别 Sub2API
        check(Sub2API.looksLikeSub2API(object(#"{"site_name":"AIportX","version":"1.0.214","turnstile_enabled":false,"linuxdo_oauth_enabled":false}"#)), "Public settings of a Sub2API site are recognised")
        check(!Sub2API.looksLikeSub2API(object(#"{"system_name":"New API","turnstile_check":false}"#)), "New API settings are not mistaken for Sub2API")

        // Key 列表与分组
        let list: [String: Any] = ["items": [keyJSON(id: 38685, name: "wyq", key: "sk-abc123def456", platform: "openai", models: ["gpt-6-sol", "gpt-6.1-terra"]),
                                             keyJSON(id: 2, name: "masked", key: "sk-abc****xyz", platform: "anthropic", models: [])],
                                   "page": 1, "pages": 3, "total": 2]
        let (keys, pages) = Sub2API.keys(list)
        check(keys.count == 2 && pages == 3, "Key page parses items and page count")
        check(keys[0].usable && !keys[1].usable, "Masked keys cannot be imported")
        check(keys[0].group?.wire == .responses && keys[0].group?.models.count == 2, "OpenAI groups map to Responses with their models")
        check(Sub2API.wire(platform: "anthropic") == .anthropic && Sub2API.wire(platform: "grok") == .xai && Sub2API.wire(platform: "gemini") == nil,
              "Platform mapping follows the site's CC Switch export; Gemini is unsupported")

        // 失效判断
        let now = Date()
        check(!RelayKey(keyJSON(id: 1, name: "a", key: "sk-x", platform: "openai", models: []))!.exhausted(now: now), "Active unlimited key is usable")
        check(RelayKey(keyJSON(id: 1, name: "a", key: "sk-x", platform: "openai", models: [], status: "disabled"))!.exhausted(now: now), "Disabled key is exhausted")
        check(RelayKey(keyJSON(id: 1, name: "a", key: "sk-x", platform: "openai", models: [], quota: 5, used: 5))!.exhausted(now: now), "Used-up quota is exhausted")
        check(RelayKey(keyJSON(id: 1, name: "a", key: "sk-x", platform: "openai", models: [], expires: "2020-01-01T00:00:00.123456+08:00"))!.exhausted(now: now), "Expired key is exhausted")
        check(RelayKey(keyJSON(id: 1, name: "BridgeDock-1106-2230", key: "sk-x", platform: "openai", models: []))!.managedByBridgeDock, "BridgeDock- keys are managed by BD")

        // 时间解析（微秒 + 时区）
        let parsed = Sub2API.date("2026-11-06T22:26:16.367075+08:00")
        check(parsed == ISO8601DateFormatter().date(from: "2026-11-06T14:26:16Z"), "Microsecond timestamps with offsets parse")

        // 渠道构造
        let channel = try Sub2API.channel(for: keys[0], group: nil, site: site(), existing: [], accounts: [])
        check(channel.wire == .responses && channel.baseURL == "https://api.aiportx.com/v1", "Responses channel uses the published API base with /v1")
        check(channel.apiKey == "sk-abc123def456" && channel.models.count == 2, "Key and group models are copied")
        check(channel.relaySiteID == "site-0001" && channel.relayKeyID == 38685 && channel.relayGroupID == 24, "Site, key and group IDs are recorded")
        check(channel.balanceMode == .sub2api && channel.manageURL == "https://www.aiportx.com/keys", "Balance mode and manage page are set")
        check(channel.prefix == "aiportx", "Prefix comes from the API host")
        check((try? channel.validated()) != nil, "Built channel passes validation")
        let claudeKey = RelayKey(keyJSON(id: 9, name: "c", key: "sk-claude1", platform: "anthropic", models: ["claude-opus-5-5"]))!
        let claude = try Sub2API.channel(for: claudeKey, group: nil, site: site(), existing: [channel], accounts: [])
        check(claude.wire == .anthropic && claude.baseURL == "https://api.aiportx.com", "Anthropic channel drops /v1")
        check(claude.prefix == "aiportx-2", "Second channel on one host gets a fresh prefix")
        var renamed = channel
        renamed.name = "我的 GPT"
        renamed.modelLines = "gpt-6-sol = sol"
        let again = try Sub2API.channel(for: keys[0], group: nil, site: site(), existing: [renamed], accounts: [])
        check(again.id == channel.id && again.name == "我的 GPT", "Re-importing the same key updates the existing channel")
        check(again.modelLines == "gpt-6-sol = sol\ngpt-6.1-terra", "Aliases are kept and only new group models are added")
        var stale = channel
        stale.apiKey = "sk-old-string"
        let refreshed = try Sub2API.channel(for: keys[0], group: nil, site: site(), existing: [stale], accounts: [])
        check(refreshed.id == channel.id && refreshed.apiKey == "sk-abc123def456", "Same site and key ID updates the channel even if the key string changed")
        rejects("Masked key import is refused") { _ = try Sub2API.channel(for: keys[1], group: nil, site: site(), existing: [], accounts: []) }

        // 新建 Key 请求体
        let body = Sub2API.createBody(name: "BridgeDock-x", groupID: 24, quota: 5, expiresInDays: 0)
        check(body["name"] as? String == "BridgeDock-x" && body["group_id"] as? Int == 24 && body["quota"] as? Double == 5 && body["expires_in_days"] == nil,
              "Create body carries only set limits")

        // 令牌续期时机
        check(RelaySession(siteID: "s", accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(3600)).needsRefresh(now: now), "Under 2 hours left refreshes")
        check(!RelaySession(siteID: "s", accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(20 * 3600)).needsRefresh(now: now), "Fresh token waits")

        // 旧版 state.json 兼容
        let oldChannel = try JSONDecoder().decode(Channel.self, from: Data(#"{"name":"x","baseURL":"https://a.com/v1","apiKey":"k","prefix":"x","modelLines":"m"}"#.utf8))
        check(oldChannel.verifyHours == 0 && oldChannel.relaySiteID.isEmpty && oldChannel.verifyModels.isEmpty, "Old channels decode with verification off")
        let oldSettings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port":18417,"channels":[]}"#.utf8))
        check(oldSettings.relaySites.isEmpty, "Old settings decode without relay sites")
        let siteData = try JSONEncoder().encode(site())
        let decodedSite = try JSONDecoder().decode(RelaySite.self, from: siteData)
        check(decodedSite == site() && decodedSite.autoReplaceKeys, "Relay sites round-trip")
        var hours = channel
        hours.verifyHours = 999
        hours.verifyModels = ["gpt-6-sol", "missing"]
        let clamped = try hours.validated()
        check(clamped.verifyHours == 168 && clamped.verifyModels == ["gpt-6-sol"], "Verification interval is clamped and unknown models dropped")

        // 令牌文件
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bd-relay-\(UUID().uuidString)")
        let store = RelaySessionStore(dataDirectory: directory)
        try store.save(RelaySession(siteID: "site-0001", accessToken: "a.b.c", refreshToken: "rt_1", expiresAt: now))
        check(try store.read("site-0001").refreshToken == "rt_1", "Session file round-trips")
        let mode = (try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("relay-sites/site-0001.json").path)[.posixPermissions] as? NSNumber)?.intValue
        check(mode == 0o600, "Session file is private")
        rejects("Path-like site IDs are refused") { _ = try store.read("../state") }
        store.delete("site-0001")
        rejects("Deleted session is gone") { _ = try store.read("site-0001") }
        try? FileManager.default.removeItem(at: directory)

        // 核验：响应格式
        var anthropic = VerificationResponse()
        anthropic.status = 200
        anthropic.json = object(#"{"id":"msg_01","type":"message","role":"assistant","model":"claude-opus-5-5-20261001","content":[{"type":"text","text":"BD-1234"}],"usage":{"input_tokens":20,"cache_read_input_tokens":4500,"cache_creation_input_tokens":0,"output_tokens":5}}"#)
        check(ModelVerification.protocolCheck(anthropic, wire: .anthropic, model: "claude-opus-5-5", marker: "BD-1234").outcome == .pass, "Native Anthropic response with dated model passes")
        check(anthropic.promptTokens == 4520 && anthropic.cachedTokens == 4500, "Anthropic prompt tokens include cache reads")
        var converted = VerificationResponse()
        converted.status = 200
        converted.json = object(#"{"id":"chatcmpl-1","object":"chat.completion","model":"deepseek-v4","choices":[{"message":{"content":"BD-1234"}}],"usage":{"prompt_tokens":20,"completion_tokens":5}}"#)
        check(ModelVerification.protocolCheck(converted, wire: .anthropic, model: "claude-opus-5-5", marker: "BD-1234").outcome == .fail, "Chat-shaped body on the Messages API fails")
        var renamedModel = anthropic
        renamedModel.json["model"] = "claude-haiku-5-5"
        check(ModelVerification.protocolCheck(renamedModel, wire: .anthropic, model: "claude-opus-5-5", marker: "BD-1234").outcome == .warn, "A different returned model is flagged")
        check(ModelVerification.sameModel("openai/gpt-6-sol", "gpt-6-sol") && ModelVerification.sameModel("claude-opus-5.5", "claude-opus-5-5"), "Vendor prefixes and 5.5/5-5 spellings match")

        // 核验：分词指纹
        check(ModelVerification.tokenizerCheck(delta: 4431, reference: 4433, baseline: nil).outcome == .pass, "Delta matching the official reference passes")
        check(ModelVerification.tokenizerCheck(delta: 3900, reference: 4433, baseline: nil).outcome == .fail, "Different tokenizer fails")
        check(ModelVerification.tokenizerCheck(delta: 4431, reference: nil, baseline: nil).outcome == .pass, "First run records a baseline")
        check(ModelVerification.tokenizerCheck(delta: 3900, reference: nil, baseline: 4431).outcome == .warn, "Drift from baseline is suspicious")
        check(ModelVerification.tokenizerCheck(delta: 0, reference: nil, baseline: nil).outcome == .fail, "Usage that ignores input fails")

        // 核验：缓存与 thinking
        check(ModelVerification.cacheCheck(anthropic).outcome == .pass, "Cache hit passes")
        var noCache = anthropic
        noCache.json["usage"] = ["input_tokens": 4520, "output_tokens": 5]
        check(ModelVerification.cacheCheck(noCache).outcome == .warn, "Missing cache hit warns")
        var signed = anthropic
        signed.json["content"] = [["type": "thinking", "thinking": "17*23", "signature": String(repeating: "A", count: 300)], ["type": "text", "text": "391"]]
        check(ModelVerification.thinkingCheck(signed, wire: .anthropic).outcome == .pass, "Signed thinking passes")
        var unsigned = signed
        unsigned.json["content"] = [["type": "thinking", "thinking": "17*23", "signature": ""], ["type": "text", "text": "391"]]
        check(ModelVerification.thinkingCheck(unsigned, wire: .anthropic).outcome == .fail, "Unsigned thinking fails")
        var reasoning = VerificationResponse()
        reasoning.status = 200
        reasoning.json = object(#"{"object":"response","output_text":"391","usage":{"input_tokens":30,"output_tokens":90,"output_tokens_details":{"reasoning_tokens":64}}}"#)
        check(ModelVerification.thinkingCheck(reasoning, wire: .responses).outcome == .pass, "Reasoning tokens pass on Responses")
        check(ModelVerification.thinkingCheck(nil, wire: .anthropic).outcome == .skip, "Unsupported thinking is skipped")

        // 核验：计费
        let started = Date()
        let sent = [ModelVerification.SentRequest(model: "gpt-6-sol", started: started, finished: started.addingTimeInterval(2), promptTokens: 4500, outputTokens: 12)]
        func log(_ input: Int, _ cached: Int, model: String = "gpt-6-sol", output: Int = 12) -> RelayUsageLog {
            let formatter = ISO8601DateFormatter()
            return RelayUsageLog(["model": model, "created_at": formatter.string(from: started.addingTimeInterval(3)),
                                  "input_tokens": input, "cache_read_tokens": cached, "output_tokens": output])!
        }
        check(ModelVerification.billingCheck(sent: sent, logs: [log(500, 4000)]).outcome == .pass, "Matching billing passes")
        check(ModelVerification.billingCheck(sent: sent, logs: [log(6000, 0)]).outcome == .fail, "Overcharged input fails")
        check(ModelVerification.billingCheck(sent: sent, logs: [log(4500, 4000)]).outcome == .pass, "Sites that count cache inside input_tokens are not flagged")
        check(ModelVerification.billingCheck(sent: sent, logs: [log(1500, 4000)]).outcome == .fail, "Extra uncached input on top of cache reads fails")
        check(ModelVerification.billingCheck(sent: sent, logs: [log(4500, 0, model: "other")]).outcome == .warn, "Missing records warn")

        // 结论
        let pass = VerificationCheck(name: "a", outcome: .pass, detail: "")
        let warn = VerificationCheck(name: "b", outcome: .warn, detail: "")
        let fail = VerificationCheck(name: "c", outcome: .fail, detail: "")
        check(ModelVerification.verdict([pass]) == .trusted && ModelVerification.verdict([pass, warn]) == .suspicious
              && ModelVerification.verdict([warn, fail]) == .abnormal && ModelVerification.verdict([]) == .unavailable, "Verdict combines checks")

        // 请求构造
        let longAnthropic = ModelVerification.request(wire: .anthropic, model: "m", marker: "BD-1", long: true, cacheKey: "k")
        let content = ((longAnthropic.body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        check(longAnthropic.path == "/v1/messages" && content.count == 2 && content[0]["cache_control"] != nil, "Long Anthropic probe marks the filler cacheable")
        let longResponses = ModelVerification.request(wire: .responses, model: "m", marker: "BD-1", long: true, cacheKey: "k")
        check(longResponses.path == "/responses" && longResponses.body["prompt_cache_key"] as? String == "k", "Responses probe pins a cache key")
        check(ModelVerification.headers(wire: .anthropic, key: "sk-1")["x-api-key"] == "sk-1", "Anthropic probes send x-api-key")

        if failures.isEmpty {
            print("RelaySitesTests passed \(count) checks")
        } else {
            for failure in failures { print("FAIL: " + failure) }
            print("RelaySitesTests failed \(failures.count) of \(count) checks")
            exit(1)
        }
    }
}
