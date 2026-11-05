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
        let route = KiroGatewayRoute(port: 18421, keys: ["": "k-default", "kiro": "k-kiro"])
        let target = ModelGateway.kiroTarget(for: published("claude-opus-5.5", owner: "kiro"), route: route)
        check(target?.port == 18421 && target?.key == "k-default" && target?.model == "claude-opus-5.5", "unprefixed Kiro models use the default key")
        let prefixed = ModelGateway.kiroTarget(for: published("kiro/claude-opus-5.5", owner: "kiro"), route: route)
        check(prefixed?.key == "k-kiro" && prefixed?.model == "claude-opus-5.5", "prefixed Kiro models strip the prefix and use that pool's key")
        check(ModelGateway.kiroTarget(for: published("claude-opus-5-5", owner: "anthropic"), route: route) == nil,
              "a same-named Claude subscription model stays on the core")
        check(ModelGateway.kiroTarget(for: published("kiro-3/claude-opus-5.5", owner: "kiro"), route: route) == nil,
              "a prefix without a runtime key falls back to the core")
        check(KiroRuntimeCredentials.pooledPrefixes(groups: ["kiro": [8], "kiro-2": [7], "*": [7, 8]], pool: [7, 8]) == ["kiro", "kiro-2"],
              "prefixes whose accounts are all pooled route to the pool")
        check(KiroRuntimeCredentials.pooledPrefixes(groups: ["kiro": [8], "kiro-2": [7, 9], "*": [7, 8]], pool: [7, 8]) == ["kiro"],
              "a prefix holding an opted-out account keeps its own key")
        let pooled = KiroGatewayRoute(port: 18421, keys: ["kiro": "k-kiro", "kiro-2": "k-kiro-2", "kiro-3": "k-kiro-3", "*": "k-pool"],
                                      pooledPrefixes: ["kiro", "kiro-2"])
        check(ModelGateway.kiroTarget(for: published("kiro/claude-sonnet-4-6", owner: "kiro"), route: pooled)?.key == "k-pool"
              && ModelGateway.kiroTarget(for: published("kiro-2/claude-sonnet-4-6", owner: "kiro"), route: pooled)?.key == "k-pool",
              "with a shared pool every Kiro prefix uses the pool key")
        check(ModelGateway.kiroTarget(for: published("kiro-3/claude-sonnet-4-6", owner: "kiro"), route: pooled)?.key == "k-kiro-3",
              "an opted-out prefix keeps its own account")
        check(ModelGateway.kiroTarget(for: published("kiro-4/claude-sonnet-4-6", owner: "kiro"), route: pooled) == nil,
              "an unknown prefix still falls back to the core with a pool present")
        check(ModelGateway.kiroTarget(for: published("claude-opus-5.5", owner: "kiro"), route: nil) == nil,
              "without a ready runtime every Kiro request falls back to the core")

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
        print("PASS \(count) Kiro runtime assertions; no network or real credentials.")
    }
}
