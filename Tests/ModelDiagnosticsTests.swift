import Foundation

@main
struct ModelDiagnosticsTests {
    static var count = 0
    static func check(_ condition: Bool, _ label: String) {
        precondition(condition, label)
        count += 1
        print("PASS " + label)
    }

    static func main() async throws {
        check(ModelTestProbe.candyAnswer(round: [7, 9, 8], star: [7, 6, 4]) == 21, "candy solver reproduces the published answer 21")
        let original = ModelTestProbe.candy(index: 1, round: [7, 9, 8], star: [7, 6, 4], flavors: ["苹果", "桃子", "西瓜"])
        check(original.expectedJSON == "{\"answer\":21}" && original.prompt.contains("五角星形      7      6      4"), "original candy table renders")
        let probes = ModelTestProbe.make(for: .reasoning)
        check(probes.count == 3 && probes.allSatisfy { $0.usesEffort && $0.maxTokens >= 16_000 }, "three effort-controlled reasoning probes")
        for probe in probes {
            check(probe.grade(probe.expectedJSON!) == true, "generated answer passes " + probe.title)
            check(probe.grade("```json\n" + probe.expectedJSON! + "\n```") == true, "single JSON fence accepted")
            check(probe.grade("Worked solution {x}. Final:\n" + probe.expectedJSON!) == true, "trailing JSON after a worked solution accepted")
            check(probe.grade("I am a powerful model") == false, "self-description cannot pass capability probe")
        }
        check(original.grade("先试 {\"answer\":21}，验证后改为 {\"answer\":22}") == false, "only the final JSON answer counts")
        check(ModelTestProbe(title: "type", prompt: "", expectedJSON: "{\"answer\":1}").grade("{\"answer\":true}") == false, "boolean cannot pass integer answer")
        let needles = ModelTestProbe.make(for: .longContext)
        check(needles.map(\.contextTier) == [32_768, 131_072] && needles.allSatisfy { $0.grade($0.expectedJSON!) == true }, "long-context tiers are graded")
        check(needles[1].prompt.utf8.count > 220_000, "128k tier carries a real haystack")
        let million = ModelTestProbe.make(for: .longContext, contextLimit: 1_048_576).map(\.contextTier)
        check(million == [200_000, 262_144, 524_288, 1_048_576], "tiers follow the provider's declared limit up to its maximum")

        let base0 = URL(string: "http://127.0.0.1:1")!
        func body(_ wire: String, _ effort: ModelReasoningEffort, _ style: AnthropicThinkingStyle = .adaptive) throws -> [String: Any] {
            let request = try ModelTestHTTP.request(baseURL: base0, key: "k", model: "m", wire: wire, probe: original, streaming: false, effort: effort, thinking: style)
            return try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        }
        check((try body("responses", .high)["reasoning"] as? [String: String]) == ["effort": "high"], "Responses sends reasoning.effort")
        check((try body("chat", .low)["reasoning_effort"] as? String) == "low", "Chat sends reasoning_effort")
        check((try body("chat", .unset)["reasoning_effort"]) == nil, "unset effort is not sent")
        let adaptive = try body("anthropic", .medium)
        check((adaptive["thinking"] as? [String: String])?["type"] == "adaptive" && (adaptive["output_config"] as? [String: String]) == ["effort": "medium"], "Anthropic adaptive thinking with effort")
        check(((try body("anthropic", .medium, .budget)["thinking"] as? [String: Any])?["budget_tokens"] as? Int) == 16_000, "Anthropic budget thinking fallback")
        let quickBody = try JSONSerialization.jsonObject(with: ModelTestHTTP.request(baseURL: base0, key: "k", model: "m", wire: "anthropic", probe: ModelTestProbe.make(for: .quick)[0], streaming: false, effort: .high).httpBody!) as! [String: Any]
        check(quickBody["thinking"] == nil, "non-reasoning probes never request thinking")

        var reasoning = ModelTestPayload()
        try reasoning.consume(Data(#"{"choices":[{"message":{"content":"{\"answer\":3}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":90,"completion_tokens":800,"completion_tokens_details":{"reasoning_tokens":760}}}"#.utf8), streaming: false)
        check(reasoning.reasoningTokens == 760 && reasoning.inputTokens == 90, "Chat reasoning tokens parsed")
        var responsesUsage = ModelTestPayload()
        try responsesUsage.consume(Data(#"{"status":"completed","output_text":"x","usage":{"input_tokens":5,"output_tokens":50,"output_tokens_details":{"reasoning_tokens":42}}}"#.utf8), streaming: false)
        check(responsesUsage.reasoningTokens == 42, "Responses reasoning tokens parsed")
        let longSignature = String(repeating: "S", count: 400)
        var signed = ModelTestPayload()
        try signed.consume(Data(#"{"content":[{"type":"thinking","thinking":"...","signature":"\#(longSignature)"},{"type":"text","text":"ok"}]}"#.utf8), streaming: false)
        check(signed.thinking(requested: true) == .signed(400) && signed.text == "ok", "non-stream thinking signature verified")
        var streamedSignature = ModelTestPayload()
        try streamedSignature.consume(Data(#"{"type":"content_block_start","content_block":{"type":"thinking","thinking":""}}"#.utf8), streaming: true)
        try streamedSignature.consume(Data(#"{"type":"content_block_delta","delta":{"type":"signature_delta","signature":"short"}}"#.utf8), streaming: true)
        check(streamedSignature.thinking(requested: true) == .shortSignature(5), "streamed short signature flagged")
        check(ModelTestPayload().thinking(requested: true) == .missing && ModelTestPayload().thinking(requested: false) == .notRequested, "missing thinking flagged only when requested")
        check(Set(ModelTestProbe.make(for: .connectivity).compactMap(\.marker)).count == 3, "every connectivity request has a fresh challenge")

        var settings = AppSettings()
        var channel = Channel()
        channel.id = "fixture"; channel.name = "测试渠道"; channel.prefix = "test"
        channel.modelLines = "actual-model = advertised-model"
        settings.channels = [channel]
        let catalog = ModelPublishing.catalog(rawModels: [ModelItem(id: "test/advertised-model", owner: "mock")], settings: settings, accounts: [])
        let route = ModelRouteExpectation(model: catalog[0].publicID, catalog: catalog, settings: settings)
        check(route.upstreamIDs == ["actual-model"], "resolve upstream through configured alias")
        check(!route.finding(for: ["actual-model"]).warning, "configured alias is not reported as substitution")
        check(route.finding(for: ["actual-model-mini"]).warning, "do not normalize away different model suffix")
        check(route.finding(for: ["actual-model", "other-model"]).warning, "mixed model identities remain visible")
        check(route.finding(for: [catalog[0].publicID]).title.contains("别名"), "public echo is not proof of upstream identity")
        check(route.finding(for: []).title.contains("信息不足"), "missing model field remains inconclusive")

        var payload = ModelTestPayload()
        for line in [": keepalive", "", "data: {\"model\":\"fixture\",", "data: \"choices\":[{\"delta\":{\"content\":\"hello\"}}]}", "", "data: [DONE]", ""] { try payload.line(line) }
        check(payload.text == "hello" && payload.complete && payload.models == ["fixture"], "multiline SSE and comments parsed correctly")
        var failure = ModelTestPayload()
        try failure.consume(Data(#"{"type":"error","error":{"message":"overloaded"}}"#.utf8), streaming: true)
        check(failure.error == "overloaded" && !failure.complete, "200 SSE error remains failure")
        var truncated = ModelTestPayload()
        try truncated.consume(Data(#"{"choices":[{"delta":{"content":"partial"},"finish_reason":"length"}]}"#.utf8), streaming: true)
        check(truncated.truncated && !truncated.complete, "length finish does not hide missing terminator")
        var responses = ModelTestPayload()
        try responses.consume(Data(#"{"type":"response.output_text.delta","delta":"hello"}"#.utf8), streaming: true)
        try responses.consume(Data(#"{"type":"response.completed","response":{"model":"response-model","output":[{"content":[{"type":"output_text","text":"hello"}]}],"usage":{"output_tokens":7}}}"#.utf8), streaming: true)
        check(responses.text == "hello" && responses.outputTokens == 7 && responses.complete, "Responses final event does not duplicate text")

        guard CommandLine.arguments.count > 1 else { print("PASS \(count) model diagnostic assertions"); return }
        let base = URL(string: CommandLine.arguments[1])!
        let probe = ModelTestProbe(title: "network", prompt: "Reply with BD_FIXTURE", marker: "BD_FIXTURE")
        for wire in ["chat", "responses", "anthropic"] {
            let request = try ModelTestHTTP.request(baseURL: base, key: "test-key", model: "normal", wire: wire, probe: probe, streaming: true)
            let sample = await ModelTestHTTP.perform(request, probe: probe, index: 0)
            check(sample.succeeded && sample.text == "BD_FIXTURE" && sample.httpStatus == 200, wire + " streaming succeeds")
            check(sample.returnedModels == ["upstream-fixture"], wire + " captures response model")
            check((sample.firstTextSeconds ?? 0) >= 0.1 && sample.duration > sample.firstTextSeconds!, wire + " measures first text after keepalive")
            let jsonRequest = try ModelTestHTTP.request(baseURL: base, key: "test-key", model: "normal", wire: wire, probe: probe, streaming: false)
            let json = await ModelTestHTTP.perform(jsonRequest, probe: probe, index: 0)
            check(json.succeeded && !json.streaming && json.firstTextSeconds == nil, wire + " JSON does not invent first-text latency")
        }
        for model in ["cutoff", "rate-limit", "empty", "bad-json", "stream-error", "truncated", "wrong-marker", "redirect"] {
            let request = try ModelTestHTTP.request(baseURL: base, key: "test-key", model: model, wire: "chat", probe: probe, streaming: true)
            let sample = await ModelTestHTTP.perform(request, probe: probe, index: 0)
            check(!sample.succeeded, model + " is not a false success")
            if model == "rate-limit" { check(sample.httpStatus == 429 && sample.error!.contains("限流"), "rate limit receives a useful diagnosis") }
            if model == "redirect" { check(sample.httpStatus == 302, "redirect is not followed with local key") }
        }
        for (model, expected) in [("thinking-signed", ThinkingEvidence.signed(400)), ("thinking-stripped", .missing)] {
            let request = try ModelTestHTTP.request(baseURL: base, key: "test-key", model: model, wire: "anthropic", probe: original, streaming: false, effort: .high)
            let sample = await ModelTestHTTP.perform(request, probe: original, index: 0)
            check(sample.succeeded && sample.answerCorrect == true && sample.thinking == expected, model + " thinking evidence over HTTP")
        }
        let slow = try ModelTestHTTP.request(baseURL: base, key: "test-key", model: "slow", wire: "chat", probe: probe, streaming: true)
        let task = Task { await ModelTestHTTP.perform(slow, probe: probe, index: 0) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let cancelStart = ProcessInfo.processInfo.systemUptime
        task.cancel()
        let cancelled = await task.value
        check(!cancelled.succeeded && cancelled.error!.contains("取消") && ProcessInfo.processInfo.systemUptime - cancelStart < 2, "cancellation aborts in-flight networking promptly")
        print("PASS \(count) model diagnostic assertions")
    }
}
