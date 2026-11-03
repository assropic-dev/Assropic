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
        let probes = ModelTestProbe.make(for: .routing)
        check(probes.count == 3, "three independently graded capability probes")
        for probe in probes {
            check(probe.grade(probe.expectedJSON!) == true, "generated answer passes " + probe.title)
            check(probe.grade("```json\n" + probe.expectedJSON! + "\n```") == true, "single JSON fence accepted")
            check(probe.grade("I am a powerful model") == false, "self-description cannot pass capability probe")
        }
        check(ModelTestProbe(title: "type", prompt: "", expectedJSON: "{\"answer\":1}").grade("{\"answer\":true}") == false, "boolean cannot pass integer answer")
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
