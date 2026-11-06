import Foundation
import CoreFoundation
import Darwin
import CryptoKit

struct LocalSubscriptionCredential {
    let provider: String
    let source: String
    let data: Data
}

enum LocalSubscriptionError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

/// Reads local login material without logging, refreshing, importing or modifying it.
/// Codex schema: github.com/openai/codex, codex-rs/login/src/auth/storage.rs and token_data.rs.
/// Kiro schema: github.com/xiaokui-dev/cliproxyapi-kiro-plugin, internal/kiro/types.go.
enum LocalSubscriptionCredentials {
    private static let limit = 2_000_000

    /// Parses one pasted Kiro credential or a batch. Only Kiro login fields
    /// survive; passwords, TOTP seeds, cookies and unrelated secrets are dropped.
    /// The whole batch is validated before any document is returned.
    static func kiroDocuments(_ data: Data) throws -> [Data] {
        guard data.count <= limit, let parsed = try? JSONSerialization.jsonObject(with: data) else {
            throw LocalSubscriptionError.message("请粘贴不超过 2 MB 的 Kiro 凭据 JSON 对象或数组。")
        }
        let values: [Any]
        if let object = parsed as? [String: Any] { values = [object] }
        else if let array = parsed as? [Any], !array.isEmpty { values = array }
        else { throw LocalSubscriptionError.message("Kiro 凭据应为一个 JSON 对象，或至少包含一个对象的数组。") }
        var result: [Data] = []
        var seen = Set<Data>()
        for (index, value) in values.enumerated() {
            do {
                guard let source = value as? [String: Any], !source.isEmpty else {
                    throw LocalSubscriptionError.message("每条凭据都必须是 JSON 对象。")
                }
                if let type = source["type"] {
                    guard let type = type as? String, canonicalProvider(type) == "kiro" else {
                        throw LocalSubscriptionError.message("只支持 Kiro 凭据，不能混入其他服务的账号。")
                    }
                }
                var document: [String: Any] = ["type": "kiro"]
                let mapping = ["email": "email", "access_token": "accessToken", "refresh_token": "refreshToken",
                               "profile_arn": "profileArn", "client_id": "clientId", "client_secret": "clientSecret",
                               "client_id_hash": "clientIdHash", "idc_region": "idcRegion", "expires_at": "expiresAt"]
                copyStrings(source, into: &document, mapping: mapping)
                for key in ["accessToken", "refreshToken", "profileArn", "clientId", "clientSecret", "clientIdHash", "idcRegion", "expiresAt"] {
                    if let value = nonempty(source[key]) { document[key] = value }
                }
                if document["expiresAt"] == nil, let value = nonempty(source["expired"]) { document["expiresAt"] = value }
                if let rawExpiry = source["expiresAt"] as? NSNumber, CFGetTypeID(rawExpiry) != CFBooleanGetTypeID(),
                   let expiry = secondsDate(rawExpiry.doubleValue > 100_000_000_000 ? rawExpiry.doubleValue / 1000 : rawExpiry.doubleValue) {
                    document["expiresAt"] = expiry
                }
                let region = nonempty(source["region"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "us-east-1"
                guard validKiroRegion(region) else { throw LocalSubscriptionError.message("Kiro 凭据的区域格式无效。") }
                document["region"] = region
                if let region = nonempty(document["idcRegion"]), !validKiroRegion(region) {
                    throw LocalSubscriptionError.message("Kiro 凭据的组织区域格式无效。")
                }
                if let hash = nonempty(document["clientIdHash"]), hash.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) == nil {
                    throw LocalSubscriptionError.message("Kiro 客户端注册文件标识无效。")
                }
                let provider = nonempty(source["provider"])
                if source["provider"] != nil, provider == nil {
                    throw LocalSubscriptionError.message("Kiro 登录来源必须是有效的名称。")
                }
                var social = false
                if let provider {
                    switch compactLoginName(provider) {
                    case "github": document["provider"] = "Github"; social = true
                    case "google": document["provider"] = "Google"; social = true
                    case "kiro": document["provider"] = "kiro"
                    case "aws", "builderid", "awsbuilderid": document["provider"] = "BuilderId"
                    case "idc", "sso", "iamidentitycenter": document["provider"] = "IdC"
                    default: throw LocalSubscriptionError.message("只支持 Kiro 的 Google、GitHub、AWS Builder ID 或组织登录凭据。")
                    }
                }
                if social { document["authMethod"] = "social" }
                else if let method = nonempty(source["authMethod"]) ?? nonempty(source["auth_method"]) {
                    switch compactLoginName(method) {
                    case "social": document["authMethod"] = "social"
                    case "builderid", "awsbuilderid": document["authMethod"] = "builder-id"
                    case "idc", "sso", "iamidentitycenter": document["authMethod"] = "idc"
                    default: throw LocalSubscriptionError.message("Kiro 凭据的登录方式无法识别。")
                    }
                } else if let provider = document["provider"] as? String {
                    if provider == "BuilderId" { document["authMethod"] = "builder-id" }
                    if provider == "IdC" { document["authMethod"] = "idc" }
                }
                let encoded = try normalized(JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]), provider: "kiro")
                if seen.insert(encoded).inserted { result.append(encoded) }
            } catch {
                throw LocalSubscriptionError.message("第 \(index + 1) 条凭据：" + error.localizedDescription)
            }
        }
        return result
    }

    private static func compactLoginName(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
    }

    private static func validKiroRegion(_ region: String) -> Bool {
        region.range(of: "^[a-z]{2}(?:-gov)?-[a-z]+-[0-9]+$", options: .regularExpression) != nil
    }

    /// Converts native files to the same format accepted by CredentialImport.
    /// Native wrappers are unpacked selectively, so unrelated MCP/API credentials
    /// in the original file are never copied into the subscription account.
    static func normalized(_ data: Data, provider requestedProvider: String? = nil,
                           kiroRegistration: Data? = nil) throws -> Data {
        let root = try object(data)
        let requested = requestedProvider.map(canonicalProvider)
        let declared = (root["type"] as? String ?? root["provider"] as? String).map(canonicalProvider)
        let inferred: String?
        if root["claudeAiOauth"] is [String: Any] { inferred = "claude" }
        else if root["tokens"] is [String: Any] { inferred = "codex" }
        else if root["accessToken"] is String, root["refreshToken"] is String,
                declared == "kiro" || (declared == nil && requested == nil) { inferred = "kiro" }
        else { inferred = declared }
        if let requested, let inferred, requested != inferred {
            throw LocalSubscriptionError.message("凭据所属服务与所选订阅服务不一致。")
        }
        let provider = requested ?? inferred
        if provider == "codex", root["tokens"] is [String: Any],
           let mode = nonempty(root["auth_mode"]),
           !["chatgpt", "chatgptauthtokens"].contains(mode.lowercased()) {
            throw LocalSubscriptionError.message("Codex 当前没有使用 ChatGPT 订阅登录，请先在 Codex 中切换到 ChatGPT 登录。")
        }
        var document = root
        if provider == "claude", let oauth = root["claudeAiOauth"] as? [String: Any] {
            document = ["type": "claude"]
            copyStrings(oauth, into: &document, mapping: ["accessToken": "access_token", "refreshToken": "refresh_token",
                                                       "subscriptionType": "subscription_type", "rateLimitTier": "rate_limit_tier"])
            if let expiry = millisecondsDate(oauth["expiresAt"]) { document["expired"] = expiry }
            if let scopes = oauth["scopes"] as? [String] { document["scopes"] = scopes }
        } else if provider == "codex", let tokens = root["tokens"] as? [String: Any] {
            document = ["type": "codex"]
            copyStrings(tokens, into: &document, mapping: ["access_token": "access_token", "refresh_token": "refresh_token",
                                                         "id_token": "id_token", "account_id": "account_id",
                                                         "login_owner_id": "login_owner_id"])
            if let provenance = tokens["oauth_provenance"] as? [String: Any],
               let issuer = nonempty(provenance["issuer"]), let client = nonempty(provenance["client_id"]) {
                document["oauth_provenance"] = ["issuer": issuer, "client_id": client]
            }
            if let refresh = nonempty(root["last_refresh"]) { document["last_refresh"] = refresh }
            // JWT claims are display/expiry hints only; no authority or endpoint
            // is inferred from these unverified payloads.
            let accessClaims = jwtClaims(nonempty(tokens["access_token"]))
            let idClaims = jwtClaims(nonempty(tokens["id_token"]))
            if let email = nonempty(idClaims["email"]) ?? nonempty(accessClaims["email"]) {
                document["email"] = email
            }
            if let expiry = secondsDate(accessClaims["exp"]) { document["expired"] = expiry }
        } else if provider == "kiro" {
            document["type"] = "kiro"
            if let kiroRegistration {
                let registration = try object(kiroRegistration)
                for key in ["clientId", "clientSecret", "region", "idcRegion"] where nonempty(document[key]) == nil {
                    if let value = nonempty(registration[key]) { document[key] = value }
                }
            }
        }
        if document["type"] == nil, let provider { document["type"] = provider }
        do {
            return try CredentialImport.normalized(JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]))
        } catch {
            throw LocalSubscriptionError.message("未找到可用的订阅登录令牌，请先在对应客户端登录，或使用浏览器授权。")
        }
    }

    /// `keychainReader` and `desktopProcessReader` are injectable for tests;
    /// their results stay in memory. The caller decides whether and how to
    /// import the returned credential.
    static func load(provider: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     keychainReader: (() throws -> Data?)? = nil,
                     desktopProcessReader: (() throws -> Data?)? = nil) throws -> LocalSubscriptionCredential {
        guard let first = try loadAll(provider: provider, home: home, environment: environment,
                                      keychainReader: keychainReader,
                                      desktopProcessReader: desktopProcessReader).first else {
            throw missing(canonicalProvider(provider))
        }
        return first
    }

    /// Loads every locally available Claude account. Claude Code normally puts
    /// its OAuth blob in the macOS keychain or `~/.claude/.credentials.json`.
    /// Claude Desktop launches its embedded Code runtime with the current
    /// OAuth access token in the child process environment instead, so a
    /// desktop login can be present without either of those files existing.
    /// Returning all distinct identities lets a machine with different Desktop
    /// and standalone Code accounts import both without overwriting either.
    static func loadAll(provider: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        keychainReader: (() throws -> Data?)? = nil,
                        desktopProcessReader: (() throws -> Data?)? = nil) throws -> [LocalSubscriptionCredential] {
        let provider = canonicalProvider(provider)
        switch provider {
        case "claude":
            var candidates: [(credential: LocalSubscriptionCredential, priority: Int)] = []
            var lastError: Error?

            // Desktop's process token is a short-lived access token. Keep it
            // as the lowest-priority candidate so a standalone Code keychain
            // or file credential (which includes a refresh token) wins when
            // both processes represent the same account.
            if let processData = try? (desktopProcessReader ?? readClaudeDesktopProcesses)(),
               let desktop = claudeDesktopCredentials(processData) {
                candidates.append(contentsOf: desktop.map { ($0, 1) })
            }

            if let keychainReader {
                if let result = try? keychainReader(),
                   let data = try? normalized(result, provider: provider) {
                    do {
                        candidates.append((.init(provider: provider, source: "Claude Code · macOS 钥匙串",
                                                 data: try addingClaudeIdentity(data, home: home, environment: environment)), 3))
                    } catch { lastError = error }
                }
            } else {
                for service in claudeKeychainServices(environment: environment) {
                    if let result = try? readClaudeKeychain(service: service),
                       let data = try? normalized(result, provider: provider) {
                        do {
                            candidates.append((.init(provider: provider, source: "Claude Code · macOS 钥匙串",
                                                     data: try addingClaudeIdentity(data, home: home, environment: environment)), 3))
                            break
                        } catch { lastError = error }
                    }
                }
            }
            let configured = nonempty(environment["CLAUDE_CONFIG_DIR"])
            let directory = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent(".claude", isDirectory: true)
            let fileURL = directory.appendingPathComponent(".credentials.json")
            if let data = try? readFile(fileURL) {
                do {
                    candidates.append((.init(provider: provider, source: fileURL.path,
                                             data: try addingClaudeIdentity(normalized(data, provider: provider), home: home, environment: environment)), 2))
                } catch { lastError = error }
            }
            let selected = distinctClaudeCandidates(candidates)
            if !selected.isEmpty { return selected }
            if let lastError { throw lastError }
            throw missing(provider)
        case "codex":
            let configured = nonempty(environment["CODEX_HOME"])
            let directory = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent(".codex", isDirectory: true)
            return [try loadFile(directory.appendingPathComponent("auth.json"), provider: provider)]
        case "kiro":
            let directory = home.appendingPathComponent(".aws/sso/cache", isDirectory: true)
            let url = directory.appendingPathComponent("kiro-auth-token.json")
            guard let token = try? readFile(url), let metadata = try? object(token) else {
                throw missing(provider)
            }
            var registration: Data?
            if let hash = nonempty(metadata["clientIdHash"]) {
                guard hash.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
                    throw LocalSubscriptionError.message("Kiro 客户端注册文件标识无效，请在 Kiro 中重新登录。")
                }
                registration = try? readFile(directory.appendingPathComponent(hash + ".json"))
            }
            let data = try normalized(token, provider: provider, kiroRegistration: registration)
            let document = try object(data)
            let social = nonempty(document["authMethod"])?.lowercased() == "social"
            if social {
                guard nonempty(document["profileArn"]) != nil else {
                    throw LocalSubscriptionError.message("Kiro 社交登录缺少 profileArn，请在 Kiro 中重新登录后再导入。")
                }
            } else {
                guard nonempty(document["clientId"]) != nil, nonempty(document["clientSecret"]) != nil else {
                    throw LocalSubscriptionError.message("Kiro 登录缺少配套的客户端注册信息，请在 Kiro 中重新登录，或使用 AWS Builder ID 浏览器授权。")
                }
            }
            return [.init(provider: provider, source: url.path, data: data)]
        case "kimi", "kimi-ai":
            return [try loadKimiCode(provider: provider, home: home, environment: environment)]
        case "xai", "cursor-agent-v1", "zcode":
            return [try loadGeneric(provider: provider, home: home, environment: environment)]
        default:
            throw LocalSubscriptionError.message("此服务暂不支持读取本机订阅登录。")
        }
    }

    private static func distinctClaudeCandidates(_ candidates: [(credential: LocalSubscriptionCredential, priority: Int)]) -> [LocalSubscriptionCredential] {
        var selected: [(credential: LocalSubscriptionCredential, priority: Int)] = []
        var byIdentity: [String: Int] = [:]
        for candidate in candidates {
            guard let document = try? object(candidate.credential.data) else { continue }
            let identity = LocalSubscriptionIdentity.stableIdentity(document)
                ?? filenameIdentity(candidate.credential)
            if let index = byIdentity[identity] {
                if candidate.priority > selected[index].priority { selected[index] = candidate }
            } else {
                byIdentity[identity] = selected.count
                selected.append(candidate)
            }
        }
        return selected.sorted { $0.priority > $1.priority }.map(\.credential)
    }

    private static func filenameIdentity(_ credential: LocalSubscriptionCredential) -> String {
        // This is only a de-duplication key for opaque tokens. It is never
        // written to disk or exposed in the UI.
        let document = (try? object(credential.data)) ?? [:]
        return credential.source + "\0" + (document["access_token"] as? String ?? "")
    }

    /// Kimi Code keeps the login token in a separate OAuth store.  The TOML
    /// provider entry contains only a reference such as
    /// `oauth = { storage = "file", key = "oauth/kimi-code" }`; treating
    /// config.toml as a flat credential file therefore loses the real token.
    private static func loadKimiCode(provider: String, home: URL,
                                     environment: [String: String]) throws -> LocalSubscriptionCredential {
        let configured = nonempty(environment["KIMI_CODE_HOME"])
            ?? nonempty(environment["KIMI_HOME"])
        let root = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".kimi-code", isDirectory: true)
        let credentialsDirectory = root.appendingPathComponent("credentials", isDirectory: true)
        var fileCandidates: [URL] = []
        var keyringCandidates: [String] = []

        // Read the config only to resolve OAuth references. A configured API
        // key is not used as the subscription login when an OAuth file exists.
        for configURL in [root.appendingPathComponent("config.toml"),
                          root.appendingPathComponent("config.json")] {
            guard let data = try? readFile(configURL),
                  let config = configObject(data, toml: configURL.pathExtension == "toml") else { continue }
            for reference in kimiOAuthReferences(config) {
                if reference.storage == "keyring" {
                    keyringCandidates.append(reference.key)
                } else if let file = credentialFile(directory: credentialsDirectory, key: reference.key) {
                    fileCandidates.append(file)
                }
            }
        }

        // Current kimi-cli uses oauth/kimi-code, which is written as
        // credentials/kimi-code.json.  Include this known path even when the
        // config was partially written or is being migrated.
        if let known = credentialFile(directory: credentialsDirectory, key: "oauth/kimi-code") {
            fileCandidates.append(known)
        }
        // Older releases and local test fixtures used a single credentials or
        // auth file.  Keep those paths after the OAuth store so a real login
        // token is selected before an unrelated API key in config.toml.
        fileCandidates.append(contentsOf: [
            root.appendingPathComponent("credentials.json"),
            root.appendingPathComponent("auth.json")
        ])
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: credentialsDirectory.path) {
            for entry in entries.sorted() where entry.hasSuffix(".json") && entry != "config.json" {
                fileCandidates.append(credentialsDirectory.appendingPathComponent(entry))
            }
        }

        var seen = Set<String>()
        for url in fileCandidates where seen.insert(url.standardizedFileURL.path).inserted {
            guard let data = try? readFile(url),
                  let converted = normalizeKimi(data, provider: provider, identity: url.lastPathComponent) else { continue }
            return .init(provider: provider, source: url.path, data: converted)
        }
        for key in keyringCandidates where !key.isEmpty {
            guard let data = try? readKimiKeychain(key: key),
                  let converted = normalizeKimi(data, provider: provider, identity: key) else { continue }
            return .init(provider: provider, source: "Kimi Code · macOS 钥匙串", data: converted)
        }
        // A GUI-launched Assropic does not inherit a shell's
        // KIMI_CODE_HOME. Keep the documented config-directory override
        // discoverable when the CLI was launched from a shell.
        if configured == nil {
            let alternate = home.appendingPathComponent(".config/kimi-code", isDirectory: true)
            var fallbackEnvironment = environment
            fallbackEnvironment["KIMI_CODE_HOME"] = alternate.path
            if let fallback = try? loadKimiCode(provider: provider, home: home, environment: fallbackEnvironment) {
                return fallback
            }
        }
        throw missing(provider)
    }

    private struct KimiOAuthReference {
        let storage: String
        let key: String
    }

    private static func kimiOAuthReferences(_ root: [String: Any]) -> [KimiOAuthReference] {
        var result: [KimiOAuthReference] = []
        func inspect(_ value: Any, name: String) {
            guard let provider = value as? [String: Any] else { return }
            let type = nonempty(provider["type"])?.lowercased() ?? ""
            let looksLikeKimi = ["kimi", "kimi-ai"].contains(type) || name.lowercased().contains("kimi")
            guard looksLikeKimi, let oauth = provider["oauth"] as? [String: Any],
                  let key = nonempty(oauth["key"]) else { return }
            result.append(.init(storage: nonempty(oauth["storage"])?.lowercased() ?? "file", key: key))
        }
        if let providers = root["providers"] as? [String: Any] {
            for (name, value) in providers { inspect(value, name: name) }
        }
        if let services = root["services"] as? [String: Any] {
            for (name, value) in services { inspect(value, name: name) }
        }
        return result
    }

    private static func credentialFile(directory: URL, key: String) -> URL? {
        let raw = key.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        guard raw.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil else { return nil }
        let filename = raw.hasSuffix(".json") ? raw : raw + ".json"
        return directory.appendingPathComponent(filename, isDirectory: false)
    }

    private static func normalizeKimi(_ data: Data, provider: String, identity: String) -> Data? {
        guard let source = try? object(data) else { return nil }
        var root = source
        // A few clients wrap the OAuthToken object in a `token`/`oauth` table.
        for key in ["token", "oauth", "credentials", "auth"] {
            if let nested = root[key] as? [String: Any] {
                for (name, value) in nested where (value is String || value is NSNumber) && root[name] == nil {
                    root[name] = value
                }
            }
        }
        for (from, to) in [("accessToken", "access_token"), ("refreshToken", "refresh_token"),
                           ("idToken", "id_token"), ("expiresAt", "expires_at"),
                           ("expiresIn", "expires_in"), ("tokenType", "token_type")] {
            if root[to] == nil, let value = root[from] { root[to] = value }
        }
        root["type"] = provider
        root["local_identity"] = "kimi-code/" + identity
        guard let flattened = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else { return nil }
        return try? normalized(flattened, provider: provider)
    }

    private static func configObject(_ data: Data, toml: Bool) -> [String: Any]? {
        if !toml { return try? object(data) }
        return tomlObject(data)
    }

    private static func loadGeneric(provider: String, home: URL, environment: [String: String]) throws -> LocalSubscriptionCredential {
        let candidates: [URL]
        switch provider {
        case "kimi", "kimi-ai":
            let root = nonempty(environment["KIMI_HOME"]).map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent(".kimi-code", isDirectory: true)
            candidates = [root.appendingPathComponent("credentials.json"), root.appendingPathComponent("auth.json"),
                          root.appendingPathComponent("config.json"), root.appendingPathComponent("config.toml"),
                          home.appendingPathComponent(".config/kimi-code/credentials.json"),
                          home.appendingPathComponent(".config/kimi-code/auth.json"),
                          home.appendingPathComponent(".kimi/config.json")]
        case "xai":
            candidates = [home.appendingPathComponent(".grok/auth.json"), home.appendingPathComponent(".config/grok/auth.json"),
                          home.appendingPathComponent(".config/xai/auth.json"),
                          home.appendingPathComponent("Library/Application Support/Grok/auth.json")]
        case "cursor-agent-v1":
            candidates = [home.appendingPathComponent(".cursor/auth.json"), home.appendingPathComponent(".cursor-agent/auth.json"),
                          home.appendingPathComponent("Library/Application Support/Cursor/auth.json")]
        default:
            candidates = [home.appendingPathComponent(".zcode/auth.json"), home.appendingPathComponent(".config/zcode/auth.json"),
                          home.appendingPathComponent("Library/Application Support/ZCode/auth.json"),
                          home.appendingPathComponent("Library/Application Support/ZCode/accounts.json")]
        }
        for url in candidates {
            guard let data = try? readFile(url) else { continue }
            let converted = normalizeGeneric(data, provider: provider, toml: url.pathExtension.lowercased() == "toml")
            if let converted {
                return .init(provider: provider, source: url.path, data: converted)
            }
        }
        throw missing(provider)
    }

    private static func normalizeGeneric(_ data: Data, provider: String, toml: Bool) -> Data? {
        let source = toml ? (try? JSONSerialization.data(withJSONObject: tomlObject(data))) : data
        guard let source else { return nil }
        if let converted = try? normalized(source, provider: provider) { return converted }
        guard var root = try? object(source) else { return nil }
        // Kimi, Grok and small third-party clients commonly wrap the token in
        // `auth`, `credentials` or `account`. Merge only scalar fields from
        // those known containers; unrelated settings stay out of the import.
        for key in ["auth", "credentials", "account", "login", "session", "token_data"] {
            if let nested = root[key] as? [String: Any] {
                for (name, value) in nested where (value is String || value is NSNumber) && root[name] == nil { root[name] = value }
            }
        }
        for (from, to) in [("accessToken", "access_token"), ("refreshToken", "refresh_token"),
                           ("idToken", "id_token"), ("expiresAt", "expires_at"),
                           ("expiresIn", "expires_in"), ("tokenType", "token_type")] {
            if root[to] == nil, let value = root[from] { root[to] = value }
        }
        root["type"] = provider
        guard let flattened = try? JSONSerialization.data(withJSONObject: root) else { return nil }
        return try? normalized(flattened, provider: provider)
    }

    private static func tomlObject(_ data: Data) -> [String: Any] {
        let text = String(decoding: data, as: UTF8.self)
        var result: [String: Any] = [:]
        var table: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = tomlStripComment(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let header = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                table = tomlPath(header)
                _ = tomlDictionary(table, in: &result)
                continue
            }
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equal]).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let value = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty, let parsed = tomlValue(value) else { continue }
            var path = table
            path.append(contentsOf: tomlPath(key))
            tomlSet(parsed, at: path, in: &result)
        }
        return result
    }

    private static func tomlStripComment(_ line: String) -> String {
        var quoted: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            if character == "\\" && quoted == "\"" { escaped = true; continue }
            if character == "\"" || character == "'" {
                if quoted == character { quoted = nil } else if quoted == nil { quoted = character }
            } else if character == "#" && quoted == nil {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func tomlPath(_ text: String) -> [String] {
        text.split(separator: ".", omittingEmptySubsequences: true).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }.filter { !$0.isEmpty }
    }

    private static func tomlValue(_ raw: String) -> Any? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
            return String(value.dropFirst().dropLast())
        }
        if value == "true" { return true }
        if value == "false" { return false }
        if let number = Double(value) { return number }
        if value.hasPrefix("[") && value.hasSuffix("]") {
            return tomlSplit(value.dropFirst().dropLast().description).compactMap(tomlValue)
        }
        if value.hasPrefix("{") && value.hasSuffix("}") {
            var object: [String: Any] = [:]
            for item in tomlSplit(value.dropFirst().dropLast().description) {
                guard let equal = item.firstIndex(of: "=") else { continue }
                let key = String(item[..<equal]).trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                let rawValue = String(item[item.index(after: equal)...])
                if let parsed = tomlValue(rawValue) { object[key] = parsed }
            }
            return object
        }
        return value
    }

    private static func tomlSplit(_ text: String) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        var quote: Character?
        var depth = 0
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if escaped { escaped = false; continue }
            if character == "\\" && quote == "\"" { escaped = true; continue }
            if character == "\"" || character == "'" {
                if quote == character { quote = nil } else if quote == nil { quote = character }
            } else if quote == nil {
                if character == "[" || character == "{" { depth += 1 }
                if character == "]" || character == "}" { depth -= 1 }
                if character == "," && depth == 0 {
                    result.append(String(text[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
                    start = text.index(after: index)
                }
            }
        }
        let tail = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private static func tomlDictionary(_ path: [String], in root: inout [String: Any]) -> [String: Any] {
        guard let first = path.first else { return root }
        if path.count == 1 {
            if root[first] == nil { root[first] = [String: Any]() }
            return root[first] as? [String: Any] ?? [:]
        }
        var child = root[first] as? [String: Any] ?? [:]
        let remainder = Array(path.dropFirst())
        _ = tomlDictionary(remainder, in: &child)
        root[first] = child
        return child
    }

    private static func tomlSet(_ value: Any, at path: [String], in root: inout [String: Any]) {
        guard let first = path.first else { return }
        if path.count == 1 { root[first] = value; return }
        var child = root[first] as? [String: Any] ?? [:]
        tomlSet(value, at: Array(path.dropFirst()), in: &child)
        root[first] = child
    }

    private static func loadFile(_ url: URL, provider: String) throws -> LocalSubscriptionCredential {
        guard let data = try? readFile(url) else { throw missing(provider) }
        return .init(provider: provider, source: url.path, data: try normalized(data, provider: provider))
    }

    private static func addingClaudeIdentity(_ data: Data, home: URL, environment: [String: String]) throws -> Data {
        // Claude's token blob can be opaque. Its own config keeps the account
        // identity separately; copy only those two non-secret fields.
        let url: URL
        if let directory = nonempty(environment["CLAUDE_CONFIG_DIR"]) {
            url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(".claude.json")
        } else {
            url = home.appendingPathComponent(".claude.json")
        }
        guard let configData = try? readFile(url), let config = try? object(configData),
              let account = config["oauthAccount"] as? [String: Any] else { return data }
        var document = try object(data)
        if nonempty(document["account_id"]) == nil, let identity = nonempty(account["accountUuid"]) {
            document["account_id"] = identity
        }
        if nonempty(document["email"]) == nil, let email = nonempty(account["emailAddress"]) {
            document["email"] = email
        }
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    /// `claude-desktop` starts its embedded Code runtime with the current
    /// OAuth access token in the child environment. The token is intentionally
    /// never printed or persisted by this reader; it is normalized in memory
    /// and copied to Assropic's private account store by the caller.
    private static func claudeDesktopCredentials(_ data: Data) -> [LocalSubscriptionCredential]? {
        let text = String(decoding: data, as: UTF8.self)
        var result: [LocalSubscriptionCredential] = []
        var seen = Set<String>()
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine)
            guard line.contains("claude.app/Contents/MacOS/claude") else { continue }
            guard processEnvironmentValue("CLAUDE_CODE_ENTRYPOINT", in: line) == "claude-desktop" else { continue }
            guard let token = processEnvironmentValue("CLAUDE_CODE_OAUTH_TOKEN", in: line),
                  validProcessValue(token, maxLength: 16_384) else { continue }
            let account = processEnvironmentValue("CLAUDE_CODE_ACCOUNT_UUID", in: line)
            let email = processEnvironmentValue("CLAUDE_CODE_USER_EMAIL", in: line)
            let identity = account ?? email ?? token
            guard seen.insert(identity).inserted else { continue }
            var document: [String: Any] = ["type": "claude", "access_token": token,
                                           "local_identity": "claude-desktop/" + identity]
            if let account, validProcessValue(account, maxLength: 256) { document["account_id"] = account }
            if let email, validProcessValue(email, maxLength: 512) { document["email"] = email }
            if let subscription = processEnvironmentValue("CLAUDE_CODE_SUBSCRIPTION_TYPE", in: line),
               validProcessValue(subscription, maxLength: 128) { document["subscription_type"] = subscription }
            if let tier = processEnvironmentValue("CLAUDE_CODE_RATE_LIMIT_TIER", in: line),
               validProcessValue(tier, maxLength: 256) { document["rate_limit_tier"] = tier }
            if let scopes = processEnvironmentValue("CLAUDE_CODE_OAUTH_SCOPES", in: line),
               validProcessValue(scopes, maxLength: 512) {
                document["scopes"] = scopes.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            }
            guard let encoded = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
                  let normalized = try? normalized(encoded, provider: "claude") else { continue }
            result.append(.init(provider: "claude", source: "Claude Desktop · 运行中的 Code 会话", data: normalized))
        }
        return result.isEmpty ? nil : result
    }

    private static func processEnvironmentValue(_ key: String, in line: String) -> String? {
        for part in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0] == key else { continue }
            return String(pair[1])
        }
        return nil
    }

    private static func validProcessValue(_ value: String, maxLength: Int) -> Bool {
        value.utf8.count <= maxLength && !value.isEmpty
            && value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
    }

    /// Recent Claude Code releases use `CLAUDE_SECURESTORAGE_CONFIG_DIR` to
    /// select a per-profile Keychain item. Older releases tied the same suffix
    /// to `CLAUDE_CONFIG_DIR`; try both derived names and the default item so
    /// either client version can be imported without changing its files.
    static func claudeKeychainServices(environment: [String: String]) -> [String] {
        var result = ["Claude Code-credentials"]
        let configured = nonempty(environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"])
            ?? nonempty(environment["CLAUDE_CONFIG_DIR"])
        guard let configured else { return result }
        var paths = [configured]
        let expanded = NSString(string: configured).expandingTildeInPath
        if !paths.contains(expanded) { paths.append(expanded) }
        let standardized = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
        if !paths.contains(standardized) { paths.append(standardized) }
        let suffixes = paths.map { digestPrefix($0) }
        for suffix in suffixes {
            let service = "Claude Code-credentials-" + suffix
            if !result.contains(service) { result.insert(service, at: 0) }
        }
        return result
    }

    private static func digestPrefix(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func readClaudeDesktopProcesses() throws -> Data? {
        // First list command lines without environments, then inspect only
        // Claude's embedded Code processes. This avoids copying unrelated
        // secrets from every process on the machine into Assropic memory.
        guard let processList = try runProcessData(executable: "/bin/ps", arguments: ["-ax", "-o", "pid=,command="],
                                                   timeout: 5, maxBytes: 2_000_000) else { return nil }
        var environments = Data()
        let text = String(decoding: processList, as: UTF8.self)
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine)
            guard line.contains("claude.app/Contents/MacOS/claude"),
                  let pid = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
                  pid.range(of: "^[0-9]+$", options: .regularExpression) != nil else { continue }
            guard let environment = try runProcessData(executable: "/bin/ps", arguments: ["eww", "-p", String(pid), "-o", "command="],
                                                        timeout: 2, maxBytes: 512_000) else { continue }
            environments.append(environment)
            environments.append(10)
            if environments.count > 8_000_000 { break }
        }
        return environments.isEmpty ? nil : environments
    }

    private static func runProcessData(executable: String, arguments: [String], timeout: TimeInterval,
                                       maxBytes: Int) throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeoutWork = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        defer { timeoutWork.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty, data.count <= maxBytes else { return nil }
        return data
    }

    private static func readFile(_ url: URL) throws -> Data {
        // Validate the opened descriptor, not a separate path check, so a file
        // replacement cannot redirect the read to a symlink, device or pipe.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw LocalSubscriptionError.message("无法读取本机登录文件。")
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else {
            throw LocalSubscriptionError.message("本机登录凭据必须是不超过 2 MB 的普通文件。")
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while result.count <= limit {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, limit + 1 - result.count))
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw LocalSubscriptionError.message("无法读取本机登录文件。")
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        throw LocalSubscriptionError.message("本机登录文件过大，无法作为订阅凭据导入。")
    }

    private static func readClaudeKeychain(service: String) throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty, data.count <= limit else { return nil }
        return data
    }

    private static func readKimiKeychain(key: String) throws -> Data? {
        guard key.range(of: "^[A-Za-z0-9_./-]{1,128}$", options: .regularExpression) != nil else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "kimi-code", "-a", key, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty, data.count <= limit else { return nil }
        return data
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= limit,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !value.isEmpty else {
            throw LocalSubscriptionError.message("订阅凭据必须是不超过 2 MB 的 JSON 对象。")
        }
        return value
    }

    private static func canonicalProvider(_ provider: String) -> String {
        let provider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch provider {
        case "anthropic": return "claude"
        case "gpt", "chatgpt": return "codex"
        case "kimi-code", "kimi-code-cn": return "kimi"
        case "kimi-code-ai": return "kimi-ai"
        case "grok", "grok-build", "xai-cli": return "xai"
        case "cursor", "cursor-agent", "cursor-agent-v1": return "cursor-agent-v1"
        case "zcode-bigmodel", "zcode-zai", "zai": return "zcode"
        default: return provider.lowercased()
        }
    }

    private static func missing(_ provider: String) -> LocalSubscriptionError {
        let title = ["claude": "Claude Code", "codex": "Codex / ChatGPT", "kiro": "Kiro",
                     "kimi": "Kimi Code 国内", "kimi-ai": "Kimi Code 国际",
                     "xai": "Grok Build", "cursor-agent-v1": "Cursor", "zcode": "ZCode"][provider] ?? provider
        return .message("未找到 \(title) 的本机登录凭据，请先在对应客户端登录，或使用浏览器授权。")
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string
    }

    private static func copyStrings(_ source: [String: Any], into target: inout [String: Any], mapping: [String: String]) {
        for (from, to) in mapping { if let value = nonempty(source[from]) { target[to] = value } }
    }

    private static func millisecondsDate(_ value: Any?) -> String? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return secondsDate(number.doubleValue / 1000)
    }

    private static func secondsDate(_ value: Any?) -> String? {
        let interval: Double
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { interval = number.doubleValue }
        else if let number = value as? Double { interval = number }
        else { return nil }
        guard interval.isFinite, interval > 0, interval < 253_402_300_800 else { return nil }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: interval))
    }

    private static func jwtClaims(_ value: String?) -> [String: Any] {
        guard let value else { return [:] }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return [:] }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let claims = try? object(data) else { return [:] }
        return claims
    }
}
