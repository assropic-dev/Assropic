import Foundation

@main
struct SubscriptionTests {
    static var count = 0
    static var failures: [String] = []

    static func check(_ condition: Bool, _ message: String) {
        count += 1
        if !condition { failures.append(message) }
    }

    static func rejects(_ message: String, _ operation: () throws -> Void) {
        count += 1
        do {
            try operation()
            failures.append(message)
        } catch {}
    }

    static func object(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func session(_ provider: String) -> LoginSession {
        LoginSession(provider: provider, state: "test-state-7", url: "https://example.invalid/authorize",
                     userCode: "ABCD-EFGH", expiresAt: Date().addingTimeInterval(300), previousAccount: nil)
    }

    static func main() throws {
        let knownProviders = ["claude", "codex", "kimi", "kimi-ai", "kiro", "xai", "zcode-bigmodel", "zcode-zai", "cursor-agent-v1"]
        check(Set(SubscriptionProvider.all.map(\.id)) == Set(knownProviders) && SubscriptionProvider.all.count == knownProviders.count,
              "Every supported subscription has exactly one management entry")
        check(SubscriptionProvider.find("anthropic")?.id == "claude", "Legacy Anthropic provider resolves to Claude login")
        check(SubscriptionProvider.find("unsupported") == nil, "Unknown provider cannot silently select another account flow")
        check(SubscriptionProvider.find("cursor-agent-v1")?.importOnly == false,
              "The Cursor plugin exposes the Grok Bot browser-login flow")
        check(SubscriptionProvider.find("zcode-bigmodel")?.importOnly == false && SubscriptionProvider.find("zcode-zai")?.importOnly == false,
              "Both ZCode portals expose their supported browser-login flows")
        check(session("anthropic").displayName == "Claude", "Legacy provider is presented with the current display name")
        check(session("codex").supportsCallback && !session("kimi").supportsCallback && !session("xai").supportsCallback,
              "Device-code flows do not offer an unrelated redirect callback")
        check(SubscriptionProvider.find("codex")?.supportsRecovery == true && SubscriptionProvider.find("kimi")?.supportsRecovery == false,
              "Only supported flows claim to replace the selected credential")

        let cursorCredential = try CursorAccountProfile.cursor.credential(label: "  工作  ", key: "  key_fixture  ", prefix: "cursor")
        let grokCredential = try CursorAccountProfile.grokBot.credential(label: "", key: "key_fixture", prefix: "grok-bot")
        for credential in [cursorCredential, grokCredential] {
            let imported = try object(CredentialImport.normalized(jsonData(credential)))
            check(imported["type"] as? String == "cursor-agent-v1" && imported["api_key"] as? String == "key_fixture",
                  "Both Cursor and Grok Bot use the Cursor account provider and preserve the shared key")
            check(imported["runtime_profile"] as? String == credential["runtime_profile"] as? String,
                  "Credential import retains the selected Cursor or Grok Bot transport")
        }
        check(cursorCredential["runtime_profile"] as? String == "agent_v1" && grokCredential["runtime_profile"] as? String == "sand",
              "Cursor and Grok Bot select their respective plugin transports")
        check(cursorCredential["note"] as? String == "工作" && grokCredential["prefix"] as? String == "grok-bot",
              "Account notes and separate channel prefixes survive credential construction")
        check(CursorAccountProfile.cursor.filename(digest: "fixture") == "cursor-fixture.json",
              "Existing Cursor filename identity remains unchanged")
        check(CursorAccountProfile.cursor.filename(digest: "fixture") != CursorAccountProfile.grokBot.filename(digest: "fixture"),
              "Using one account key for both transports cannot overwrite its other channel")
        for key in ["", "  ", "key_ fixture", "key_\nfixture"] {
            rejects("Invalid shared account keys never become credentials") {
                _ = try CursorAccountProfile.grokBot.credential(label: "", key: key, prefix: "grok-bot")
            }
        }
        check(Account(["provider": "cursor-agent-v1", "runtime_profile": "sand"]).providerTitle == "Grok Bot",
              "Grok Bot credentials are named by their transport, not mislabeled as Grok Build")
        check(Account(["provider": "cursor-agent-v1"]).providerTitle == "Cursor",
              "Legacy Cursor credentials without a profile retain their display name")

        func sessionToken(subject: String = "auth0|user_fixture", expiry: Double = Date().addingTimeInterval(3600).timeIntervalSince1970) throws -> String {
            let payload = try jsonData(["sub": subject, "exp": expiry]).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "eyJhbGciOiJIUzI1NiJ9." + payload + ".fixture"
        }
        let sessionJWT = try sessionToken()
        for text in ["test@example.invalid----user_fixture::" + sessionJWT, "user_fixture::" + sessionJWT,
                     "WorkosCursorSessionToken=user_fixture%3A%3A" + sessionJWT, sessionJWT] {
            let parsed = try CursorSessionCredential(text)
            check(parsed.userID == "user_fixture" && parsed.subject == "auth0|user_fixture", "Session formats retain the same account identity")
            check(try parsed.verifiedEmail(["sub": "user_fixture", "email": "test@example.invalid"]) == "test@example.invalid",
                  "Remote Cursor profile confirms pasted session identity")
            let credential = try CursorAccountProfile.cursor.credential(label: "工作", key: text, prefix: "cursor2")
            check(credential["auth_method"] as? String == "session" && credential["api_key"] == nil,
                  "Pasted sessions never become API keys")
            check(credential["access_token"] as? String == sessionJWT && credential["runtime_profile"] as? String == "agent_v1",
                  "Session credentials select the Cursor transport")
            check(try object(CredentialImport.normalized(jsonData(credential)))["account_id"] as? String == parsed.subject,
                  "Session credentials survive JSON import")
        }
        for text in ["user_other::" + sessionJWT, "test@example.invalid----user_fixture::broken", "user_fixture::" + (try sessionToken(expiry: 1)),
                     "user_fixture::" + (try sessionToken(subject: "auth0|user_other")), "user_fixture::" + sessionJWT + "\r\nCookie: injected",
                     "user_fixture%3A%3A" + sessionJWT + "%0D%0Ainjected"] {
            rejects("Invalid, expired and mismatched Cursor sessions are rejected") { _ = try CursorSessionCredential(text) }
        }
        let checkedSession = try CursorSessionCredential("test@example.invalid----user_fixture::" + sessionJWT)
        rejects("A different remote account cannot authenticate a pasted session") {
            _ = try checkedSession.verifiedEmail(["sub": "user_other", "email": "test@example.invalid"])
        }
        rejects("A pasted email must match the remote Cursor account") {
            _ = try checkedSession.verifiedEmail(["sub": "user_fixture", "email": "other@example.invalid"])
        }

        let identity = Account(["name": "codex-work.json", "provider": "codex", "email": "same@example.invalid",
                                "status": "active", "note": "工作账户", "priority": "12", "auth_index": "index-1",
                                "id_token": ["chatgpt_account_id": "work-id", "plan_type": "business",
                                             "chatgpt_subscription_active_until": "2027-01-01T00:00:00Z"]])
        check(identity.planName == "business", "Read the actual v8 plan_type claim")
        check(identity.subscriptionUntil == "2027-01-01T00:00:00Z", "Preserve the subscription expiry independently of token expiry")
        check(identity.accountID == "work-id" && identity.authIndex == "index-1", "Retain the account routing identity")
        check(identity.displayName == "工作账户" && identity.priority == 12, "Operator note and string priority survive loading")
        let personal = Account(["name": "codex-personal.json", "email": "same@example.invalid", "status": "active"])
        check(identity.id != personal.id, "Accounts sharing one email remain separate credentials")
        let legacy = Account(["id": "legacy.json", "type": "codex", "label": "Old account",
                              "id_token": ["chatgpt_plan_type": "plus"]])
        check(legacy.provider == "codex" && legacy.email == "Old account" && legacy.planName == "plus", "Legacy credential metadata remains readable")
        check(legacy.priority == 0 && !legacy.disabled && !legacy.requiresSignIn, "Absent optional state uses safe defaults")
        check(Account(["status": "active", "requires_sign_in": true]).statusText == "需要重新授权", "Expired authentication outranks the stale active status")
        check(Account(["status": "active", "requires_sign_in": true, "disabled": true]).statusText == "已停用", "An intentionally disabled account stays disabled in the UI")
        check(Account(["status": "error"]).statusText == "凭据异常", "An error is not presented as a usable account")
        check(Account(["status": "pending"]).statusText == "等待生效", "A pending credential is not presented as active")

        let legacyProxy = AccountOptions(account: identity, document: ["proxy-url": "socks5://127.0.0.1:1080"])
        check(legacyProxy.proxyURL == "socks5://127.0.0.1:1080", "Editing legacy credentials preserves the existing proxy override")
        var options = AccountOptions(account: identity, document: ["prefix": "work", "proxy_url": "socks5://127.0.0.1:1080", "priority": 3])
        check(options.note == "工作账户" && options.priority == 3, "Downloaded routing fields override list defaults without erasing the note")
        options.prefix = "  Team_2-a  "
        options.note = "  候补账户  "
        let edited = try options.fields(name: identity.name)
        check(edited["name"] as? String == identity.name && edited["prefix"] as? String == "Team_2-a", "Patch targets the file identity and trims the routing prefix")
        check(edited["note"] as? String == "候补账户" && edited["priority"] as? Int == 3, "Operator settings are encoded as independent patch fields")
        options.prefix = " \n"
        options.proxyURL = "  "
        options.note = " "
        let cleared = try options.fields(name: identity.name)
        check(cleared["prefix"] as? String == "" && cleared["proxy_url"] as? String == "" && cleared["note"] as? String == "", "Clearing routing fields explicitly removes prior overrides")
        for invalidPrefix in ["../work", "team/model", "two words", "x\nheader", "中文"] {
            options.prefix = invalidPrefix
            rejects("Invalid account prefix must be rejected: \(invalidPrefix)") { _ = try options.fields(name: identity.name) }
        }
        options.prefix = "valid"
        options.proxyURL = "file:///tmp/proxy"
        rejects("Non-network proxy schemes cannot become credential routing overrides") { _ = try options.fields(name: identity.name) }
        options.proxyURL = "direct"
        check(try options.fields(name: identity.name)["proxy_url"] as? String == "direct", "An explicit direct connection remains distinct from inherited routing")

        let codex = session("codex")
        let callback = try OAuthCallback.payload("  http://localhost:1455/auth/callback?state=test-state-7&code=encoded%2Bvalue%3D  ", session: codex)
        check(callback["code"] == "encoded+value=" && callback["state"] == codex.state && callback["provider"] == "codex", "Callback decoding retains exact authorization-code characters")
        let claude = try OAuthCallback.payload("  claude-code#test-state-7 \n", session: session("claude"))
        check(claude["code"] == "claude-code" && claude["provider"] == "claude", "Claude's displayed code#state form can be submitted")
        let claudeAuthURL = "https://claude.ai/oauth/authorize?code=true&client_id=fixture-client-id&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&scope=user%3Ainference&code_challenge=fixture-private-challenge&code_challenge_method=S256&state=test-state-7"
        let claudeSession = LoginSession(provider: "claude", state: "test-state-7", url: claudeAuthURL,
                                        userCode: "", expiresAt: Date().addingTimeInterval(300), previousAccount: nil)
        let claudeCallback = try OAuthCallback.payload("http://localhost:54545/callback?code=fixture-authorization-code%2Bvalue%3D&state=test-state-7", session: claudeSession)
        check(claudeCallback["code"] == "fixture-authorization-code+value=" && claudeCallback["state"] == claudeSession.state,
              "Claude's completed loopback callback retains the real authorization code")
        for authorizationPage in [
            claudeAuthURL,
            "https://claude.ai/oauth/authorize?code=true&state=test-state-7",
            "https://claude.ai/oauth/authorize?code=fixture-private-code&state=test-state-7",
            "https://example.invalid/another-authorize?code=fixture-private-code&state=test-state-7&response_type=code&code_challenge=fixture-private-challenge"
        ] {
            do {
                _ = try OAuthCallback.payload(authorizationPage, session: claudeSession)
                check(false, "The browser authorization page must never be submitted as an OAuth callback")
            } catch {
                let message = error.localizedDescription
                check(message.contains("授权") && message.contains("回调"),
                      "An authorization-page rejection explains that a completed callback is required")
                check(!message.contains(authorizationPage) && !message.contains("fixture-private-code") && !message.contains("fixture-private-challenge") && !message.contains("test-state-7"),
                      "An authorization-page error does not echo the pasted URL or its sensitive values")
            }
        }
        let denied = try OAuthCallback.payload("http://localhost:1455/auth/callback?state=test-state-7&error=access_denied", session: codex)
        check(denied["error"] == "access_denied" && denied["code"] == nil, "An authorization denial is forwarded without inventing a code")
        for badCallback in [
            "http://localhost:1455/auth/callback?state=another-session&code=code",
            "http://localhost:1455/auth/callback?code=code",
            "http://localhost:1455/auth/callback?state=test-state-7",
            "http://localhost:1455/auth/callback?state=test-state-7&code=",
            "http://localhost:1455/auth/callback?state=test-state-7&state=another-session&code=code",
            "http://localhost:1455/auth/callback?state=test-state-7&state=test-state-7&code=code",
            "http://localhost:1455/auth/callback?state=test-state-7&code=one&code=two",
            "http://localhost:1455/auth/callback?state=test-state-7&code=one&code=one",
            "http://localhost:1455/auth/callback?state=test-state-7&error=one&error=two",
            "http://localhost:1455/auth/callback?state=test-state-7&code=code&error=access_denied",
            "http://localhost:1455/auth/callback?state=test-state-7&code=two%20words",
            "http://localhost:1455/auth/callback?state=test-state-7&code=line%0Abreak",
            "http://localhost:1455/auth/callback?state=test-state-7&code=tab%09value"
        ] {
            rejects("Reject incomplete, mismatched or ambiguous OAuth callback: \(badCallback)") { _ = try OAuthCallback.payload(badCallback, session: codex) }
        }
        rejects("A raw code from a different Claude session cannot be attached to the current session") {
            _ = try OAuthCallback.payload("code#another-session", session: session("claude"))
        }
        for malformedCode in ["two words#test-state-7", "line\nbreak#test-state-7", "tab\tvalue#test-state-7"] {
            rejects("A Claude authorization code containing whitespace cannot reach token exchange") {
                _ = try OAuthCallback.payload(malformedCode, session: claudeSession)
            }
        }
        rejects("Codex does not reinterpret arbitrary text as a Claude authorization code") {
            _ = try OAuthCallback.payload("code#test-state-7", session: codex)
        }
        for provider in ["claude", "anthropic", "codex"] {
            check(OAuthCallback.lifetime(provider: provider, advertised: nil) == 300,
                  "Browser callback sessions default to the core's five-minute wait")
            check(OAuthCallback.lifetime(provider: provider, advertised: 900) == 300,
                  "An advertised lifetime cannot extend browser callback sessions past the core deadline")
            check(OAuthCallback.lifetime(provider: provider, advertised: 120) == 120,
                  "A shorter server-advertised browser callback lifetime is preserved")
        }
        check(OAuthCallback.lifetime(provider: "kimi", advertised: nil) == 900,
              "Other login methods retain their fifteen-minute default")
        check(OAuthCallback.lifetime(provider: "cursor-agent-v1", advertised: nil) == 300,
              "Grok Bot's browser login matches the plugin's five-minute expiry")
        check(OAuthCallback.lifetime(provider: "kimi", advertised: 1800) == 1800,
              "Other login methods preserve their server-advertised device-code lifetime")
        check(OAuthCallback.lifetime(provider: "kimi", advertised: 60) == 60,
              "Other login methods honor a shorter server-advertised lifetime")
        check(OAuthCallback.lifetime(provider: "claude", advertised: 0.5) == 0.5,
              "Subsecond server lifetimes are not rounded up")
        for invalidLifetime in [Double.nan, Double.infinity, -1, 0] {
            check(OAuthCallback.lifetime(provider: "claude", advertised: invalidLifetime) == 300,
                  "Invalid server lifetimes do not create an unbounded browser session")
        }
        let expiredClaude = LoginSession(provider: "claude", state: "test-state-7", url: claudeAuthURL,
                                         userCode: "", expiresAt: Date().addingTimeInterval(-1), previousAccount: nil)
        for expiredCallback in [
            "expired-fixture-code#test-state-7",
            "http://localhost:54545/callback?code=expired-fixture-code&state=test-state-7"
        ] {
            rejects("An expired login cannot submit either a displayed code or callback URL") {
                _ = try OAuthCallback.payload(expiredCallback, session: expiredClaude)
            }
        }

        let rawKiro: [String: Any] = ["accessToken": "mock-access", "refreshToken": "mock-refresh", "region": "us-east-1",
                                      "authMethod": "social", "provider": "Github", "expiresAt": "2027-01-01T00:00:00Z"]
        let rawKiroResult = try object(CredentialImport.normalized(jsonData(rawKiro)))
        check(rawKiroResult["type"] as? String == "kiro", "Raw Kiro tokens identify the Kiro credential rather than the social login provider")
        check(rawKiroResult["access_token"] as? String == "mock-access" && rawKiroResult["refresh_token"] as? String == "mock-refresh", "Raw Kiro token names are adapted for the proxy")
        check(rawKiroResult["region"] as? String == "us-east-1" && rawKiroResult["expiresAt"] as? String == "2027-01-01T00:00:00Z", "Import preserves provider-specific refresh metadata")
        let canonicalKiro = try object(CredentialImport.normalized(jsonData(["type": "kiro", "access_token": "canonical", "accessToken": "stale", "refresh_token": "refresh"])))
        check(canonicalKiro["access_token"] as? String == "canonical", "An alias cannot replace an existing canonical token")
        check(canonicalKiro["accessToken"] as? String == "canonical", "Core and Kiro plugin must receive the same token when aliases conflict")
        let snakeKiro = try object(CredentialImport.normalized(jsonData(["type": "kiro", "access_token": "snake-access", "refresh_token": "snake-refresh", "region": "us-west-2"])))
        check(snakeKiro["accessToken"] as? String == "snake-access" && snakeKiro["refreshToken"] as? String == "snake-refresh", "Canonical Kiro tokens are also exposed using the plugin's native names")
        check(snakeKiro["access_token"] as? String == "snake-access" && snakeKiro["region"] as? String == "us-west-2", "Kiro adaptation preserves the original token fields and region")
        for tokenField in ["key", "jwt"] {
            let rawZCode: [String: Any] = ["type": "zcode", "site": "zai", "device": "mock-device", tokenField: "mock-zcode-credential"]
            let zcode = try object(CredentialImport.normalized(jsonData(rawZCode)))
            check(zcode["type"] as? String == "zcode" && zcode["site"] as? String == "zai", "Native ZCode \(tokenField) import preserves site attribution")
            check(zcode["device"] as? String == "mock-device" && zcode[tokenField] as? String == "mock-zcode-credential", "Native ZCode \(tokenField) import preserves renewal credentials")
        }
        for invalidZCode in [
            #"{"type":"zcode","site":"other","device":"mock-device","key":"mock-key"}"#,
            #"{"type":"zcode","site":"zai","key":"mock-key"}"#,
            #"{"type":"zcode","site":"bigmodel","device":"mock-device","jwt":"  "}"#
        ] {
            rejects("Incomplete ZCode login metadata cannot be presented as a usable subscription") {
                _ = try CredentialImport.normalized(Data(invalidZCode.utf8))
            }
        }
        let anthropic = try object(CredentialImport.normalized(jsonData(["type": "anthropic", "access_token": "mock-token", "note": "keep"])))
        check(anthropic["type"] as? String == "claude" && anthropic["note"] as? String == "keep", "Provider aliases normalize without discarding operator metadata")
        for invalid in ["[]", "{}", "null", "{", #"{"type":"codex"}"#, #"{"type":"codex","access_token":"  "}"#,
                        #"{"access_token":"mock-token"}"#, #"{"type":"codex","access_token":true}"#] {
            rejects("Malformed or unusable credential is rejected: \(invalid)") { _ = try CredentialImport.normalized(Data(invalid.utf8)) }
        }
        rejects("Empty nested token data cannot be imported as a usable credential") {
            _ = try CredentialImport.normalized(Data(#"{"type":"codex","token":{}}"#.utf8))
        }
        rejects("Whitespace-only nested tokens cannot be imported as usable credentials") {
            _ = try CredentialImport.normalized(Data(#"{"type":"codex","token":{"refresh_token":"  "}}"#.utf8))
        }
        rejects("Oversized credential documents are rejected before import") {
            _ = try CredentialImport.normalized(jsonData(["type": "codex", "access_token": String(repeating: "x", count: 2_000_001)]))
        }

        if failures.isEmpty {
            print("PASS \(count) subscription identity, account routing, OAuth callback and credential-import assertions")
        } else {
            for failure in failures { print("FAIL: \(failure)") }
            print("FAILED \(failures.count) of \(count) subscription assertions")
            exit(1)
        }
    }
}
