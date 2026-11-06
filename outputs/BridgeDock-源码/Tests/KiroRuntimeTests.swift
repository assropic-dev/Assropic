import Foundation

@main
struct KiroRuntimeTests {
    static var count = 0
    static func check(_ condition: Bool, _ label: String) {
        precondition(condition, label)
        count += 1
        print("PASS " + label)
    }

    static func main() {
        let social: [String: Any] = ["type": "kiro", "accessToken": "access-a", "access_token": "access-a", "refreshToken": "refresh-a",
                                     "refresh_token": "refresh-a", "profileArn": "arn:aws:codewhisperer:us-east-1:1:profile/A",
                                     "region": "us-east-1", "authMethod": "social", "expiresAt": "2026-11-03T16:00:00Z",
                                     "note": "本机 Kiro", "prefix": "kiro"]
        let idc: [String: Any] = ["type": "kiro", "refresh_token": "refresh-b", "clientId": "client", "clientSecret": "secret",
                                  "authMethod": "IdC", "region": "eu-central-1", "idcRegion": "us-east-1", "disabled": true,
                                  "priority": 3, "proxy_url": "direct", "prefix": "kiro-2"]
        let other: [String: Any] = ["type": "claude", "refresh_token": "x"]
        var ids: [String: UInt64] = ["b.json": 7]
        let document = KiroRuntimeCredentials.document(accounts: [("a.json", social), ("b.json", idc), ("c.json", other)], ids: &ids)
        check(document.count == 2, "only Kiro accounts reach kiro2cc")
        check(ids["b.json"] == 7 && ids["a.json"] == 8, "known ids are kept and new accounts get the next unused id")
        var again = ids
        _ = KiroRuntimeCredentials.document(accounts: [("a.json", social), ("b.json", idc)], ids: &again)
        check(again == ids, "ids are stable across rebuilds")
        let a = document.first { $0["id"] as? UInt64 == 8 }!
        let b = document.first { $0["id"] as? UInt64 == 7 }!
        check(a["authMethod"] as? String == "social" && a["accessToken"] as? String == "access-a" && a["refreshToken"] as? String == "refresh-a",
              "social tokens are carried over")
        check(a["nickname"] as? String == "本机 Kiro" && a["apiRegion"] as? String == "us-east-1", "display name and API region are mapped")
        check(a["subscriptionTitle"] as? String == "KIRO PRO", "accounts get a provisional paid title so Opus routes before usage is read")
        check((a["machineId"] as? String)?.count == 64, "a stable 64-hex machine id is derived")
        // Kiro social logins all carry the same public profileArn; that must not merge their device identity.
        var twin = social; twin["refreshToken"] = "refresh-c"; twin["refresh_token"] = "refresh-c"
        var twinIDs: [String: UInt64] = [:]
        let twins = KiroRuntimeCredentials.document(accounts: [("a.json", social), ("c.json", twin)], ids: &twinIDs)
        check(Set(twins.compactMap { $0["machineId"] as? String }).count == 2,
              "two social accounts sharing one profileArn get different machine ids")
        var rotatedSocial = social; rotatedSocial["refreshToken"] = "refresh-new"; rotatedSocial["refresh_token"] = "refresh-new"
        check(KiroMachineID.derive(accountName: "a.json", account: rotatedSocial) == a["machineId"] as? String,
              "the machine id survives token rotation and re-login")
        check(KiroMachineID.derive(accountName: "a.json", account: social) == KiroMachineID.derive(accountName: "a.json", account: ["refresh_token": "other"]),
              "kiro2cc and the quota request derive the same id for one account")
        var pinned = social; pinned["machineId"] = String(repeating: "AB", count: 32)
        check(KiroMachineID.derive(accountName: "a.json", account: pinned) == String(repeating: "ab", count: 32)
              && KiroMachineID.derive(accountName: "a.json", account: ["machineId": "short"]) == a["machineId"] as? String,
              "a valid machineId in the account wins and an invalid one is ignored")
        check(b["authMethod"] as? String == "idc" && b["clientSecret"] as? String == "secret" && b["authRegion"] as? String == "us-east-1",
              "IdC accounts keep client registration and auth region")
        check(b["disabled"] as? Bool == true && b["priority"] as? Int == 3 && b["proxyUrl"] as? String == "direct",
              "disabled, priority and per-account proxy are mapped")
        check(KiroRuntimeCredentials.authMethod(["clientId": "c", "clientSecret": "s"]) == "idc"
              && KiroRuntimeCredentials.authMethod(["authMethod": "builder-id"]) == "idc"
              && KiroRuntimeCredentials.authMethod([:]) == "social", "auth method is inferred like kiro2cc does")

        let groups = KiroRuntimeCredentials.keyGroups(accounts: [("a.json", social), ("b.json", idc)], ids: ids)
        check(groups == ["kiro": [8]], "disabled accounts get no client key and each prefix is bound to its own accounts")

        check(KiroRuntimeCredentials.poolMembers(accounts: [("a.json", social), ("b.json", idc)], ids: ids) == nil,
              "a single enabled account gets no shared pool key")
        var second = idc; second["disabled"] = false
        check(KiroRuntimeCredentials.poolMembers(accounts: [("a.json", social), ("b.json", second)], ids: ids) == [7, 8],
              "two enabled accounts share one pool key bound to both")
        var optedOut = second; optedOut["pool"] = false
        check(KiroRuntimeCredentials.poolMembers(accounts: [("a.json", social), ("b.json", optedOut)], ids: ids) == nil,
              "an account marked pool=false stays out of the shared pool")
        check(KiroRuntimeCredentials.keyGroups(accounts: [("a.json", social), ("b.json", second)], ids: ids) == ["kiro": [8], "kiro-2": [7]],
              "per-prefix keys stay bound to their own account next to the pool")

        let rotated: [String: Any] = ["id": 8, "accessToken": "access-new", "refreshToken": "refresh-new", "expiresAt": "2026-11-03T17:00:00Z"]
        let merged = KiroRuntimeCredentials.merged(account: social, runtime: rotated)
        check(merged?["access_token"] as? String == "access-new" && merged?["accessToken"] as? String == "access-new"
              && merged?["refresh_token"] as? String == "refresh-new" && merged?["expiresAt"] as? String == "2026-11-03T17:00:00Z",
              "rotated tokens are written back under both field spellings")
        check(merged?["prefix"] as? String == "kiro" && merged?["note"] as? String == "本机 Kiro", "write-back keeps BridgeDock's own fields")
        let stale: [String: Any] = ["accessToken": "old", "refreshToken": "old", "expiresAt": "2026-11-03T15:00:00Z"]
        check(KiroRuntimeCredentials.merged(account: social, runtime: stale) == nil, "an older runtime token never overwrites a newer login")

        let base = KiroRuntime.fingerprint([("a.json", social)], proxyURL: "")
        var renewed = social; renewed["accessToken"] = "access-c"; renewed["expiresAt"] = "2026-11-03T18:00:00Z"
        check(KiroRuntime.fingerprint([("a.json", renewed)], proxyURL: "") == base, "access-token renewal does not trigger a runtime sync")
        var relogged = social; relogged["refreshToken"] = "refresh-z"
        check(KiroRuntime.fingerprint([("a.json", relogged)], proxyURL: "") != base, "a new login triggers a runtime sync")
        var disabled = social; disabled["disabled"] = true
        check(KiroRuntime.fingerprint([("a.json", disabled)], proxyURL: "") != base, "enabling or disabling triggers a runtime sync")
        check(KiroRuntime.fingerprint([("a.json", social)], proxyURL: "http://p:1") != base, "proxy changes trigger a runtime sync")

        func published(_ id: String, owner: String) -> PublishedModel {
            PublishedModel(id: id, publicID: "Kiro/x", sourceID: "s", sourceName: "Kiro", modelName: id, owner: owner, isEnabled: true, metadata: [:])
        }
        // Workers: one kiro2cc per account; the prefix and pool flag decide which may serve a model.
        let w1 = KiroWorkerRoute(id: "1", port: 18431, key: "k1", prefix: "kiro", pooled: true)
        let w2 = KiroWorkerRoute(id: "2", port: 18432, key: "k2", prefix: "kiro-2", pooled: true)
        let w3 = KiroWorkerRoute(id: "3", port: 18433, key: "k3", prefix: "kiro-3", pooled: false)
        let w4 = KiroWorkerRoute(id: "4", port: 18434, key: "k4", prefix: "", pooled: false)
        let route = KiroGatewayRoute(workers: [w1, w2, w3, w4])
        let pooledTarget = ModelGateway.kiroTarget(for: published("kiro/claude-opus-5.5", owner: "kiro"), route: route)
        check(pooledTarget?.workers == [w1, w2] && pooledTarget?.model == "claude-opus-5.5",
              "a pooled prefix may use every pooled account, and the prefix is stripped from the model")
        check(ModelGateway.kiroTarget(for: published("kiro-2/claude-sonnet-4-6", owner: "kiro"), route: route)?.workers == [w1, w2],
              "every pooled prefix shares the same pool")
        check(ModelGateway.kiroTarget(for: published("kiro-3/claude-opus-5.5", owner: "kiro"), route: route)?.workers == [w3],
              "an opted-out account is reached only through its own prefix")
        check(ModelGateway.kiroTarget(for: published("claude-opus-5.5", owner: "kiro"), route: route)?.workers == [w4],
              "unprefixed Kiro models use the unprefixed account")
        check(ModelGateway.kiroTarget(for: published("claude-opus-5-5", owner: "anthropic"), route: route) == nil,
              "a same-named Claude subscription model stays on the core")
        check(ModelGateway.kiroTarget(for: published("kiro-9/claude-opus-5.5", owner: "kiro"), route: route) == nil,
              "a prefix without a ready worker falls back to the core")
        check(ModelGateway.kiroTarget(for: published("claude-opus-5.5", owner: "kiro"), route: nil) == nil,
              "without a ready worker every Kiro request falls back to the core")
        check(KiroGatewayRoute(workers: [w1, w3]).candidates(prefix: "kiro") == [w1],
              "a pool of one is no pool: the prefix keeps its own account")
        check(KiroRuntimeCredentials.pooledPrefixes(groups: ["kiro": [8], "kiro-2": [7], "*": [7, 8]], pool: [7, 8]) == ["kiro", "kiro-2"],
              "prefixes whose accounts are all pooled route to the pool")

        // Conversation keys: every turn of one conversation maps to one key.
        let system: [String: Any] = ["role": "system", "content": "You are Cursor."]
        let firstTurn: [String: Any] = ["messages": [system, ["role": "user", "content": "修复登录页"]]]
        let laterTurn: [String: Any] = ["messages": [system, ["role": "user", "content": "修复登录页"],
                                                     ["role": "assistant", "content": "好的"], ["role": "user", "content": "继续"]]]
        let otherChat: [String: Any] = ["messages": [system, ["role": "user", "content": "写单元测试"]]]
        let key = KiroSessionKey.derive(firstTurn)
        check(key != nil && key == KiroSessionKey.derive(laterTurn), "later turns of a conversation keep its key")
        check(key != KiroSessionKey.derive(otherChat), "another conversation gets another key")
        check(KiroSessionKey.derive(["messages": [["role": "user", "content": [["type": "text", "text": "修复登录页"]]]], "system": "You are Cursor."])
              == KiroSessionKey.derive(["messages": [["role": "user", "content": "修复登录页"]], "system": [["type": "text", "text": "You are Cursor."]]]),
              "Anthropic-style string and block content give the same key")
        check(KiroSessionKey.derive(["metadata": ["user_id": "user_x_session_1"], "messages": [["role": "user", "content": "a"]]])
              == KiroSessionKey.derive(["metadata": ["user_id": "user_x_session_1"], "messages": [["role": "user", "content": "b"]]]),
              "an explicit client session id wins over the prompt")
        check(KiroSessionKey.derive(["messages": [system]]) == nil && KiroSessionKey.derive(["messages": []]) == nil,
              "a body without a user message has no conversation key")
        check(key?.count == 16, "the key is a short digest and keeps nothing of the prompt")

        // The router: placement, stickiness and the switching standard.
        var now = Date(timeIntervalSince1970: 1_000_000)
        var events: [String] = []
        let router = KiroSessionRouter(clock: { now })
        router.onEvent = { events.append($0) }
        let pair = [w1, w2]
        let firstChat = router.select(session: "A", candidates: pair)!
        let secondChat = router.select(session: "B", candidates: pair)!
        check(firstChat.reason == "new" && secondChat.reason == "new" && firstChat.worker != secondChat.worker, "two new conversations go to two different accounts")
        check((0..<5).allSatisfy { _ in router.select(session: "A", candidates: pair) == KiroSessionRouter.Choice(worker: firstChat.worker, reason: "sticky") },
              "a conversation stays on its account")
        router.begin(firstChat.worker.id); router.finish(firstChat.worker.id, session: "A", outcome: .failure(status: 502))
        router.begin(firstChat.worker.id); router.finish(firstChat.worker.id, session: "A", outcome: .failure(status: 503))
        check(router.account(of: "A") == firstChat.worker.id, "two failures in a row do not move a conversation")
        router.begin(firstChat.worker.id); router.finish(firstChat.worker.id, session: "A", outcome: .success)
        router.begin(firstChat.worker.id); router.finish(firstChat.worker.id, session: "A", outcome: .failure(status: 502))
        router.begin(firstChat.worker.id); router.finish(firstChat.worker.id, session: "A", outcome: .failure(status: 502))
        check(router.account(of: "A") == firstChat.worker.id, "a success in between starts the count again")
        router.begin(firstChat.worker.id); router.finish(firstChat.worker.id, session: "A", outcome: .failure(status: 502))
        check(router.account(of: "A") == nil, "the third failure in a row releases the conversation")
        let moved = router.select(session: "A", candidates: pair)!
        check(moved.worker != firstChat.worker && router.account(of: "A") == moved.worker.id,
              "its next turn goes to the other account")
        check(events.contains { $0.contains("连续失败 3 次") }, "the move is written to the router log with its reason")

        let windowed = KiroSessionRouter(clock: { now })
        let c = windowed.select(session: "C", candidates: pair)!
        windowed.finish(c.worker.id, session: "C", outcome: .failure(status: 500))
        windowed.finish(c.worker.id, session: "C", outcome: .failure(status: 500))
        now = now.addingTimeInterval(11 * 60)
        windowed.finish(c.worker.id, session: "C", outcome: .failure(status: 500))
        check(windowed.account(of: "C") == c.worker.id, "failures more than ten minutes apart are not consecutive")
        windowed.finish(c.worker.id, session: "C", outcome: .failure(status: 400))
        windowed.finish(c.worker.id, session: "C", outcome: .failure(status: 404))
        windowed.finish(c.worker.id, session: "C", outcome: .failure(status: 422))
        check(windowed.account(of: "C") == c.worker.id, "client errors never count against an account")

        let hard = KiroSessionRouter(clock: { now })
        let d = hard.select(session: "D", candidates: pair)!
        hard.finish(d.worker.id, session: "D", outcome: .failure(status: 402))
        check(hard.account(of: "D") == nil, "a quota error releases the conversation at once")
        check((0..<4).allSatisfy { hard.select(session: "N\($0)", candidates: pair)?.worker != d.worker },
              "an account out of quota takes no new conversations")
        now = now.addingTimeInterval(11 * 60)
        check((0..<6).contains { hard.select(session: "M\($0)", candidates: pair)?.worker == d.worker },
              "after its cooldown the account is used again")

        let breaker = KiroSessionRouter(clock: { now })
        for _ in 0..<5 { breaker.begin("1"); breaker.finish("1", session: nil, outcome: .failure(status: 503)) }
        check((0..<4).allSatisfy { breaker.select(session: "E\($0)", candidates: pair)?.worker == w2 },
              "five failures in a row open the account's circuit")
        check(breaker.snapshot().accounts.first { $0.id == "1" }?.circuitOpen == true, "the open circuit shows in the snapshot")
        check(breaker.select(session: nil, candidates: [w1])?.worker == w1, "with every circuit open the request is still tried")
        now = now.addingTimeInterval(2 * 60 + 1)
        breaker.finish("1", session: nil, outcome: .success)
        check(breaker.snapshot().accounts.first { $0.id == "1" }?.circuitOpen == false, "a success after the cooldown closes the circuit")

        let home = KiroSessionRouter(clock: { now })
        let g = home.select(session: "G", candidates: pair)!
        for _ in 0..<5 { home.finish(g.worker.id, session: nil, outcome: .failure(status: 503)) }
        let away = home.select(session: "G", candidates: pair)!
        check(away.reason == "standby" && away.worker != g.worker && home.account(of: "G") == g.worker.id,
              "while its account's circuit is open a turn goes elsewhere and the conversation keeps its home")
        now = now.addingTimeInterval(2 * 60 + 1)
        check(home.select(session: "G", candidates: pair) == KiroSessionRouter.Choice(worker: g.worker, reason: "sticky"),
              "after the cooldown the conversation is back on its own account")

        let retry = KiroSessionRouter(clock: { now })
        let f = retry.select(session: "F", candidates: pair)!
        retry.begin(f.worker.id); retry.finish(f.worker.id, session: "F", outcome: .unreachable)
        let retried = retry.select(session: "F", candidates: pair, excluding: [f.worker.id])!
        check(retried.reason == "retry" && retried.worker != f.worker && retry.account(of: "F") == f.worker.id,
              "a request whose account is unreachable is retried elsewhere without moving the conversation")
        check(retry.select(session: "F", candidates: pair, excluding: ["1", "2"]) == nil, "no account left means no choice")
        let remaining = f.worker.id == "1" ? w2 : w1
        let standby = retry.select(session: "F", candidates: [remaining])!
        check(standby.reason == "standby" && standby.worker == remaining && retry.account(of: "F") == f.worker.id,
              "while its account is out of the route a turn is served elsewhere and the conversation keeps its home")
        now = now.addingTimeInterval(61)
        let lone = retry.select(session: "F", candidates: [remaining])!
        check(lone.reason == "moved" && retry.account(of: "F") == remaining.id,
              "an account gone for over a minute hands its conversation over")
        retry.begin("1"); retry.begin("1"); retry.finish("1", session: nil, outcome: .cancelled)
        check(retry.snapshot().accounts.first { $0.id == "1" }?.inFlight == 1, "a cancelled request only releases its in-flight slot")
        now = now.addingTimeInterval(7 * 60 * 60)
        _ = retry.select(session: "other", candidates: pair)
        check(retry.account(of: "F") == nil, "a conversation idle for six hours is forgotten")
        check((try? JSONEncoder().encode(retry.snapshot())) != nil, "the snapshot encodes for router-state.json")
        check(KiroSessionRouter.retriesElsewhere(status: 429) && KiroSessionRouter.retriesElsewhere(status: 402)
              && KiroSessionRouter.retriesElsewhere(status: 401) && KiroSessionRouter.retriesElsewhere(status: 503)
              && !KiroSessionRouter.retriesElsewhere(status: 400) && !KiroSessionRouter.retriesElsewhere(status: 200),
              "only account-side errors are retried on another account")

        // 429 is a rate limit: the account rests for its Retry-After, conversations keep their home.
        let throttle = KiroSessionRouter(clock: { now })
        var throttleEvents: [String] = []
        throttle.onEvent = { throttleEvents.append($0) }
        let t = throttle.select(session: "T", candidates: pair)!
        for _ in 0..<6 { throttle.begin(t.worker.id); throttle.finish(t.worker.id, session: "T", outcome: .failure(status: 429, retryAfter: 5)) }
        check(throttle.account(of: "T") == t.worker.id, "rate limits never move a conversation, however many")
        check(throttle.snapshot().accounts.first { $0.id == t.worker.id }?.consecutiveFailures == 0,
              "rate limits do not count toward the failure circuit")
        let resting = throttle.snapshot().accounts.first { $0.id == t.worker.id }
        check(resting?.circuitOpen == true && resting?.restSeconds == 5 && resting?.restReason == "throttled",
              "the account rests for the upstream's Retry-After and the snapshot shows why and how long")
        let duringRest = throttle.select(session: "T", candidates: pair)!
        check(duringRest.reason == "standby" && duringRest.worker != t.worker, "while it rests a turn is served elsewhere")
        check(throttle.select(session: "T2", candidates: pair)?.worker != t.worker, "a resting account takes no new conversations")
        check(throttleEvents.contains { $0.contains("429") && $0.contains("会话保持原账号") }, "the rate limit is written to the router log")
        now = now.addingTimeInterval(6)
        check(throttle.select(session: "T", candidates: pair) == KiroSessionRouter.Choice(worker: t.worker, reason: "sticky"),
              "after the rest the conversation is back on its own account")
        throttle.finish(t.worker.id, session: "T", outcome: .failure(status: 429, retryAfter: 3600))
        check(throttle.snapshot().accounts.first { $0.id == t.worker.id }?.restSeconds == 60, "a Retry-After longer than a minute is capped")
        now = now.addingTimeInterval(61)
        throttle.finish(t.worker.id, session: "T", outcome: .failure(status: 429))
        check(throttle.snapshot().accounts.first { $0.id == t.worker.id }?.restSeconds == 5, "without a Retry-After the rest is five seconds")
        throttle.finish(t.worker.id, session: "T", outcome: .failure(status: 402))
        throttle.finish(t.worker.id, session: nil, outcome: .failure(status: 429, retryAfter: 1))
        let quotaRest = throttle.snapshot().accounts.first { $0.id == t.worker.id }
        check(quotaRest?.restReason == "quota" && (quotaRest?.restSeconds ?? 0) > 500, "a short rate-limit rest never shortens a quota rest")

        // 401/403 is confirmed by a second one before the account is treated as broken.
        let auth = KiroSessionRouter(clock: { now })
        let ua = auth.select(session: "U", candidates: pair)!
        auth.finish(ua.worker.id, session: "U", outcome: .failure(status: 401))
        let firstAuth = auth.snapshot().accounts.first { $0.id == ua.worker.id }
        check(auth.account(of: "U") == ua.worker.id && firstAuth?.restReason == "auth" && firstAuth?.restSeconds == 30,
              "a first 401 rests the account for 30 seconds and keeps its conversations")
        now = now.addingTimeInterval(31)
        auth.finish(ua.worker.id, session: "U", outcome: .success)
        auth.finish(ua.worker.id, session: "U", outcome: .failure(status: 403))
        check(auth.account(of: "U") == ua.worker.id, "a success in between clears the first rejection")
        auth.finish(ua.worker.id, session: "U", outcome: .failure(status: 403))
        let confirmed = auth.snapshot().accounts.first { $0.id == ua.worker.id }
        check(auth.account(of: "U") == nil && confirmed?.restReason == "auth" && (confirmed?.restSeconds ?? 0) == 600,
              "a second rejection in a row releases the conversation and rests the account ten minutes")
        let spaced = KiroSessionRouter(clock: { now })
        let ub = spaced.select(session: "V", candidates: pair)!
        spaced.finish(ub.worker.id, session: "V", outcome: .failure(status: 401))
        now = now.addingTimeInterval(11 * 60)
        spaced.finish(ub.worker.id, session: "V", outcome: .failure(status: 401))
        check(spaced.account(of: "V") == ub.worker.id, "rejections more than ten minutes apart are not confirmed")

        // Retry-After for the client: only when every account of the model is resting.
        let wait = KiroSessionRouter(clock: { now })
        check(wait.retryAfter(candidates: pair) == nil, "no Retry-After while an account is available")
        wait.finish("1", session: nil, outcome: .failure(status: 429, retryAfter: 8))
        check(wait.retryAfter(candidates: pair) == nil, "one resting account still leaves another available")
        wait.finish("2", session: nil, outcome: .failure(status: 429, retryAfter: 3))
        check(wait.retryAfter(candidates: pair) == 3, "with every account resting the client waits for the soonest one")
        check(KiroSessionRouter.retryAfter("12") == 12 && KiroSessionRouter.retryAfter(" 0 ") == 0
              && KiroSessionRouter.retryAfter("-1") == nil && KiroSessionRouter.retryAfter("soon") == nil && KiroSessionRouter.retryAfter(nil) == nil,
              "Retry-After seconds are parsed and junk is ignored")
        let httpDate = KiroSessionRouter.retryAfter("Wed, 21 Oct 2015 07:28:30 GMT", now: Date(timeIntervalSince1970: 1445412480))
        check(httpDate == 30, "an HTTP-date Retry-After becomes seconds from now")

        // A burst of failovers spreads by requests in flight instead of piling onto one account.
        let herd = KiroSessionRouter(clock: { now })
        let h3 = KiroWorkerRoute(id: "3", port: 18433, key: "k3", prefix: "kiro", pooled: true)
        let trio = [w1, w2, h3]
        _ = herd.select(session: "H1", candidates: trio); _ = herd.select(session: "H2", candidates: trio); _ = herd.select(session: "H3", candidates: trio)
        let homeOfH1 = herd.account(of: "H1")!
        // One of the other accounts holds four more conversations: by conversation count alone every
        // standby turn would land on the quieter one.
        let busy = trio.first { $0.id != homeOfH1 }!
        for n in 4...7 { _ = herd.select(session: "H\(n)", candidates: [busy]) }
        herd.finish(homeOfH1, session: nil, outcome: .failure(status: 429, retryAfter: 30))
        var placed: [String: Int] = [:]
        for _ in 0..<6 {
            let choice = herd.select(session: "H1", candidates: trio)!
            herd.begin(choice.worker.id)
            placed[choice.worker.id, default: 0] += 1
        }
        check(placed[homeOfH1] == nil && placed.count == 2 && placed.values.allSatisfy { $0 == 3 },
              "six standby turns at once are split evenly over the other accounts")

        // Slots fix each account's worker folder and port.
        var slots: [String: Int] = [:]
        check(KiroWorkerSlots.assign(["b.json", "a.json"], to: &slots) && slots == ["a.json": 1, "b.json": 2],
              "accounts get slots in name order")
        check(!KiroWorkerSlots.assign(["a.json", "b.json"], to: &slots), "known accounts keep their slots")
        KiroWorkerSlots.assign(["a.json", "c.json"], to: &slots)
        check(slots["c.json"] == 3 && slots["b.json"] == 2, "a new account never takes a remembered account's slot")
        check(KiroWorkerSlots.port(1) == 18431 && KiroWorkerSlots.port(2) == 18432, "slot n listens on 18430 + n")

        // Live changes: what kiro2cc is told without restarting.
        let base1: [String: Any] = ["id": UInt64(1), "refreshToken": "r1", "authMethod": "social", "profileArn": "arn-1", "priority": 0, "disabled": false]
        let base2: [String: Any] = ["id": UInt64(2), "refreshToken": "r2", "authMethod": "idc", "clientId": "c", "clientSecret": "s",
                                    "authRegion": "us-east-1", "priority": 0, "disabled": false]
        let unchanged = KiroRuntimeChange.between(old: ["a": base1, "b": base2], new: ["a": base1, "b": base2])
        check(unchanged.isEmpty, "identical accounts need no change")
        var b2Off = base2; b2Off["disabled"] = true
        var a1Prio = base1; a1Prio["priority"] = 4
        let toggled = KiroRuntimeChange.between(old: ["a": base1, "b": base2], new: ["a": a1Prio, "b": b2Off])
        check(toggled.disabled == ["b": true] && toggled.priority == ["a": 4] && toggled.updated.isEmpty && !toggled.needsRestart,
              "disabling and reprioritising are applied live")
        var newMachine = base1; newMachine["machineId"] = String(repeating: "c", count: 64)
        check(KiroRuntimeChange.between(old: ["a": base1], new: ["a": newMachine]).updated == ["a"],
              "a changed machine id is pushed to kiro2cc as an update")
        let added = KiroRuntimeChange.between(old: ["a": base1], new: ["a": base1, "b": base2])
        check(added.added == ["b"] && added.removed.isEmpty && !added.needsRestart, "a new account is added live")
        let removed = KiroRuntimeChange.between(old: ["a": base1, "b": base2], new: ["a": base1])
        check(removed.removed == ["b"] && removed.added.isEmpty, "a deleted account is removed live")
        var relogin = base1; relogin["refreshToken"] = "r1-new"; relogin["profileArn"] = nil
        let updated = KiroRuntimeChange.between(old: ["a": base1], new: ["a": relogin])
        check(updated.updated == ["a"] && !updated.needsRestart, "a new login, even one dropping its profile ARN, is an in-place update")
        var lostClient = base2; lostClient["clientId"] = nil
        check(KiroRuntimeChange.between(old: ["b": base2], new: ["b": lostClient]).needsRestart,
              "a field the admin API cannot clear falls back to a restart")
        let rotatedRuntime = KiroRuntime.withRuntimeTokens(["a": base1], runtime: [1: ["id": 1, "refreshToken": "r1-rotated"]])
        var copiedBack = base1; copiedBack["refreshToken"] = "r1-rotated"
        check(KiroRuntimeChange.between(old: rotatedRuntime, new: ["a": copiedBack]).isEmpty,
              "a refresh token kiro2cc rotated and BridgeDock copied back is not treated as a new login")

        let keyPlan = KiroRuntimeChange.keys(current: ["": [1], "*": [1, 2], "kiro-2": [2]], desired: ["": [1, 3], "*": [1, 2, 3], "kiro-3": [3]])
        check(keyPlan.create == ["kiro-3"] && keyPlan.rebind == ["", "*"] && keyPlan.delete == ["kiro-2"],
              "client keys are created, rebound and deleted to match the accounts")
        check(KiroRuntimeChange.keys(current: ["*": [1, 2]], desired: ["*": [1, 2]]) == ([], [], []), "unchanged keys are left alone")

        let addBody = KiroRuntimeCredentials.addRequest(document.first { $0["id"] as? UInt64 == 7 }!)
        check(addBody["refreshToken"] as? String == "refresh-b" && addBody["authMethod"] as? String == "idc"
              && addBody["clientSecret"] as? String == "secret" && addBody["disabled"] as? Bool == true && addBody["priority"] as? Int == 3
              && addBody["proxyUrl"] as? String == "direct" && addBody["accessToken"] == nil && addBody["id"] == nil,
              "the add request carries the login and settings but no id or access token")
        let updateBody = KiroRuntimeCredentials.updateRequest(["refreshToken": "r", "authMethod": "social"])
        check(updateBody["profileArn"] as? String == "" && updateBody["proxyUrl"] as? String == "" && updateBody["refreshToken"] as? String == "r",
              "an update clears a profile ARN or per-account proxy that is gone")

        check((0...8).map { KiroRuntimeRestart.delay(attempt: $0) } == [1, 2, 4, 8, 16, 32, 60, 60, 60],
              "crash restarts back off 1, 2, 4 … seconds up to one minute")

        let fractional = KiroRuntimeCredentials.date("2026-11-05T15:34:39.826476+00:00")
        let plain = KiroRuntimeCredentials.date("2026-11-05T15:34:39Z")
        check(fractional != nil && plain != nil && abs(fractional!.timeIntervalSince(plain!) - 0.826) < 0.01
              && KiroRuntimeCredentials.date("not a date") == nil, "cached formatters parse both timestamp forms")
        check(ModelGateway.isUnreachable(URLError(.cannotConnectToHost)) && ModelGateway.isUnreachable(URLError(.networkConnectionLost))
              && !ModelGateway.isUnreachable(URLError(.timedOut)) && !ModelGateway.isUnreachable(URLError(.cancelled)),
              "only a kiro2cc that could not be reached is retried on the core")
        check(ModelPublishing.kiroThinking(ModelCapability(contextLength: 1_000_000), owner: "kiro", name: "claude-opus-5.5")?.reasoningEfforts
              == ["low", "medium", "high", "xhigh", "max"], "Kiro's Claude models advertise every thinking level kiro2cc accepts")
        check(ModelPublishing.kiroThinking(nil, owner: "Kiro", name: "claude-sonnet-4-6")?.reasoningEfforts?.count == 5,
              "a Kiro Claude model without a known capability still gets thinking levels")
        check(ModelPublishing.kiroThinking(ModelCapability(reasoningEfforts: ["high"]), owner: "kiro", name: "claude-opus-5.5")?.reasoningEfforts == ["high"],
              "levels the core already lists for a Kiro model are kept")
        check(ModelPublishing.kiroThinking(nil, owner: "kiro", name: "auto") == nil
              && ModelPublishing.kiroThinking(nil, owner: "anthropic", name: "claude-opus-5-5") == nil,
              "Kiro's auto model and other providers are left alone")
        print("PASS \(count) Kiro runtime assertions; no network or real credentials.")
    }
}
