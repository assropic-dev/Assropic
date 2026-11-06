import Foundation

// xcrun swiftc -swift-version 5 Sources/AccountRest.swift Sources/KiroRouting.swift Tests/AccountRestTests.swift -o /tmp/bridgedock-rest-tests
@main
struct AccountRestTests {
    static var count = 0
    static func check(_ condition: Bool, _ label: String) {
        precondition(condition, label)
        count += 1
        print("PASS " + label)
    }

    /// Written by CLIProxyAPI 8.0.53 with save-cooldown-status after one simulated 503 (proxy_test.py).
    static let coreFile = """
    {
      "version": 1,
      "auth_id": "openai-compatibility:pool:f40deaefe8a1",
      "provider": "openai-compatible-pool",
      "updated_at": "2026-11-06T13:22:53.17398Z",
      "records": [
        {
          "provider": "openai-compatible-pool",
          "auth_id": "openai-compatibility:pool:f40deaefe8a1",
          "status": "cooling",
          "next_retry_after": "2026-11-06T21:23:53.173722+08:00",
          "reason": "{\\"error\\": {\\"message\\": \\"Simulated transient overload\\"}}",
          "quota": {"exceeded": false, "next_recover_at": "0001-01-01T00:00:00Z", "observed_at": "0001-01-01T00:00:00Z"},
          "last_error": {"message": "overload", "retryable": false, "http_status": 503},
          "updated_at": "2026-11-06T21:22:53.173722+08:00"
        },
        {
          "provider": "openai-compatible-pool",
          "auth_id": "openai-compatibility:pool:f40deaefe8a1",
          "model": "pool-model",
          "status": "cooling",
          "next_retry_after": "2026-11-06T21:23:53.173722+08:00",
          "quota": {"exceeded": false, "next_recover_at": "0001-01-01T00:00:00Z"},
          "last_error": {"http_status": 503}
        }
      ]
    }
    """

    static func main() throws {
        let written = ISO8601DateFormatter().date(from: "2026-11-06T13:22:53Z")!
        let parsed = AccountRestReader.parseCooldown(Data(coreFile.utf8), now: written)
        check(parsed?.authID == "openai-compatibility:pool:f40deaefe8a1", "the core's cooldown file names its credential")
        check(parsed?.rest.reason == .transient && parsed?.rest.models == [], "a whole-credential 503 rest is a transient one")
        check(abs((parsed?.rest.until.timeIntervalSince(written) ?? 0) - 60.17) < 0.01, "the rest ends at next_retry_after, fractional seconds and offset included")
        check(AccountRestReader.parseCooldown(Data(coreFile.utf8), now: written.addingTimeInterval(61)) == nil, "a finished rest is not shown")

        func file(_ records: [[String: Any]]) -> Data {
            try! JSONSerialization.data(withJSONObject: ["auth_id": "claude-a@example.com.json", "records": records])
        }
        let now = written
        let later = { (seconds: Int) in ISO8601DateFormatter().string(from: now.addingTimeInterval(TimeInterval(seconds))) }
        let quota = AccountRestReader.parseCooldown(file([[
            "next_retry_after": later(30), "quota": ["exceeded": true, "next_recover_at": later(7200)], "last_error": ["http_status": 429]]]), now: now)
        check(quota?.rest.reason == .quota && Int(quota!.rest.until.timeIntervalSince(now)) == 7200,
              "an exceeded quota rests until it recovers, even when the retry time is sooner")
        let throttled = AccountRestReader.parseCooldown(file([["next_retry_after": later(45), "last_error": ["http_status": 429]]]), now: now)
        check(throttled?.rest.reason == .throttled, "a 429 without an exceeded quota is a rate limit")
        let auth = AccountRestReader.parseCooldown(file([["next_retry_after": later(45), "last_error": ["http_status": 401]]]), now: now)
        check(auth?.rest.reason == .auth, "401 rests are shown as an authentication problem")
        let models = AccountRestReader.parseCooldown(file([
            ["model": "claude-fable-5-1", "next_retry_after": later(600), "quota": ["exceeded": true]],
            ["model": "claude-opus-5-5", "next_retry_after": later(60), "last_error": ["http_status": 429]],
            ["model": "claude-sonnet-5-5", "next_retry_after": later(-5)]]), now: now)
        check(models?.rest.models == ["claude-fable-5-1", "claude-opus-5-5"] && Int(models!.rest.until.timeIntervalSince(now)) == 600,
              "model-level cooldowns list only the resting models and end with the longest one")
        check(models?.rest.text(now: now)?.hasPrefix("部分模型冷却（claude-fable-5-1、claude-opus-5-5）") == true,
              "a partial rest says which models rest while the account keeps serving the others")
        check(AccountRestReader.parseCooldown(Data("not json".utf8), now: now) == nil
              && AccountRestReader.parseCooldown(file([]), now: now) == nil, "broken or empty files are ignored")

        let rest = AccountRest(until: now.addingTimeInterval(125), reason: .throttled)
        check(rest.text(now: now) == "冷却中 · 上游限流 · 约 2 分 5 秒后恢复", "the countdown reads in minutes and seconds")
        check(rest.text(now: now.addingTimeInterval(125)) == nil, "the line disappears when the rest is over")
        check(AccountRest.duration(3 * 3600 + 120) == "3 小时 2 分" && AccountRest.duration(2 * 86400 + 3600) == "2 天 1 小时"
              && AccountRest.duration(0.2) == "1 秒", "long rests read in hours and days")

        // Cooldown files sit next to the account files; only *.cds is read.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bridgedock-rest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try file([["next_retry_after": ISO8601DateFormatter().string(from: Date().addingTimeInterval(90)), "last_error": ["http_status": 429]]])
            .write(to: directory.appendingPathComponent("claude-a@example.com.cds"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("claude-a@example.com.json"))
        let rests = AccountRestReader.coreRests(directory: directory)
        check(rests.keys.sorted() == ["claude-a@example.com.json"] && rests.values.first?.reason == .throttled,
              "the account directory yields each resting credential once")

        // Kiro: the router knows accounts by worker slot; the list shows them by account file.
        var clock = now
        let router = KiroSessionRouter(clock: { clock })
        router.finish("2", session: nil, outcome: .failure(status: 429, retryAfter: 20))
        router.finish("1", session: nil, outcome: .success)
        let kiro = AccountRestReader.kiroRests(router.snapshot(), slots: ["kiro-a.json": 1, "kiro-b.json": 2], now: now)
        check(kiro.keys.sorted() == ["kiro-b.json"] && kiro["kiro-b.json"]?.reason == .throttled
              && kiro["kiro-b.json"]?.source == "kiro" && Int(kiro["kiro-b.json"]!.until.timeIntervalSince(now)) == 20,
              "a resting Kiro worker shows on its account with the router's reason and time")
        let core = ["kiro-b.json": AccountRest(until: now.addingTimeInterval(999), reason: .quota),
                    "codex-id": AccountRest(until: now.addingTimeInterval(30), reason: .transient)]
        check(AccountRestReader.rest(for: ("kiro-b.json", "kiro-b.json"), core: core, kiro: kiro)?.source == "kiro",
              "for Kiro accounts the router's state wins over the core's")
        check(AccountRestReader.rest(for: ("codex-id", "codex.json"), core: core, kiro: kiro)?.reason == .transient
              && AccountRestReader.rest(for: ("x", "y.json"), core: core, kiro: kiro) == nil,
              "other accounts are matched by the core's credential id")
        router.clearRest("2")
        check(router.snapshot().accounts.first { $0.id == "2" }?.restSeconds == 0, "ending a rest by hand frees the account at once")
        clock = clock.addingTimeInterval(1)
        check(router.select(session: "Z", candidates: [KiroWorkerRoute(id: "2", port: 1, key: "k", prefix: "", pooled: false),
                                                       KiroWorkerRoute(id: "1", port: 2, key: "k", prefix: "", pooled: false)]) != nil,
              "the freed account is selectable again")
        print("PASS \(count) account rest assertions")
    }
}
