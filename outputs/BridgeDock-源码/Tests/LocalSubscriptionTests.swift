import Foundation
import Darwin

@main
struct LocalSubscriptionTests {
    static var count = 0
    static func check(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
        count += 1
    }
    static func rejects(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError(message) } catch { count += 1 }
    }
    static func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    static func object(_ value: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: value) as! [String: Any] }
    static func token(_ claims: [String: Any]) throws -> String {
        "eyJhbGciOiJub25lIn0." + (try data(claims)).base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") + ".fixture"
    }
    static func write(_ value: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data(value).write(to: url)
    }

    static func main() throws {
        let claude: [String: Any] = ["claudeAiOauth": ["accessToken": "fixture-claude", "refreshToken": "fixture-refresh",
            "expiresAt": 4_102_444_800_000, "scopes": ["user:inference"], "subscriptionType": "max", "rateLimitTier": "default_claude_max_5x"],
            "mcpOAuth": ["server": ["accessToken": "must-not-copy"]]]
        let cc = try object(LocalSubscriptionCredentials.normalized(data(claude)))
        check(cc["type"] as? String == "claude", "Claude native wrapper identifies its provider")
        check(cc["access_token"] as? String == "fixture-claude" && cc["refresh_token"] as? String == "fixture-refresh", "Claude token fields map to the core format")
        check(cc["expired"] as? String == "2100-01-01T00:00:00Z", "Claude millisecond expiry becomes RFC3339")
        check(cc["subscription_type"] as? String == "max" && cc["scopes"] as? [String] == ["user:inference"], "Claude subscription metadata survives")
        check(cc["mcpOAuth"] == nil && cc["claudeAiOauth"] == nil, "Unrelated secrets are not copied")
        rejects("Provider mismatches must fail") { _ = try LocalSubscriptionCredentials.normalized(data(claude), provider: "codex") }
        rejects("Legacy provider-only documents cannot bypass selected-provider matching") {
            _ = try LocalSubscriptionCredentials.normalized(data(["provider": "claude", "access_token": "fixture"]), provider: "codex")
        }

        let access = try token(["exp": 4_102_444_800, "email": "fixture@example.invalid"])
        let id = try token(["email": "id@example.invalid", "https://api.openai.com/auth": ["chatgpt_account_id": "workspace-id"]])
        let codex: [String: Any] = ["auth_mode": "chatgpt", "OPENAI_API_KEY": "must-not-copy", "tokens": [
            "access_token": access, "refresh_token": "fixture-codex-refresh", "id_token": id, "account_id": "workspace-id",
            "login_owner_id": "fixture-login", "oauth_provenance": ["issuer": "https://auth.example.invalid", "client_id": "fixture-oauth-client"]],
            "last_refresh": "2099-12-31T23:00:00Z"]
        let cd = try object(LocalSubscriptionCredentials.normalized(data(codex), provider: "gpt"))
        check(cd["type"] as? String == "codex" && cd["account_id"] as? String == "workspace-id", "Codex native account identity survives")
        check(cd["access_token"] as? String == access && cd["id_token"] as? String == id, "Codex JWT bytes remain exact")
        check(cd["email"] as? String == "id@example.invalid" && cd["expired"] as? String == "2100-01-01T00:00:00Z", "JWT display metadata and expiry are decoded")
        check(cd["last_refresh"] as? String == "2099-12-31T23:00:00Z", "Codex refresh date survives")
        check(cd["tokens"] == nil && cd["OPENAI_API_KEY"] == nil, "Codex copies subscription fields only")
        check(cd["login_owner_id"] as? String == "fixture-login" && (cd["oauth_provenance"] as? [String: String])?["issuer"] == "https://auth.example.invalid", "Codex preserves recorded login and OAuth provenance metadata without inferring it")
        rejects("API-key-only Codex is not a subscription") { _ = try LocalSubscriptionCredentials.normalized(data(["OPENAI_API_KEY": "fixture"]), provider: "codex") }
        var apiMode = codex
        apiMode["auth_mode"] = "apikey"
        rejects("Codex API-key mode cannot reuse stale ChatGPT tokens") { _ = try LocalSubscriptionCredentials.normalized(data(apiMode), provider: "codex") }
        rejects("Empty native tokens must fail") { _ = try LocalSubscriptionCredentials.normalized(data(["tokens": ["access_token": " "]] )) }
        rejects("Oversized objects must fail") { _ = try LocalSubscriptionCredentials.normalized(data(["type": "codex", "access_token": String(repeating: "a", count: 2_000_001)])) }

        let kiro: [String: Any] = ["accessToken": "fixture-kiro", "refreshToken": "fixture-kiro-refresh", "authMethod": "IdC",
            "clientIdHash": "abc123", "region": "us-east-1", "expiresAt": "2100-01-01T00:00:00Z"]
        let registration: [String: Any] = ["clientId": "fixture-client", "clientSecret": "fixture-secret", "expiresAt": "2101-01-01T00:00:00Z", "region": "eu-west-1"]
        let kd = try object(LocalSubscriptionCredentials.normalized(data(kiro), kiroRegistration: data(registration)))
        check(kd["type"] as? String == "kiro" && kd["access_token"] as? String == "fixture-kiro", "Kiro aliases remain compatible with the core")
        check(kd["clientId"] as? String == "fixture-client" && kd["clientSecret"] as? String == "fixture-secret", "Kiro merges its paired registration")
        check(kd["region"] as? String == "us-east-1" && kd["expiresAt"] as? String == "2100-01-01T00:00:00Z", "Registration cannot replace token region or expiry")
        let pasted: [String: Any] = ["email": "pasted@example.invalid", "provider": " GitHub ", "accessToken": "fixture-paste-access",
                                    "refreshToken": "fixture-paste-refresh", "totpSecret": "discard-totp", "password": "discard-password",
                                    "cookie": "discard-cookie", "api_key": "discard-api", "unrelated": ["secret": "discard-nested"]]
        let pastedDocuments = try LocalSubscriptionCredentials.kiroDocuments(data(pasted))
        check(pastedDocuments.count == 1, "Single pasted Kiro object is accepted")
        let pastedDocument = try object(pastedDocuments[0])
        check(pastedDocument["type"] as? String == "kiro" && pastedDocument["provider"] as? String == "Github" && pastedDocument["authMethod"] as? String == "social", "GitHub source maps to canonical Kiro social login")
        check(pastedDocument["email"] as? String == "pasted@example.invalid" && pastedDocument["accessToken"] as? String == "fixture-paste-access" && pastedDocument["access_token"] as? String == "fixture-paste-access", "Pasted identity and native/core token aliases survive")
        check(pastedDocument["region"] as? String == "us-east-1" && pastedDocument["profileArn"] == nil, "Pasted social credentials permit missing profile ARN and default the region")
        check(["totpSecret", "password", "cookie", "api_key", "unrelated"].allSatisfy { pastedDocument[$0] == nil }, "Unrelated pasted secrets are removed by the field whitelist")
        let google: [String: Any] = ["provider": "google", "email": "google@example.invalid", "access_token": "fixture-google-access", "refresh_token": "fixture-google-refresh", "profile_arn": "fixture-google-arn", "region": "eu-west-1"]
        let batchData = try JSONSerialization.data(withJSONObject: [pasted, google, pasted])
        let batch = try LocalSubscriptionCredentials.kiroDocuments(batchData)
        check(batch.count == 2, "Pasted arrays deduplicate identical normalized credentials")
        let googleDocument = try object(batch[1])
        check(googleDocument["provider"] as? String == "Google" && googleDocument["authMethod"] as? String == "social", "Google source maps to canonical Kiro social login")
        check(googleDocument["accessToken"] as? String == "fixture-google-access" && googleDocument["profileArn"] as? String == "fixture-google-arn" && googleDocument["region"] as? String == "eu-west-1", "Snake-case Kiro tokens and profile metadata are supported")
        let builderPaste = try LocalSubscriptionCredentials.kiroDocuments(data(["type": "kiro", "provider": "AWS Builder ID", "accessToken": "builder-access", "refreshToken": "builder-refresh", "clientId": "fixture-client", "clientSecret": "fixture-client-secret"]))
        check(try object(builderPaste[0])["authMethod"] as? String == "builder-id", "Builder credentials preserve the Kiro login method")
        rejects("Empty pasted batches must fail") { _ = try LocalSubscriptionCredentials.kiroDocuments(Data("[]".utf8)) }
        rejects("Non-object pasted entries must fail the whole batch") { _ = try LocalSubscriptionCredentials.kiroDocuments(Data("[{}, 1]".utf8)) }
        rejects("Mixed-provider pasted batches must fail") { _ = try LocalSubscriptionCredentials.kiroDocuments(JSONSerialization.data(withJSONObject: [pasted, ["provider": "codex", "accessToken": "fixture", "refreshToken": "fixture"]])) }
        rejects("Explicit unrelated credential types must fail") { _ = try LocalSubscriptionCredentials.kiroDocuments(data(["type": "claude", "provider": "Github", "accessToken": "fixture", "refreshToken": "fixture"])) }
        rejects("Pasted credentials require usable tokens") { _ = try LocalSubscriptionCredentials.kiroDocuments(data(["provider": "Github", "accessToken": " ", "refreshToken": ""])) }
        rejects("Malformed pasted JSON fails safely") { _ = try LocalSubscriptionCredentials.kiroDocuments(Data("not-json".utf8)) }
        rejects("Invalid region cannot enter Kiro endpoint generation") { _ = try LocalSubscriptionCredentials.kiroDocuments(data(["provider": "Github", "accessToken": "fixture", "region": "invalid.example"] )) }
        let legacy = try object(LocalSubscriptionCredentials.normalized(data(["type": "codex", "access_token": "fixture", "disabled": true, "prefix": "existing"])))
        check(legacy["disabled"] as? Bool == true && legacy["prefix"] as? String == "existing", "Existing proxy documents retain routing and disabled state")

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("bridgedock-local-login-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let codexFile = home.appendingPathComponent(".codex/auth.json")
        try write(codex, to: codexFile)
        let before = try Data(contentsOf: codexFile)
        let loaded = try LocalSubscriptionCredentials.load(provider: "chatgpt", home: home, environment: [:])
        check(loaded.provider == "codex" && loaded.source == codexFile.path, "Local Codex loader uses the expected path")
        check(try Data(contentsOf: codexFile) == before, "Loading never rewrites the source login")
        let custom = home.appendingPathComponent("custom-codex")
        try write(codex, to: custom.appendingPathComponent("auth.json"))
        let overridden = try LocalSubscriptionCredentials.load(provider: "codex", home: home, environment: ["CODEX_HOME": custom.path])
        check(overridden.source.hasPrefix(custom.path), "CODEX_HOME is respected")
        let unsafeHome = home.appendingPathComponent("unsafe")
        let unsafeFile = unsafeHome.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: unsafeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: unsafeFile, withDestinationURL: codexFile)
        rejects("Local credential reads reject symbolic links") { _ = try LocalSubscriptionCredentials.load(provider: "codex", home: unsafeHome, environment: [:]) }
        try FileManager.default.removeItem(at: unsafeFile)
        try FileManager.default.createDirectory(at: unsafeFile, withIntermediateDirectories: false)
        rejects("Local credential reads reject directories") { _ = try LocalSubscriptionCredentials.load(provider: "codex", home: unsafeHome, environment: [:]) }
        try FileManager.default.removeItem(at: unsafeFile)
        check(mkfifo(unsafeFile.path, 0o600) == 0, "FIFO fixture is created")
        rejects("Local credential reads reject FIFOs without blocking") { _ = try LocalSubscriptionCredentials.load(provider: "codex", home: unsafeHome, environment: [:]) }
        try FileManager.default.removeItem(at: unsafeFile)
        try Data(repeating: 120, count: 2_000_001).write(to: unsafeFile)
        rejects("Local credential reads reject oversized files") { _ = try LocalSubscriptionCredentials.load(provider: "codex", home: unsafeHome, environment: [:]) }

        let keychain = try LocalSubscriptionCredentials.load(provider: "claude", home: home, environment: [:], keychainReader: { try data(claude) })
        check(keychain.source.contains("钥匙串"), "Claude keychain is read before the file fallback")
        check(try object(keychain.data)["account_id"] == nil, "Claude can load without optional account metadata")
        let claudeConfig = home.appendingPathComponent(".claude.json")
        try write(["oauthAccount": ["accountUuid": "fixture-claude-account", "emailAddress": "claude@example.invalid", "otherSecret": "must-not-copy"], "other": "must-not-copy"], to: claudeConfig)
        let keychainIdentity = try LocalSubscriptionCredentials.load(provider: "claude", home: home, environment: [:], keychainReader: { try data(claude) })
        let claudeIdentity = try object(keychainIdentity.data)
        check(claudeIdentity["account_id"] as? String == "fixture-claude-account" && claudeIdentity["email"] as? String == "claude@example.invalid", "Claude config supplies stable account identity for opaque keychain tokens")
        check(claudeIdentity["otherSecret"] == nil && claudeIdentity["oauthAccount"] == nil && claudeIdentity["other"] == nil, "Only Claude identity fields are copied from config")
        let claudeFile = home.appendingPathComponent(".claude/.credentials.json")
        try write(claude, to: claudeFile)
        let fallback = try LocalSubscriptionCredentials.load(provider: "claude", home: home, environment: [:], keychainReader: { nil })
        check(fallback.source == claudeFile.path, "Missing keychain falls back to the Claude credential file")
        check(try object(fallback.data)["account_id"] as? String == "fixture-claude-account", "Claude file fallback receives the same optional identity metadata")
        let invalidKeychain = try LocalSubscriptionCredentials.load(provider: "claude", home: home, environment: [:], keychainReader: { Data("invalid".utf8) })
        check(invalidKeychain.source == claudeFile.path, "Invalid keychain also permits a valid file fallback")
        let customClaude = home.appendingPathComponent("custom-claude")
        try write(["oauthAccount": ["accountUuid": "custom-account", "emailAddress": "custom@example.invalid"]], to: customClaude.appendingPathComponent(".claude.json"))
        let customClaudeIdentity = try LocalSubscriptionCredentials.load(provider: "claude", home: home, environment: ["CLAUDE_CONFIG_DIR": customClaude.path], keychainReader: { try data(claude) })
        check(try object(customClaudeIdentity.data)["account_id"] as? String == "custom-account", "Custom Claude config directories use their own account metadata")
        let cache = home.appendingPathComponent(".aws/sso/cache")
        try write(kiro, to: cache.appendingPathComponent("kiro-auth-token.json"))
        try write(registration, to: cache.appendingPathComponent("abc123.json"))
        let localKiro = try LocalSubscriptionCredentials.load(provider: "kiro", home: home, environment: [:])
        check(try object(localKiro.data)["clientId"] as? String == "fixture-client", "Kiro loader reads only the matching registration file")
        try FileManager.default.removeItem(at: cache.appendingPathComponent("abc123.json"))
        rejects("Unpaired Kiro SSO tokens cannot appear ready") { _ = try LocalSubscriptionCredentials.load(provider: "kiro", home: home, environment: [:]) }
        var unsafe = kiro
        unsafe["clientIdHash"] = "../../outside"
        try write(unsafe, to: cache.appendingPathComponent("kiro-auth-token.json"))
        rejects("Registration identifiers cannot traverse directories") { _ = try LocalSubscriptionCredentials.load(provider: "kiro", home: home, environment: [:]) }
        let social: [String: Any] = ["accessToken": "fixture", "refreshToken": "fixture-refresh", "authMethod": "social", "profileArn": "fixture-arn"]
        try write(social, to: cache.appendingPathComponent("kiro-auth-token.json"))
        check(try object(LocalSubscriptionCredentials.load(provider: "kiro", home: home, environment: [:]).data)["profileArn"] as? String == "fixture-arn", "Social Kiro login needs no unrelated registration")
        rejects("Unsupported local providers fail clearly") { _ = try LocalSubscriptionCredentials.load(provider: "unsupported", home: home, environment: [:]) }
        print("PASS \(count) native subscription import and local read assertions; synthetic credentials only")
    }
}
