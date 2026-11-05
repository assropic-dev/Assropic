import Foundation
import CryptoKit

/// BridgeDock's `accounts/` files stay the source of truth for Kiro logins, which
/// the core plugin still creates and lists. kiro2cc-proxy serves the inference
/// because it relays upstream events as they arrive; the plugin buffers whole replies.
enum KiroRuntimeCredentials {
    /// Builds kiro2cc's credentials.json from BridgeDock account documents.
    /// `ids` keeps each account's kiro2cc id stable across restarts; new names get
    /// the next unused id, so usage history never moves to a different account.
    static func document(accounts: [(name: String, value: [String: Any])], ids: inout [String: UInt64]) -> [[String: Any]] {
        var next = (ids.values.max() ?? 0) + 1
        return accounts.sorted { $0.name < $1.name }.compactMap { account in
            let value = account.value
            guard (value["type"] as? String)?.lowercased() == "kiro",
                  let refresh = string(value["refreshToken"]) ?? string(value["refresh_token"]) else { return nil }
            let id: UInt64
            if let known = ids[account.name] { id = known } else { id = next; ids[account.name] = next; next += 1 }
            var entry: [String: Any] = ["id": id, "refreshToken": refresh, "authMethod": authMethod(value),
                                        "disabled": value["disabled"] as? Bool ?? false,
                                        // Opus is only routed to accounts with a known paid plan. The
                                        // real title replaces this once kiro2cc reads the usage limits.
                                        "subscriptionTitle": string(value["subscriptionTitle"]) ?? "KIRO PRO",
                                        "thinkingAdaptive": true]
            if let token = string(value["accessToken"]) ?? string(value["access_token"]) { entry["accessToken"] = token }
            if let expiry = string(value["expiresAt"]) ?? string(value["expired"]) { entry["expiresAt"] = expiry }
            for (source, target) in [("profileArn", "profileArn"), ("clientId", "clientId"), ("clientSecret", "clientSecret"),
                                     ("email", "email"), ("note", "nickname")] {
                if let text = string(value[source]) { entry[target] = text }
            }
            if let region = string(value["region"]) { entry["region"] = region; entry["apiRegion"] = region }
            if let region = string(value["idcRegion"]) { entry["authRegion"] = region }
            if let priority = (value["priority"] as? NSNumber)?.intValue, priority >= 0 { entry["priority"] = priority }
            if let proxy = string(value["proxy_url"]) { entry["proxyUrl"] = proxy }
            // A stable per-account machine id, matching the quota request's identity.
            let identity = string(value["profileArn"]) ?? string(value["clientId"]) ?? refresh
            entry["machineId"] = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            return entry
        }
    }

    /// kiro2cc rotates tokens on its own schedule. Copies newer tokens back into the
    /// matching account document; returns nil when nothing changed.
    static func merged(account: [String: Any], runtime: [String: Any]) -> [String: Any]? {
        guard let refresh = string(runtime["refreshToken"]), let access = string(runtime["accessToken"]) else { return nil }
        let currentExpiry = date(string(account["expiresAt"]) ?? string(account["expired"]))
        let runtimeExpiry = date(string(runtime["expiresAt"]))
        guard let runtimeExpiry, runtimeExpiry > (currentExpiry ?? .distantPast) else { return nil }
        var value = account
        value["accessToken"] = access; value["access_token"] = access
        value["refreshToken"] = refresh; value["refresh_token"] = refresh
        value["expiresAt"] = string(runtime["expiresAt"])
        if value["expired"] != nil { value["expired"] = string(runtime["expiresAt"]) }
        if string(value["profileArn"]) == nil, let arn = string(runtime["profileArn"]) { value["profileArn"] = arn }
        return value
    }

    static func authMethod(_ value: [String: Any]) -> String {
        let method = (string(value["authMethod"]) ?? "").lowercased()
        if ["idc", "builder-id", "builderid", "iam"].contains(method) { return "idc" }
        if method == "social" { return "social" }
        return string(value["clientId"]) != nil && string(value["clientSecret"]) != nil ? "idc" : "social"
    }

    /// One client key per routing prefix, bound to that prefix's accounts, keeps
    /// `kiro/…` and `kiro-2/…` on separate accounts exactly as the core routes them.
    static func keyGroups(accounts: [(name: String, value: [String: Any])], ids: [String: UInt64]) -> [String: [UInt64]] {
        var groups: [String: [UInt64]] = [:]
        for account in accounts where !(account.value["disabled"] as? Bool ?? false) {
            guard let id = ids[account.name] else { continue }
            groups[string(account.value["prefix"]) ?? "", default: []].append(id)
        }
        return groups.mapValues { $0.sorted() }
    }

    /// Key group name for the shared pool, matching the gateway's lookup.
    static let poolGroup = KiroGatewayRoute.poolKey

    /// With two or more enabled accounts, one extra key is bound to all of them. kiro2cc's
    /// balanced mode then hands new conversations to the accounts in turn, and its
    /// continuation-id stickiness keeps an ongoing conversation on the account it started on.
    /// Every account keeps its own credential entry and token refresh, so none signs another out.
    static func poolMembers(accounts: [(name: String, value: [String: Any])], ids: [String: UInt64]) -> [UInt64]? {
        let members = accounts.compactMap { account -> UInt64? in
            guard !(account.value["disabled"] as? Bool ?? false), account.value["pool"] as? Bool != false else { return nil }
            return ids[account.name]
        }.sorted()
        return members.count >= 2 ? members : nil
    }

    /// A prefix uses the pool only when every one of its accounts is in it; a prefix holding an
    /// opted-out account keeps its own key so that account stays reachable on its own.
    static func pooledPrefixes(groups: [String: [UInt64]], pool: [UInt64]) -> Set<String> {
        let members = Set(pool)
        return Set(groups.filter { $0.key != poolGroup && !$0.value.isEmpty && Set($0.value).isSubset(of: members) }.keys)
    }

    static func string(_ any: Any?) -> String? {
        guard let text = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    // ISO8601DateFormatter is thread-safe and costly to build, so parsing reuses two instances.
    private static let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return fractionalDates.date(from: text) ?? plainDates.date(from: text)
    }

    static func timestamp(_ date: Date = Date()) -> String { plainDates.string(from: date) }

    /// Body for kiro2cc's `POST /api/admin/credentials`, built from a `document` entry.
    static func addRequest(_ entry: [String: Any]) -> [String: Any] {
        var body: [String: Any] = [:]
        for key in ["refreshToken", "authMethod", "clientId", "clientSecret", "profileArn", "region", "authRegion",
                    "apiRegion", "machineId", "email", "nickname", "proxyUrl"] {
            if let text = string(entry[key]) { body[key] = text }
        }
        body["priority"] = (entry["priority"] as? NSNumber)?.intValue ?? 0
        body["disabled"] = entry["disabled"] as? Bool ?? false
        return body
    }

    /// Body for `PUT /api/admin/credentials/:id`. kiro2cc treats "" as "clear" for the
    /// fields sent that way, so a removed profile ARN or per-account proxy is cleared too.
    static func updateRequest(_ entry: [String: Any]) -> [String: Any] {
        var body: [String: Any] = [:]
        for key in ["refreshToken", "authMethod", "clientId", "clientSecret", "authRegion", "apiRegion", "machineId", "email", "nickname"] {
            if let text = string(entry[key]) { body[key] = text }
        }
        for key in ["profileArn", "proxyUrl"] { body[key] = string(entry[key]) ?? "" }
        return body
    }
}

/// The difference between the accounts kiro2cc is serving and the accounts on disk,
/// so that adding, removing or editing one account never restarts the process (and
/// never cuts the streams other accounts are serving).
struct KiroRuntimeChange: Equatable {
    var added: [String] = []
    var removed: [String] = []
    /// A new login or another identity field changed; sent as an in-place credential update.
    var updated: [String] = []
    var disabled: [String: Bool] = [:]
    var priority: [String: Int] = [:]
    /// Some change cannot be expressed through the admin API (a field kiro2cc cannot clear).
    var needsRestart = false

    var isEmpty: Bool { added.isEmpty && removed.isEmpty && updated.isEmpty && disabled.isEmpty && priority.isEmpty && !needsRestart }

    /// Identity fields; changing one means the credential itself is different.
    static let identityFields = ["refreshToken", "authMethod", "clientId", "clientSecret", "profileArn", "authRegion",
                                 "apiRegion", "proxyUrl", "email", "nickname"]
    /// Fields an update cannot clear once set.
    static let unclearableFields = ["clientId", "clientSecret", "authRegion", "apiRegion"]

    /// `old` and `new` map account names to their `KiroRuntimeCredentials.document` entries.
    static func between(old: [String: [String: Any]], new: [String: [String: Any]]) -> KiroRuntimeChange {
        var change = KiroRuntimeChange()
        change.added = new.keys.filter { old[$0] == nil }.sorted()
        change.removed = old.keys.filter { new[$0] == nil }.sorted()
        for name in new.keys.sorted() {
            guard let before = old[name], let after = new[name] else { continue }
            let text = { (entry: [String: Any], key: String) in KiroRuntimeCredentials.string(entry[key]) }
            if identityFields.contains(where: { text(before, $0) != text(after, $0) }) {
                change.updated.append(name)
                if unclearableFields.contains(where: { text(before, $0) != nil && text(after, $0) == nil }) { change.needsRestart = true }
            }
            let wasDisabled = before["disabled"] as? Bool ?? false, isDisabled = after["disabled"] as? Bool ?? false
            if wasDisabled != isDisabled { change.disabled[name] = isDisabled }
            let oldPriority = (before["priority"] as? NSNumber)?.intValue ?? 0, newPriority = (after["priority"] as? NSNumber)?.intValue ?? 0
            if oldPriority != newPriority { change.priority[name] = newPriority }
        }
        return change
    }

    /// Client keys to create, rebind and delete so `current` becomes `desired` (group name to bound ids).
    static func keys(current: [String: [UInt64]], desired: [String: [UInt64]]) -> (create: [String], rebind: [String], delete: [String]) {
        (desired.keys.filter { current[$0] == nil }.sorted(),
         desired.keys.filter { current[$0] != nil && current[$0] != desired[$0] }.sorted(),
         current.keys.filter { desired[$0] == nil }.sorted())
    }
}

/// Restart pacing after kiro2cc exits on its own: 1, 2, 4 … seconds, capped at one minute.
enum KiroRuntimeRestart {
    static func delay(attempt: Int) -> UInt64 { UInt64(min(60, 1 << min(max(attempt, 0), 6))) }
    /// A process that stayed up this long is treated as healthy, so the next crash starts over at 1 second.
    static let stableUptime: TimeInterval = 300
}

/// Runs kiro2cc-proxy on a private loopback port next to the core.
@MainActor
final class KiroRuntime {
    typealias Accounts = [(name: String, value: [String: Any])]
    static let port = 18421
    /// kiro2cc caches usage limits; re-reading them keeps the plan title and quota current.
    static let balanceInterval: UInt64 = 30 * 60
    let directory: URL
    let accountsDirectory: URL
    let executable: URL
    /// Routing prefix ("" for unprefixed accounts) to kiro2cc client key.
    private(set) var keys: [String: String] = [:]
    /// Prefixes whose accounts all belong to the shared pool; the gateway sends them to the pool key.
    private(set) var pooledPrefixes: Set<String> = []
    private(set) var ready = false
    private var process: Process?
    private var output: FileHandle?
    private var fingerprint = ""
    private var syncTask: Task<Void, Never>?
    private let session: URLSession
    /// Account files are read and written here, off the main thread, one job at a time.
    private let fileQueue = DispatchQueue(label: "local.bridgedock.kiro-runtime.files", qos: .utility)
    /// What the running process holds, so later changes can be applied through its admin API.
    private var admin = ""
    private var appliedProxyURL = ""
    private var applied: [String: [String: Any]] = [:]
    private var keyGroups: [String: [UInt64]] = [:]
    private var keyIDs: [String: Int] = [:]
    /// Set while BridgeDock wants the runtime up; a crash is only restarted then.
    private var desiredProxyURL: String?
    private var restartTask: Task<Void, Never>?
    private var restartAttempts = 0
    private var launchedAt = Date.distantPast
    private var synchronizing = false
    private var resyncRequested = false
    var onReadyChange: ((Bool) -> Void)?

    init(dataDirectory: URL) {
        directory = dataDirectory.appendingPathComponent("kiro-runtime")
        accountsDirectory = dataDirectory.appendingPathComponent("accounts")
        executable = Bundle.main.resourceURL!.appendingPathComponent("kiro2cc-proxy")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        session = URLSession(configuration: configuration)
    }

    var baseURL: String { "http://127.0.0.1:\(Self.port)" }

    /// Brings kiro2cc in line with the Kiro account files. Account changes are applied to the
    /// running process; only a new upstream proxy, or a change the admin API cannot express,
    /// restarts it.
    func synchronize(proxyURL: String) async {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        desiredProxyURL = proxyURL
        // Refreshes, crash restarts and account edits can overlap at await points; run one at a
        // time and fold the overlapping calls into a single rerun against the latest settings.
        guard !synchronizing else { resyncRequested = true; return }
        synchronizing = true
        defer { synchronizing = false }
        repeat {
            resyncRequested = false
            await synchronizeOnce(proxyURL: desiredProxyURL ?? proxyURL)
        } while resyncRequested && desiredProxyURL != nil
    }

    private func synchronizeOnce(proxyURL: String) async {
        await pullRotatedTokens()
        let accounts = await kiroAccounts()
        let nextFingerprint = Self.fingerprint(accounts, proxyURL: proxyURL)
        if nextFingerprint == fingerprint, process?.isRunning == true { return }
        guard accounts.contains(where: { !($0.value["disabled"] as? Bool ?? false) }) else {
            teardown(); fingerprint = nextFingerprint; return
        }
        if ready, process?.isRunning == true, proxyURL == appliedProxyURL {
            do {
                try await applyLive(accounts)
                fingerprint = nextFingerprint
                return
            } catch {
                // Fall through to a full restart, which rebuilds every file from the accounts.
            }
        }
        teardown()
        fingerprint = nextFingerprint
        do {
            try await launch(accounts: accounts, proxyURL: proxyURL)
        } catch {
            teardown()
            scheduleRestart()
        }
    }

    /// Stops kiro2cc for good (core stopped or app quitting); no automatic restart follows.
    func stop() {
        desiredProxyURL = nil
        restartTask?.cancel(); restartTask = nil
        restartAttempts = 0
        teardown()
    }

    private func teardown() {
        syncTask?.cancel(); syncTask = nil
        if ready { ready = false; onReadyChange?(false) }
        if let process, process.isRunning {
            // kiro2cc has no graceful shutdown; persist tokens it already rotated first.
            let directory = directory, accountsDirectory = accountsDirectory
            fileQueue.sync { Self.pull(directory: directory, accountsDirectory: accountsDirectory) }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().async { Self.awaitExit(pid) }
        }
        process = nil
        try? output?.close(); output = nil
        fingerprint = ""
        keys = [:]
        pooledPrefixes = []
        admin = ""; applied = [:]; keyGroups = [:]; keyIDs = [:]
    }

    /// Restarts kiro2cc after it exited or failed to start, backing off while it keeps failing.
    private func scheduleRestart() {
        guard let proxyURL = desiredProxyURL, restartTask == nil else { return }
        if Date().timeIntervalSince(launchedAt) > KiroRuntimeRestart.stableUptime { restartAttempts = 0 }
        let delay = KiroRuntimeRestart.delay(attempt: restartAttempts)
        restartAttempts += 1
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.restartTask = nil
            guard self.desiredProxyURL != nil, self.process?.isRunning != true else { return }
            await self.synchronize(proxyURL: self.desiredProxyURL ?? proxyURL)
        }
    }

    private func launch(accounts: Accounts, proxyURL: String) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        stopOrphan()
        var ids = loadIDs()
        let credentials = KiroRuntimeCredentials.document(accounts: accounts, ids: &ids)
        try privateWrite(jsonData(ids), to: directory.appendingPathComponent("bridgedock-ids.json"))
        try privateWrite(jsonData(credentials), to: directory.appendingPathComponent("credentials.json"))
        let admin = UUID().uuidString + UUID().uuidString
        var config: [String: Any] = ["host": "127.0.0.1", "port": Self.port, "region": "us-east-1", "adminPsw": admin,
                                     "loadBalancingMode": "balanced", "clientTokenPassthrough": true,
                                     "thinkingAsText": false, "showSessionCredits": false]
        if !proxyURL.isEmpty && proxyURL != "direct" { config["proxyUrl"] = proxyURL }
        try privateWrite(jsonData(config), to: directory.appendingPathComponent("config.json"))
        let created = KiroRuntimeCredentials.timestamp()
        var nextKeys: [String: String] = [:]
        var nextKeyIDs: [String: Int] = [:]
        var keyEntries: [[String: Any]] = []
        let groups = Self.desiredGroups(accounts: accounts, ids: ids)
        for (index, group) in groups.sorted(by: { $0.key < $1.key }).enumerated() {
            let value = "sk-bd-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            nextKeys[group.key] = value
            nextKeyIDs[group.key] = index + 1
            keyEntries.append(["id": index + 1, "key": value, "name": Self.keyName(group.key),
                               "enabled": true, "createdAt": created, "boundCredentialIds": group.value])
        }
        try privateWrite(jsonData(keyEntries), to: directory.appendingPathComponent("api_keys.json"))
        let log = directory.appendingPathComponent("kiro2cc.log")
        try privateWrite(Data(), to: log)
        output = try FileHandle(forWritingTo: log)
        let child = Process()
        child.executableURL = executable
        child.arguments = ["-c", directory.appendingPathComponent("config.json").path,
                           "--credentials", directory.appendingPathComponent("credentials.json").path]
        child.currentDirectoryURL = directory
        // HOME points inside the runtime folder so kiro2cc never reads the user's ~/.aws cache.
        // At info level kiro2cc logs request metadata (ids, hashes, token counts), not tokens or prompts.
        child.environment = ["HOME": directory.path, "PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory(), "RUST_LOG": "info"]
        child.standardOutput = output; child.standardError = output
        child.terminationHandler = { [weak self] exited in
            Task { @MainActor in
                // Only an exit nobody asked for lands here: teardown() clears `process` first.
                guard let self, self.process === exited else { return }
                self.process = nil; self.fingerprint = ""
                self.syncTask?.cancel(); self.syncTask = nil
                if self.ready { self.ready = false; self.onReadyChange?(false) }
                self.scheduleRestart()
            }
        }
        try child.run()
        process = child
        launchedAt = Date()
        try privateWrite(jsonData(["pid": child.processIdentifier, "executable": executable.path]),
                         to: directory.appendingPathComponent("process.json"))
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 150_000_000)
            guard child.isRunning, process === child else { throw BridgeError.message("Kiro 运行时未能启动。") }
            if await healthy() {
                self.admin = admin
                appliedProxyURL = proxyURL
                applied = Self.entries(credentials, ids: ids)
                keyGroups = groups; keyIDs = nextKeyIDs
                keys = nextKeys
                pooledPrefixes = Self.pooled(groups)
                ready = true; onReadyChange?(true)
                startMaintenance()
                return
            }
        }
        throw BridgeError.message("Kiro 运行时未就绪。")
    }

    /// Token write-back every minute and a usage-limit refresh every `balanceInterval`;
    /// the first refresh runs right away so Opus routing sees each account's real plan.
    private func startMaintenance() {
        syncTask = Task { [weak self] in
            var elapsed: UInt64 = 0
            await self?.refreshBalances()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.pullRotatedTokens()
                elapsed += 60
                if elapsed >= Self.balanceInterval { elapsed = 0; await self.refreshBalances() }
            }
        }
    }

    /// Reads every enabled account's usage limits at once; one slow account no longer delays the rest.
    func refreshBalances() async {
        let admin = admin
        let ids = applied.values.filter { !($0["disabled"] as? Bool ?? false) }.compactMap { ($0["id"] as? NSNumber)?.uint64Value }
        guard !admin.isEmpty, !ids.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { [weak self] in _ = try? await self?.adminRequest("GET", "/api/admin/credentials/\(id)/balance", admin: admin) }
            }
        }
    }

    /// Applies account changes through kiro2cc's admin API. New credentials and keys exist before the
    /// gateway is pointed at them, and old ones are deleted only afterwards, so no request is left
    /// holding a key that just vanished. Throws on anything unexpected; the caller then restarts.
    private func applyLive(_ accounts: Accounts) async throws {
        var ids = loadIDs()
        let next = KiroRuntimeCredentials.document(accounts: accounts, ids: &ids)
        // `document` hands new accounts provisional ids; kiro2cc assigns the real ones below.
        let provisional = Self.entries(next, ids: ids)
        // A refresh token kiro2cc rotated itself and BridgeDock copied back is not a new login.
        let current = Self.withRuntimeTokens(applied, runtime: runtimeCredentials())
        let change = KiroRuntimeChange.between(old: current, new: provisional)
        guard !change.needsRestart else { throw BridgeError.message("需要重启 Kiro 运行时。") }
        let admin = admin
        var live = current
        for name in change.added {
            guard var entry = provisional[name] else { continue }
            let response = try await adminRequest("POST", "/api/admin/credentials", body: KiroRuntimeCredentials.addRequest(entry), admin: admin)
            guard let id = (response["credentialId"] as? NSNumber)?.uint64Value else { throw BridgeError.message("kiro2cc 未返回账号 id。") }
            ids[name] = id; entry["id"] = id; live[name] = entry
        }
        for name in change.updated {
            guard let id = Self.id(live[name]), let entry = provisional[name] else { continue }
            _ = try await adminRequest("PUT", "/api/admin/credentials/\(id)", body: KiroRuntimeCredentials.updateRequest(entry), admin: admin)
            live[name] = entry.merging(["id": id]) { $1 }
        }
        for (name, disabled) in change.disabled.sorted(by: { $0.key < $1.key }) {
            guard let id = Self.id(live[name]) else { continue }
            _ = try await adminRequest("POST", "/api/admin/credentials/\(id)/disabled", body: ["disabled": disabled], admin: admin)
            live[name]?["disabled"] = disabled
        }
        for (name, priority) in change.priority.sorted(by: { $0.key < $1.key }) {
            guard let id = Self.id(live[name]) else { continue }
            _ = try await adminRequest("POST", "/api/admin/credentials/\(id)/priority", body: ["priority": priority], admin: admin)
            live[name]?["priority"] = priority
        }
        try privateWrite(jsonData(ids), to: directory.appendingPathComponent("bridgedock-ids.json"))
        applied = live.filter { change.removed.contains($0.key) == false }

        let desired = Self.desiredGroups(accounts: accounts, ids: ids)
        let plan = KiroRuntimeChange.keys(current: keyGroups, desired: desired)
        var nextKeys = keys, nextKeyIDs = keyIDs
        for group in plan.create {
            let response = try await adminRequest("POST", "/api/admin/api-keys",
                                                   body: ["name": Self.keyName(group), "boundCredentialIds": desired[group] ?? []], admin: admin)
            guard let id = (response["id"] as? NSNumber)?.intValue, let key = response["key"] as? String else {
                throw BridgeError.message("kiro2cc 未返回客户端 Key。")
            }
            nextKeys[group] = key; nextKeyIDs[group] = id
        }
        for group in plan.rebind {
            guard let id = keyIDs[group] else { continue }
            _ = try await adminRequest("PUT", "/api/admin/api-keys/\(id)", body: ["boundCredentialIds": desired[group] ?? []], admin: admin)
        }
        for group in plan.delete { nextKeys[group] = nil }
        keys = nextKeys
        pooledPrefixes = Self.pooled(desired)
        keyGroups = desired
        onReadyChange?(true)

        // Retire what no longer exists, now that nothing routes to it.
        for group in plan.delete {
            if let id = nextKeyIDs.removeValue(forKey: group) { _ = try? await adminRequest("DELETE", "/api/admin/api-keys/\(id)", admin: admin) }
        }
        keyIDs = nextKeyIDs
        for name in change.removed {
            if let id = ids[name] { _ = try? await adminRequest("DELETE", "/api/admin/credentials/\(id)", admin: admin) }
        }
        if !change.added.isEmpty || !change.updated.isEmpty { await refreshBalances() }
    }

    /// kiro2cc's own credentials.json, keyed by id.
    private func runtimeCredentials() -> [UInt64: [String: Any]] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("credentials.json")),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var result: [UInt64: [String: Any]] = [:]
        for entry in entries { if let id = Self.id(entry) { result[id] = entry } }
        return result
    }

    static func withRuntimeTokens(_ entries: [String: [String: Any]], runtime: [UInt64: [String: Any]]) -> [String: [String: Any]] {
        entries.mapValues { entry in
            guard let id = id(entry), let token = KiroRuntimeCredentials.string(runtime[id]?["refreshToken"]) else { return entry }
            return entry.merging(["refreshToken": token]) { $1 }
        }
    }

    private static func desiredGroups(accounts: Accounts, ids: [String: UInt64]) -> [String: [UInt64]] {
        var groups = KiroRuntimeCredentials.keyGroups(accounts: accounts, ids: ids)
        if let pool = KiroRuntimeCredentials.poolMembers(accounts: accounts, ids: ids) {
            groups[KiroRuntimeCredentials.poolGroup] = pool
        }
        return groups
    }

    private static func pooled(_ groups: [String: [UInt64]]) -> Set<String> {
        guard let pool = groups[KiroRuntimeCredentials.poolGroup] else { return [] }
        return KiroRuntimeCredentials.pooledPrefixes(groups: groups, pool: pool)
    }

    private static func keyName(_ group: String) -> String {
        "BridgeDock " + (group == KiroRuntimeCredentials.poolGroup ? "pool" : (group.isEmpty ? "default" : group))
    }

    /// Account name to `document` entry.
    private static func entries(_ document: [[String: Any]], ids: [String: UInt64]) -> [String: [String: Any]] {
        let names = Dictionary(ids.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        var result: [String: [String: Any]] = [:]
        for entry in document { if let id = Self.id(entry), let name = names[id] { result[name] = entry } }
        return result
    }

    private static func id(_ entry: [String: Any]?) -> UInt64? { (entry?["id"] as? NSNumber)?.uint64Value }

    private func healthy() async -> Bool {
        guard let url = URL(string: baseURL + "/v1/ping"),
              let (_, response) = try? await session.data(from: url) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    @discardableResult
    private func adminRequest(_ method: String, _ path: String, body: [String: Any]? = nil, admin: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = method
        request.setValue(admin, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 20
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw BridgeError.message("kiro2cc 管理接口 \(method) \(path) 失败。")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Copies tokens kiro2cc rotated back into BridgeDock's account files, off the main thread.
    func pullRotatedTokens() async {
        let directory = directory, accountsDirectory = accountsDirectory
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            fileQueue.async { Self.pull(directory: directory, accountsDirectory: accountsDirectory); done.resume() }
        }
    }

    nonisolated static func pull(directory: URL, accountsDirectory: URL) {
        let url = directory.appendingPathComponent("credentials.json")
        // kiro2cc rewrites this file with 0644; it holds refresh tokens, so keep it owner-only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let names = Dictionary(loadIDs(directory).map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        for entry in entries {
            guard let id = (entry["id"] as? NSNumber)?.uint64Value, let name = names[id] else { continue }
            let file = accountsDirectory.appendingPathComponent(name)
            guard let original = try? Data(contentsOf: file),
                  let current = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
                  let next = KiroRuntimeCredentials.merged(account: current, runtime: entry),
                  let encoded = try? jsonData(next) else { continue }
            // The UI may have replaced this file (a new login) meanwhile; never write over that.
            guard (try? Data(contentsOf: file)) == original else { continue }
            try? privateWrite(encoded, to: file)
        }
    }

    private func kiroAccounts() async -> Accounts {
        let accountsDirectory = accountsDirectory
        let found: [(String, Data)] = await withCheckedContinuation { done in
            fileQueue.async {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: accountsDirectory.path)) ?? []
                done.resume(returning: names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
                    (try? Data(contentsOf: accountsDirectory.appendingPathComponent(name))).map { (name, $0) }
                })
            }
        }
        return found.compactMap { name, data in
            guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (value["type"] as? String)?.lowercased() == "kiro" else { return nil }
            return (name, value)
        }
    }

    /// Changes whenever anything kiro2cc serves changes; token rotation alone does not count.
    static func fingerprint(_ accounts: Accounts, proxyURL: String) -> String {
        let parts = accounts.sorted { $0.name < $1.name }.map { account -> String in
            let v = account.value
            // Kiro keeps the refresh token across access-token renewals, so a change means a new login.
            let refresh = KiroRuntimeCredentials.string(v["refreshToken"]) ?? KiroRuntimeCredentials.string(v["refresh_token"]) ?? ""
            let fields: [Any?] = [account.name, v["disabled"], v["priority"], v["prefix"], v["pool"], v["proxy_url"], v["region"], v["idcRegion"],
                                  v["profileArn"], v["clientId"], v["email"], v["note"], SHA256.hash(data: Data(refresh.utf8)).description]
            return fields.map { "\($0 ?? "")" }.joined(separator: "|")
        }
        let text = (parts + [proxyURL]).joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func loadIDs() -> [String: UInt64] { Self.loadIDs(directory) }

    nonisolated static func loadIDs(_ directory: URL) -> [String: UInt64] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("bridgedock-ids.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.compactMapValues { ($0 as? NSNumber)?.uint64Value }
    }

    private func stopOrphan() {
        let url = directory.appendingPathComponent("process.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int32, pid > 1, object["executable"] as? String == executable.path else { return }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/ps")
        check.arguments = ["-p", String(pid), "-o", "comm="]
        let pipe = Pipe()
        check.standardOutput = pipe; check.standardError = FileHandle.nullDevice
        guard (try? check.run()) != nil else { return }
        let actual = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        check.waitUntilExit()
        guard actual == executable.path else { return }
        kill(pid, SIGTERM)
        Self.awaitExit(pid)
    }

    /// Waits up to 2 seconds for `pid` to exit, then SIGKILLs it.
    nonisolated static func awaitExit(_ pid: pid_t) {
        let deadline = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}
