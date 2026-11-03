import Foundation
import CoreFoundation
import Darwin

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
        else if root["accessToken"] is String, root["refreshToken"] is String { inferred = "kiro" }
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
        do {
            return try CredentialImport.normalized(JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]))
        } catch {
            throw LocalSubscriptionError.message("未找到可用的订阅登录令牌，请先在对应客户端登录，或使用浏览器授权。")
        }
    }

    /// `keychainReader` is injectable for tests; its result stays in memory.
    /// The caller decides whether and how to import the returned credential.
    static func load(provider: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     keychainReader: (() throws -> Data?)? = nil) throws -> LocalSubscriptionCredential {
        let provider = canonicalProvider(provider)
        switch provider {
        case "claude":
            let reader = keychainReader ?? readClaudeKeychain
            if let result = try? reader(),
               let data = try? normalized(result, provider: provider) {
                return .init(provider: provider, source: "Claude Code · macOS 钥匙串",
                             data: try addingClaudeIdentity(data, home: home, environment: environment))
            }
            let configured = nonempty(environment["CLAUDE_CONFIG_DIR"])
            let directory = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent(".claude", isDirectory: true)
            let credential = try loadFile(directory.appendingPathComponent(".credentials.json"), provider: provider)
            return .init(provider: provider, source: credential.source,
                         data: try addingClaudeIdentity(credential.data, home: home, environment: environment))
        case "codex":
            let configured = nonempty(environment["CODEX_HOME"])
            let directory = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent(".codex", isDirectory: true)
            return try loadFile(directory.appendingPathComponent("auth.json"), provider: provider)
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
            return .init(provider: provider, source: url.path, data: data)
        default:
            throw LocalSubscriptionError.message("此服务暂不支持读取本机订阅登录。")
        }
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

    private static func readClaudeKeychain() throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
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
        default: return provider.lowercased()
        }
    }

    private static func missing(_ provider: String) -> LocalSubscriptionError {
        let title = ["claude": "Claude Code", "codex": "Codex / ChatGPT", "kiro": "Kiro"][provider] ?? provider
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
