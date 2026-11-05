import Foundation
import AppKit
import Combine

@MainActor
final class BridgeStore: ObservableObject {
    @Published var settings = AppSettings()
    @Published var running = false
    @Published var busy = false
    @Published var status = "准备启动"
    @Published var error: String?
    @Published var models: [ModelItem] = []
    @Published var availableModels: [PublishedModel] = []
    private var rawModels: [ModelItem] = []
    private var modelDefinitions: [String: [String: ModelCapability]] = [:]
    private var modelDefinitionKey = ""
    private var modelDefinitionsLoadedAt = Date.distantPast
    private var cursorModelCatalogs: [String: CursorModelCatalog] = [:]
    private var cursorCatalogAttempts: [String: Date] = [:]
    var modelOwners: [String] { Array(Set(rawModels.map(\.owner))) }
    var capabilityBackfillAttempted: Set<String> = []
    private let modelGateway = ModelGateway()
    @Published var accounts: [Account] = []
    @Published var activities: [Activity] = []
    @Published var login: LoginSession?
    @Published var loginStatus = ""
    @Published private(set) var callbackSubmission: UUID?
    @Published var localSubscriptionStatus: [String: String] = [:]
    @Published var accountOperation: String?
    @Published var kimiWorkStatus = "在 BridgeDock 中网页登录，无需安装或运行 Kimi 客户端。"
    var workAppliedFingerprint = ""
    var workSyncing = false
    var workRefreshAttempts: [String: Date] = [:]
    @Published var testResult = ""
    @Published var testing = false
    @Published var testReport: ModelTestReport?
    private var modelTestTask: Task<Void, Never>?
    @Published var pendingImport: ChannelImport?
    @Published var importLinkStatus = ""
    @Published var importNotice = ""
    var openMainWindow: (() -> Void)?
    @Published var quotaStates: [String: QuotaState] = [:]
    @Published var quotaRefreshing = false
    @Published var launchingAgent = false
    var quotaGeneration = 0
    @Published var cursorIdentity = CursorLocalIdentity()
    @Published var cursorBusy = false
    @Published var cursorPendingEnabled: Bool?
    @Published var cursorInstalled = false
    @Published var cursorStatus = "已关闭 · Cursor 使用原来的官方账号"
    @Published var cursorSessionReady = false
    let cursorSession = CursorSessionServer()
    @Published var kiroStreaming = false
    private(set) lazy var kiroRuntime: KiroRuntime = {
        let runtime = KiroRuntime(dataDirectory: dataDirectory)
        runtime.onReadyChange = { [weak self, unowned runtime] ready in
            guard let self else { return }
            self.kiroStreaming = ready
            self.modelGateway.updateKiro(ready ? KiroGatewayRoute(port: KiroRuntime.port, keys: runtime.keys, pooledPrefixes: runtime.pooledPrefixes) : nil)
        }
        return runtime
    }()
    let dataDirectory: URL
    private let stateURL: URL
    private let configURL: URL
    private let pluginDirectory: URL
    private var core: Process?
    private var outputHandle: FileHandle?
    private var loginTask: Task<Void, Never>?
    private var loginStarting = false
    private var refreshTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    private var validState = true
    private var shuttingDown = false
    private let session: URLSession
    var baseURL: String { "http://127.0.0.1:\(settings.port)" }
    var apiURL: String { baseURL + "/v1" }
    private var coreBaseURL: String { "http://127.0.0.1:\(settings.corePort)" }
    var coreURL: URL { Bundle.main.resourceURL!.appendingPathComponent("cli-proxy-api") }

    init() {
        dataDirectory = AppInstanceLock.dataDirectory
        stateURL = dataDirectory.appendingPathComponent("state.json")
        configURL = dataDirectory.appendingPathComponent("config.yaml")
        pluginDirectory = dataDirectory.appendingPathComponent("plugins")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 65
        session = URLSession(configuration: configuration)
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path)
            if FileManager.default.fileExists(atPath: stateURL.path) {
                settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: stateURL))
                _ = ModelPublishing.migrateStoredIDs(&settings)
                settings = migrateKimiWork(settings)
                try persist(settings) // Persist newly migrated private core credentials once.
            } else {
                try persist(settings)
            }
        } catch {
            validState = false
            self.error = "读取本地配置失败。请先检查数据目录中的 state.json。\n" + error.localizedDescription
            status = "配置需要检查"
        }
        do {
            let cursorURL = dataDirectory.appendingPathComponent("cursor-local.json")
            if FileManager.default.fileExists(atPath: cursorURL.path) {
                cursorIdentity = try JSONDecoder().decode(CursorLocalIdentity.self, from: Data(contentsOf: cursorURL))
            }
        } catch {
            cursorStatus = "本地身份配置读取失败，请检查 cursor-local.json"
            self.error = cursorStatus
        }
        if cursorIdentity.enabled { cursorStatus = "已记住 BD 模式 · 等待服务启动" }
    }

    func record(_ message: String, failed: Bool = false) {
        activities.insert(Activity(message: message, failed: failed), at: 0)
        activities = Array(activities.prefix(100))
    }

    func report(_ failure: Error) {
        error = redacted(failure.localizedDescription)
        record(error ?? "操作失败", failed: true)
    }

    func redacted(_ text: String) -> String {
        var result = text
        let proxies = (settings.channels.map(\.proxyURL) + [settings.proxyURL]).filter { $0.contains("@") }
        let secrets = settings.channels.map(\.apiKey) + proxies + [settings.clientKey, settings.managementKey, settings.coreClientKey]
        for secret in secrets where !secret.isEmpty { result = result.replacingOccurrences(of: secret, with: "••••••") }
        return String(result.prefix(1000))
    }

    private func persist(_ value: AppSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try privateWrite(encoder.encode(value), to: stateURL)
    }

    func coreDocument(_ value: AppSettings) -> [String: Any] {
        settingsForCore(value).coreConfig(dataDirectory: dataDirectory, pluginDirectory: pluginDirectory)
    }

    private func prepareCore() throws {
        let target = pluginDirectory.appendingPathComponent("darwin/arm64")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var names = ["kiro.dylib", "cursor-agent2api.dylib"]
        if #available(macOS 15.0, *) { names.append("omc-zcode-oauth.dylib") }
        for name in names {
            let plugin = Bundle.main.resourceURL!.appendingPathComponent(name)
            let destination = target.appendingPathComponent(name)
            let bundledPlugin = try Data(contentsOf: plugin)
            if (try? Data(contentsOf: destination)) != bundledPlugin {
                try privateWrite(bundledPlugin, to: destination)
            }
        }
        try FileManager.default.createDirectory(at: dataDirectory.appendingPathComponent("accounts"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try privateWrite(jsonData(settingsForCore(settings).coreConfig(dataDirectory: dataDirectory, pluginDirectory: pluginDirectory)), to: configURL)
        workAppliedFingerprint = kimiWorkFingerprint()
    }

    func start() async {
        guard validState, !busy, !running else { return }
        busy = true
        shuttingDown = false
        status = "正在启动反代内核"
        defer { busy = false }
        // Let a core that is still shutting down release the port first, so we
        // never reconnect to a dying server.
        await exitTask?.value
        exitTask = nil
        do {
            // Reserve the public port before reconnecting to a core or touching
            // shared runtimes. A port conflict must leave the existing service alone.
            modelGateway.update(port: settings.port, corePort: settings.corePort, clientKey: settings.clientKey,
                                coreKey: settings.coreClientKey, catalog: availableModels, coreModels: rawModels.map(\.id))
            try await modelGateway.start()
            // A previous app crash can leave its child alive. Only reconnect to a
            // server authenticated with this installation's private management key.
            if let _ = try? await request("/v8/management/config", timeout: 1) {
                running = true
                status = "本地服务已连接"
                await synchronizeKimiWork(force: true)
                record("重新连接已有的 BridgeDock 本地服务")
                beginRefreshing()
                await refresh()
                await startCursorSession()
                return
            }
            // Migrate an authenticated, recorded legacy core off the public port.
            if let legacyPID = stopOrphan() {
                await Task.detached { Self.awaitExit(legacyPID, forceKill: false) }.value
            }
            try prepareCore()
            let logURL = dataDirectory.appendingPathComponent("startup.log")
            try privateWrite(Data(), to: logURL)
            outputHandle = try FileHandle(forWritingTo: logURL)
            let process = Process()
            process.executableURL = coreURL
            process.arguments = ["-config", configURL.path, "-local-model"]
            process.currentDirectoryURL = dataDirectory
            process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                                   "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory()]
            process.standardOutput = outputHandle
            process.standardError = outputHandle
            process.terminationHandler = { [weak self] exited in
                let code = exited.terminationStatus
                Task { @MainActor in
                    guard let self, self.core === exited else { return }
                    self.running = false
                    self.modelGateway.stop()
                    self.kiroRuntime.stop()
                    self.cursorSession.stop()
                    self.cursorSessionReady = false
                    if self.cursorIdentity.enabled { self.cursorStatus = "BD 反代已暂停 · 等待服务启动" }
                    self.status = self.shuttingDown ? "服务已停止" : "内核已退出（\(code)）"
                    if !self.shuttingDown { self.record("反代内核退出，请检查端口或诊断日志（\(code)）", failed: true) }
                }
            }
            try process.run()
            core = process
            try privateWrite(jsonData(["pid": process.processIdentifier, "executable": coreURL.path]), to: dataDirectory.appendingPathComponent("process.json"))
            var ready = false
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 150_000_000)
                guard process.isRunning else { break }
                if let _ = try? await request("/v8/management/config", timeout: 1) { ready = true; break }
            }
            guard ready else {
                if process.isRunning { process.terminate() }
                throw BridgeError.message("反代内核未能启动。内部端口 \(settings.corePort) 可能已被占用，请在设置中换一个端口。诊断日志位于数据目录。")
            }
            running = true
            status = "本地服务运行中"
            record("反代已启动 · 127.0.0.1:\(settings.port)")
            beginRefreshing()
            await refresh()
            await startCursorSession()
        } catch {
            modelGateway.stop()
            kiroRuntime.stop()
            refreshTask?.cancel()
            cursorSession.stop()
            cursorSessionReady = false
            if core?.isRunning == true { core?.terminate() }
            running = false
            status = "启动失败"; report(error)
        }
    }

    /// Stops the core. The UI path waits for exit on a background task so the
    /// window never freezes; app termination passes `waitForExit` because the
    /// process must be gone before the app exits.
    func stop(waitForExit: Bool = false) {
        cancelModelTest()
        quotaGeneration += 1
        for id in quotaStates.keys { quotaStates[id]?.loading = false }
        modelGateway.stop()
        kiroRuntime.stop()
        cursorSession.stop()
        cursorSessionReady = false
        if cursorIdentity.enabled { cursorStatus = "BD 反代已暂停 · 等待服务启动" }
        shuttingDown = true
        refreshTask?.cancel()
        loginTask?.cancel()
        login = nil
        var target: (pid: pid_t, forceKill: Bool)?
        if let core, core.isRunning {
            core.terminate()
            target = (core.processIdentifier, true)
        } else if let pid = stopOrphan() {
            target = (pid, false)
        }
        if let target {
            if waitForExit { Self.awaitExit(target.pid, forceKill: target.forceKill) }
            else { exitTask = Task.detached { Self.awaitExit(target.pid, forceKill: target.forceKill) } }
        }
        core = nil
        try? outputHandle?.close()
        outputHandle = nil
        running = false
        status = "服务已停止"
        record("反代已停止")
    }

    /// Waits up to 2 seconds for `pid` to exit, then SIGKILLs it if allowed.
    nonisolated private static func awaitExit(_ pid: pid_t, forceKill: Bool) {
        let deadline = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if forceKill && kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// Sends SIGTERM to a core left by a crashed app and returns its pid.
    private func stopOrphan() -> pid_t? {
        let url = dataDirectory.appendingPathComponent("process.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int32, pid > 1,
              let path = object["executable"] as? String else { return nil }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/ps")
        check.arguments = ["-p", String(pid), "-o", "comm="]
        let pipe = Pipe()
        check.standardOutput = pipe
        check.standardError = FileHandle.nullDevice
        guard (try? check.run()) != nil else { return nil }
        let actual = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        check.waitUntilExit()
        guard actual == path && path == coreURL.path else { return nil }
        kill(pid, SIGTERM)
        return pid
    }

    func request(_ path: String, method: String = "GET", body: Data? = nil,
                 management: Bool = true, timeout: TimeInterval = 65, contentType: String = "application/json", internalCore: Bool = false) async throws -> Data {
        guard let url = URL(string: (management || internalCore ? coreBaseURL : baseURL) + path) else { throw BridgeError.message("无效的本地 API 地址。") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("Bearer " + (management ? settings.managementKey : (internalCore ? settings.coreClientKey : settings.clientKey)), forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BridgeError.message("反代服务未返回 HTTP 响应。") }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let errorObject = object?["error"] as? [String: Any]
            let message = errorObject?["message"] as? String ?? object?["error"] as? String ?? "请求失败"
            throw BridgeError.message("HTTP \(http.statusCode) · \(redacted(message))")
        }
        return data
    }

    func object(_ path: String, method: String = "GET", value: Any? = nil) async throws -> [String: Any] {
        let body = try value.map { try jsonData($0) }
        let data = try await request(path, method: method, body: body)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func update(_ candidate: AppSettings) async throws {
        guard !busy, !workSyncing else { throw BridgeError.message("另一项配置操作正在进行，请稍后重试。") }
        guard (1024...65535).contains(candidate.port), candidate.port != Int(CursorSessionServer.port) else { throw BridgeError.message("端口应为 1024–65535，18418 保留给 Cursor 本机会话。") }
        try validateProxyURL(candidate.proxyURL)
        if running && candidate.port != settings.port { throw BridgeError.message("请先停止反代服务，再修改端口。") }
        busy = true
        defer { busy = false }
        let previous = settings
        try persist(candidate)
        do {
            if running {
                let data = try jsonData(settingsForCore(candidate).coreConfig(dataDirectory: dataDirectory, pluginDirectory: pluginDirectory))
                _ = try await request("/v8/management/config.yaml", method: "PUT", body: data, contentType: "application/yaml")
            }
            settings = candidate
            refreshPublishedCatalog()
            workAppliedFingerprint = kimiWorkFingerprint()
        } catch {
            try? persist(previous)
            // A lost response can follow a successful server commit. Reapply the
            // previous document so the disk/UI and live server agree on rollback.
            if running {
                let old = try? jsonData(settingsForCore(previous).coreConfig(dataDirectory: dataDirectory, pluginDirectory: pluginDirectory))
                _ = try? await request("/v8/management/config.yaml", method: "PUT", body: old, contentType: "application/yaml")
            }
            throw error
        }
        if running {
            try? await Task.sleep(nanoseconds: 450_000_000)
            await refresh()
        }
    }

    func saveChannel(_ channel: Channel) async throws {
        let unchanged = settings.channels.first { $0.id == channel.id }?.prefix == channel.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = try channel.validated(channels: settings.channels, accounts: unchanged ? [] : accounts)
        var next = settings
        if let index = next.channels.firstIndex(where: { $0.id == value.id }) { next.channels[index] = value }
        else { next.channels.append(value) }
        try await update(next)
        record("已保存渠道 · \(value.name)")
    }

    func deleteChannel(_ channel: Channel) async {
        var next = settings
        next.channels.removeAll { $0.id == channel.id }
        do { try await update(next); record("已删除渠道 · \(channel.name)") }
        catch { report(error) }
    }

    private func beginRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard running else { return }
        await synchronizeKimiWork()
        do {
            async let modelData = request("/v1/models", management: false, timeout: 5, internalCore: true)
            async let accountData = request("/v8/management/credentials", timeout: 5)
            let (m, a) = try await (modelData, accountData)
            let modelObject = try JSONSerialization.jsonObject(with: m) as? [String: Any]
            rawModels = (modelObject?["data"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["id"] as? String else { return nil }
                return ModelItem(id: id, owner: $0["owned_by"] as? String ?? "", metadata: $0)
            }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            let accountObject = try JSONSerialization.jsonObject(with: a) as? [String: Any]
            var rows = accountObject?["files"] as? [[String: Any]] ?? []
            // Keep only non-secret routing prefixes, profiles and login portal metadata.
            // Some plugins omit these from the credential summary.
            for index in rows.indices where rows[index]["provider"] as? String == "zcode" || rows[index]["prefix"] == nil
                || (rows[index]["provider"] as? String == CursorAccountProfile.providerID && rows[index]["runtime_profile"] == nil) {
                guard let name = rows[index]["name"] as? String,
                      let data = try? await request("/v8/management/credentials/download?name=" + Self.query(name), timeout: 5),
                      let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                rows[index]["prefix"] = metadata["prefix"] as? String ?? ""
                if rows[index]["provider"] as? String == "zcode" {
                    rows[index]["oauth_provider"] = metadata["oauth_provider"] as? String ?? ((metadata["site"] as? String) == "bigmodel" ? "zcode-bigmodel" : "zcode-zai")
                }
                if rows[index]["provider"] as? String == CursorAccountProfile.providerID {
                    rows[index]["runtime_profile"] = metadata["runtime_profile"] as? String ?? CursorAccountProfile.cursor.rawValue
                }
            }
            accounts = rows.map(Account.init)
                .filter { !["api-key", "apikey"].contains($0.provider) }
            // Plugin vendors register their definitions after startup; retry missing sets.
            let definitionKey = Set(accounts.map(\.provider) + modelOwners).sorted().joined(separator: ",")
            let incomplete = !Self.expectedDefinitionSets(accounts, owners: modelOwners).isSubset(of: Set(modelDefinitions.keys))
            if definitionKey != modelDefinitionKey || (incomplete && Date().timeIntervalSince(modelDefinitionsLoadedAt) > 30) {
                modelDefinitions = await loadModelDefinitions()
                modelDefinitionKey = definitionKey
                modelDefinitionsLoadedAt = Date()
            }
            await loadCursorModelCatalogs()
            refreshPublishedCatalog()
            status = "本地服务运行中"
            await kiroRuntime.synchronize(proxyURL: settings.proxyURL)
            if cursorIdentity.enabled {
                try cursorSession.update(identity: cursorIdentity, apiURL: apiURL, key: settings.clientKey,
                                         model: settings.selectedModels["Cursor"] ?? models.first?.id ?? "")
            }
            Task { await self.refreshQuotas() }
            Task { await self.backfillChannelCapabilities() }
        } catch {
            status = "本地连接异常，请检查服务"
        }
    }

    private func loadCursorModelCatalogs() async {
        let eligible = accounts.filter {
            $0.provider == CursorAccountProfile.providerID && $0.runtimeProfile != CursorAccountProfile.grokBot.rawValue
                && !$0.disabled && !$0.requiresSignIn && !$0.prefix.isEmpty
        }
        let names = Set(eligible.map(\.name))
        cursorModelCatalogs = cursorModelCatalogs.filter { names.contains($0.key) }
        cursorCatalogAttempts = cursorCatalogAttempts.filter { names.contains($0.key) }
        for account in eligible {
            guard Date().timeIntervalSince(cursorCatalogAttempts[account.name] ?? .distantPast) >= 300 else { continue }
            cursorCatalogAttempts[account.name] = Date()
            do {
                let data = try await request("/v8/management/credentials/download?name=" + Self.query(account.name), timeout: 10)
                guard let credential = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = credential["access_token"] as? String, !token.isEmpty else { continue }
                let payload = try jsonData(["includeLongContextModels": true, "useModelParameters": true,
                                           "doNotUseMarkdown": true, "useCloudAgentEffortModes": true])
                let response = try await object("/v8/management/requests/api-call", method: "POST", value: [
                    "method": "POST", "url": "https://api2.cursor.sh/aiserver.v1.AiService/AvailableModels",
                    "proxy_url": credential["proxy_url"] as? String ?? "",
                    "header": ["Authorization": "Bearer " + token, "Content-Type": "application/json",
                               "Connect-Protocol-Version": "1", "X-Cursor-Client-Type": "cli", "X-Ghost-Mode": "true",
                               "X-Cursor-Client-Version": credential["client_version"] as? String ?? "cli-2026.10.22-27dcf5f"],
                    "data": String(decoding: payload, as: UTF8.self)
                ])
                guard response["status_code"] as? Int == 200,
                      let body = response["body"] as? String, body.utf8.count <= 4_000_000 else { continue }
                let catalog = try JSONDecoder().decode(CursorModelCatalog.self, from: Data(body.utf8))
                guard accounts.contains(where: { $0.name == account.name && !$0.disabled }) else { continue }
                cursorModelCatalogs[account.name] = catalog
            } catch {
                record("Cursor 模型参数暂时无法更新，将在下次刷新时重试。", failed: true)
            }
        }
    }

    private func refreshPublishedCatalog() {
        let previous = availableModels
        var cursorRoutes: [String: CursorModelRoute] = [:]
        let availableIDs = Set(rawModels.filter { $0.owner.caseInsensitiveCompare(CursorAccountProfile.providerID) == .orderedSame }.map(\.id))
        for account in accounts where !account.disabled && !account.prefix.isEmpty {
            if let catalog = cursorModelCatalogs[account.name] {
                cursorRoutes.merge(catalog.routes(prefix: account.prefix, availableModelIDs: availableIDs)) { current, _ in current }
            }
            // The catalog endpoint is optional and has returned several
            // incompatible field shapes over Cursor releases.  Infer routes
            // from the model slugs already registered by the core so the
            // account still gets a standard picker instead of raw suffixes.
            cursorRoutes.merge(CursorModelCatalog.inferredRoutes(prefix: account.prefix, availableModelIDs: availableIDs)) { current, _ in current }
        }
        availableModels = ModelPublishing.catalog(rawModels: rawModels, settings: settings, accounts: accounts,
                                                  definitions: modelDefinitions, cursorRoutes: cursorRoutes)
        if ModelPublishing.migrateStoredIDs(&settings, catalog: availableModels) {
            availableModels = ModelPublishing.catalog(rawModels: rawModels, settings: settings, accounts: accounts,
                                                      definitions: modelDefinitions, cursorRoutes: cursorRoutes)
            try? persist(settings)
        }
        var seen: Set<String> = []
        models = availableModels.filter { $0.isEnabled && seen.insert($0.publicID).inserted }.map { model in
            ModelItem(id: model.publicID, owner: providers(for: model.publicID).map(\.name).joined(separator: " / "))
        }
        for (tool, selected) in settings.selectedModels {
            if models.contains(where: { $0.id == selected }) { continue }
            let rawID = previous.first(where: { $0.publicID == selected })?.id ?? selected
            settings.selectedModels[tool] = availableModels.first(where: { ($0.id == rawID || $0.publicID == selected) && $0.isEnabled })?.publicID
        }
        modelGateway.update(port: settings.port, corePort: settings.corePort, clientKey: settings.clientKey,
                            coreKey: settings.coreClientKey, catalog: availableModels, coreModels: rawModels.map(\.id))
    }

    /// 公开 ID 不再带渠道前缀，界面改为显示渠道自身的路由前缀。
    func publicPrefix(source: String) -> String? { nil }

    /// 按公开 ID 查合并后的供应商（第一个为默认），含各自的 key、名称与能力。
    func providers(for publicID: String) -> [ModelPublishing.Provider] {
        ModelPublishing.providers(in: availableModels, publicID: publicID)
    }

    func savePublishedModels(_ ids: Set<String>) async throws {
        var candidate = settings
        candidate.publishedModelIDs = ids.sorted()
        try await update(candidate)
        try persist(settings)
        record("已设置反代开放模型 · \(models.count) 个")
    }

    func fetchModels(for channel: Channel) async throws -> String {
        try await discoverModels(for: channel).modelLines
    }

    func beginLogin(_ provider: String, account: Account? = nil, proxyURL: String = "", method: String = "") async {
        guard running, !busy, !loginStarting, login == nil else { return }
        loginStarting = true
        defer { loginStarting = false }
        var provider = SubscriptionProvider.find(provider)?.id ?? provider
        if let entry = SubscriptionProvider.find(provider), !entry.available || entry.importOnly {
            report(BridgeError.message(entry.importOnly ? "此服务商需要导入 Key，不能使用浏览器授权。" : entry.unavailableReason))
            return
        }
        if let account, account.provider == "zcode" {
            do {
                let data = try await request("/v8/management/credentials/download?name=" + Self.query(account.name))
                let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                provider = value["oauth_provider"] as? String ?? ((value["site"] as? String) == "bigmodel" ? "zcode-bigmodel" : "zcode-zai")
            } catch { report(error); return }
        }
        do {
            if provider == "kiro", !method.isEmpty {
                var next = settings
                next.kiroUseOrganization = method == "organization"
                if next.kiroUseOrganization {
                    guard let url = URL(string: next.kiroStartURL), url.scheme == "https", url.host != nil else {
                        throw BridgeError.message("请先在设置中填写组织 SSO 的 HTTPS Start URL。")
                    }
                }
                if next.kiroUseOrganization != settings.kiroUseOrganization { try await update(next) }
            }
        } catch { report(error); return }
        loginStatus = "正在创建登录会话…"
        busy = true
        defer { busy = false }
        do {
            var body: [String: Any] = ["provider": provider, "is_webui": true]
            let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            try validateProxyURL(proxy)
            guard proxy != "direct" else { throw BridgeError.message("授权代理不支持 direct。直连请清空全局出站代理。") }
            if !proxy.isEmpty { body["proxy_url"] = proxy }
            if let account, SubscriptionProvider.find(provider)?.supportsRecovery == true {
                body["name"] = account.name
                if !account.authIndex.isEmpty { body["auth_index"] = account.authIndex }
                // The core applies this proxy during token exchange as well as inference.
                if proxy.isEmpty {
                    let options = try await loadAccountOptions(account)
                    if !options.proxyURL.isEmpty && options.proxyURL != "direct" { body["proxy_url"] = options.proxyURL }
                }
            }
            let result = try await object("/v8/management/oauth/auth-url", method: "POST", value: body)
            guard let url = result["url"] as? String, let state = result["state"] as? String,
                  !state.isEmpty, let destination = URL(string: url), destination.host != nil,
                  ["https", "http"].contains(destination.scheme ?? "") else {
                throw BridgeError.message("登录服务未返回有效的授权地址。")
            }
            let seconds = OAuthCallback.lifetime(provider: provider, advertised: (result["expires_in"] as? NSNumber)?.doubleValue)
            let query = URLComponents(string: url)?.queryItems ?? []
            let code = result["user_code"] as? String ?? query.first(where: { ["user_code", "userCode"].contains($0.name) })?.value ?? ""
            let item = LoginSession(provider: provider, state: state, url: url, userCode: code,
                                    expiresAt: Date().addingTimeInterval(seconds), previousAccount: account?.name)
            callbackSubmission = nil
            login = item
            loginStatus = provider == "claude" ? "请在网页完成 Claude 授权，通常会自动返回。需要手动提交时，请复制授权完成后的结果，不要复制登录页地址。" : "请在浏览器完成授权，完成后这里会自动更新。"
            if !NSWorkspace.shared.open(destination) { loginStatus = "浏览器未能打开，请复制授权链接到浏览器完成登录。" }
            loginTask = Task { [weak self] in
                while Date() < item.expiresAt {
                    do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                    guard let self, self.login?.id == item.id else { return }
                    do {
                        let value = try await self.object("/v8/management/oauth/status?state=" + Self.query(item.state))
                        guard self.login?.id == item.id else { return }
                        let status = value["status"] as? String
                        if status == "ok" {
                            self.login = nil
                            if value["saved"] as? Bool == true && value["adopted"] as? Bool == false {
                                self.loginStatus = "凭据已保存，但尚未加载到反代服务。请刷新列表或重启服务。"
                            } else if value["requires_sign_in"] as? Bool == true {
                                self.loginStatus = "授权返回的凭据仍要求重新登录，请检查账号权限后重试。"
                            } else {
                                self.loginStatus = "账号授权已保存。请在模型页测试实际调用。"
                            }
                            self.record(self.loginStatus + " · " + item.displayName)
                            await self.refresh()
                            return
                        }
                        if status == "error" {
                            self.login = nil
                            let failure = self.redacted(value["error"] as? String ?? "请重新登录")
                            if item.provider == "claude", failure.contains("Failed to exchange authorization code") {
                                self.loginStatus = "Claude 授权码换取令牌失败。请重新发起授权，仅提交本次授权完成后的 code#state 或 localhost 回调地址；旧授权码和登录页链接不能使用。"
                            } else {
                                self.loginStatus = "登录失败 · " + failure
                            }
                            _ = try? await self.request("/v8/management/oauth/session?state=" + Self.query(item.state), method: "DELETE")
                            return
                        }
                    } catch { self.loginStatus = "等待授权结果，暂时无法连接本地服务。" }
                }
                guard let self, self.login?.id == item.id else { return }
                self.login = nil
                self.loginStatus = "登录会话已超时，请重新添加账号。"
                _ = try? await self.request("/v8/management/oauth/session?state=" + Self.query(item.state), method: "DELETE")
            }
        } catch { report(error); loginStatus = "登录会话创建失败" }
    }

    func cancelLogin() async {
        loginTask?.cancel()
        callbackSubmission = nil
        let cancelled = login
        login = nil
        loginStatus = ""
        if let cancelled { _ = try? await request("/v8/management/oauth/session?state=" + Self.query(cancelled.state), method: "DELETE") }
    }

    @discardableResult
    func submitCallback(_ text: String) async -> Bool {
        guard let login, callbackSubmission == nil else { return false }
        do {
            let payload = try OAuthCallback.payload(text, session: login)
            callbackSubmission = login.id
            _ = try await object("/v8/management/oauth/callback", method: "POST", value: payload)
            guard self.login?.id == login.id else { return true }
            loginStatus = "回调已提交，正在等待登录完成。"
            return true
        } catch {
            if callbackSubmission == login.id { callbackSubmission = nil }
            guard self.login?.id == login.id else { return false }
            report(error)
            return false
        }
    }

    func importAccount() async {
        guard running, !busy, login == nil, accountOperation == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "支持 Claude Code 凭据、Codex auth.json、Kiro 登录缓存，以及 CLIProxyAPI 凭据 JSON。"
        guard panel.runModal() == .OK else { return }
        busy = true
        defer { busy = false }
        var imported = 0
        for url in panel.urls {
            do {
                let data = try LocalSubscriptionCredentials.normalized(Data(contentsOf: url))
                if let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let prefix = value["prefix"] as? String, !prefix.isEmpty,
                   settings.channels.contains(where: { $0.prefix == prefix }) || accounts.contains(where: { $0.prefix == prefix }) {
                    throw BridgeError.message("导入凭据的前缀 \(prefix) 已被占用，请先修改 JSON 中的 prefix · " + url.lastPathComponent)
                }
                // A stable content identity makes repeated imports idempotent without
                // conflating accounts that happen to share the same email address.
                let digest = ConfigurationInstaller(directory: dataDirectory).digest(data)
                let filename = "import-" + digest + ".json"
                if FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("accounts/" + filename).path) {
                    record("已跳过重复导入 · " + url.lastPathComponent)
                    continue
                }
                _ = try await request("/v8/management/credentials?name=" + Self.query(filename), method: "POST", body: data)
                imported += 1
                record("已导入账号文件 · \(url.lastPathComponent)")
            } catch { report(error) }
        }
        await refresh()
        loginStatus = "本次已导入 \(imported) 个账号文件。"
    }

    func loadAccountOptions(_ account: Account) async throws -> AccountOptions {
        let data = try await request("/v8/management/credentials/download?name=" + Self.query(account.name))
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.message("账号配置不是有效的 JSON 对象。")
        }
        return AccountOptions(account: account, document: value)
    }

    func addCursorAccount(label: String, key: String, profile: CursorAccountProfile = .cursor, proxyURL: String = "") async throws {
        guard running, !busy, accountOperation == nil else { throw BridgeError.message("请启动本地服务并等待当前操作完成。") }
        var credential = try profile.credential(label: label, key: key, prefix: "")
        busy = true
        defer { busy = false }
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let pastedSession = CursorSessionCredential.recognizes(normalizedKey) ? try CursorSessionCredential(normalizedKey) : nil
        let digest = ConfigurationInstaller(directory: dataDirectory).digest(Data((pastedSession?.subject ?? normalizedKey).utf8))
        let name = profile.filename(digest: digest)
        var previous: [String: Any]?
        if accounts.contains(where: { $0.name == name }) || FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("accounts/" + name).path) {
            guard let pastedSession else {
                throw BridgeError.message("这个账号已接入 \(profile.title) 通道，请在现有账号中修改设置。")
            }
            let data = try await request("/v8/management/credentials/download?name=" + Self.query(name))
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  existing["auth_method"] as? String == "session",
                  existing["account_id"] as? String == pastedSession.subject else {
                throw BridgeError.message("现有账号身份不匹配，未覆盖原凭据。")
            }
            previous = existing
        }
        let effectiveProxy = previous?["proxy_url"] as? String ?? proxyURL
        try validateProxyURL(effectiveProxy)
        if let pastedSession {
            // Only the fixed official endpoint receives the pasted cookie. Do not
            // display an upstream body, which could echo authentication headers.
            let result: [String: Any]
            do {
                result = try await object("/v8/management/requests/api-call", method: "POST", value: [
                    "method": "GET", "url": "https://cursor.com/api/auth/me", "proxy_url": effectiveProxy,
                    "header": ["Cookie": pastedSession.cookie, "Accept": "application/json"]
                ])
            } catch { throw BridgeError.message("无法连接 Cursor 验证账号，请检查网络或代理后重试。") }
            guard let status = result["status_code"] as? Int, status == 200 else {
                throw BridgeError.message("Cursor 未接受这份会话凭据，请重新登录后复制，或检查出站代理。")
            }
            guard let body = result["body"] as? String, let bytes = body.data(using: .utf8),
                  let identity = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw BridgeError.message("Cursor 账号验证响应格式无效，请稍后重试。")
            }
            credential["email"] = try pastedSession.verifiedEmail(identity)
            credential["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        }
        if var previous {
            // Re-pasting a renewed session updates authentication only. Preserve
            // the account's routing, note, proxy and intentional disabled state.
            for field in ["access_token", "email", "expired", "last_refresh"] { previous[field] = credential[field] }
            credential = previous
        } else {
            credential["proxy_url"] = effectiveProxy
            var occupied = Set(settings.channels.map(\.prefix))
            for account in accounts {
                let options = try await loadAccountOptions(account)
                if !options.prefix.isEmpty { occupied.insert(options.prefix) }
            }
            credential["prefix"] = LocalSubscriptionIdentity.prefix(provider: profile.prefix, occupied: occupied)
        }
        let data = try jsonData(credential)
        _ = try await request("/v8/management/credentials?name=" + Self.query(name), method: "POST", body: data)
        record(previous == nil ? "已添加 \(profile.title) 通道 · Cursor 账号" : "已更新 \(profile.title) 会话凭据 · 保留原账号设置")
        await refresh()
    }

    func saveAccountOptions(_ account: Account, options: AccountOptions) async throws {
        guard running, !busy, accountOperation == nil else { throw BridgeError.message("请等待当前操作完成。") }
        let fields = try options.fields(name: account.name)
        let prefix = fields["prefix"] as? String ?? ""
        guard prefix.isEmpty || !settings.channels.contains(where: { $0.prefix == prefix }) else {
            throw BridgeError.message("此前缀已被 API 渠道使用，请换一个账号前缀。")
        }
        guard prefix.isEmpty || !accounts.contains(where: { $0.name != account.name && $0.prefix == prefix && $0.provider != account.provider }) else {
            throw BridgeError.message("此前缀已被其他服务商的账号使用，请换一个账号前缀。")
        }
        accountOperation = account.id
        defer { accountOperation = nil }
        _ = try await object("/v8/management/credentials/fields", method: "PATCH", value: fields)
        record("已更新账号设置 · " + account.email)
        await refresh()
    }

    func loadAccountModels(_ account: Account) async throws -> [String] {
        let value = try await object("/v8/management/credentials/models?name=" + Self.query(account.name))
        return (value["models"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.sorted()
    }

    func refreshAccount(_ account: Account) async {
        guard running, !busy, accountOperation == nil else { return }
        accountOperation = account.id
        defer { accountOperation = nil }
        do {
            var value: [String: Any] = ["name": account.name]
            if !account.authIndex.isEmpty { value["auth_index"] = account.authIndex }
            let result = try await object("/v8/management/credentials/refresh", method: "POST", value: value)
            guard result["ok"] as? Bool == true,
                  (result["auth"] as? [String: Any])?["requires_sign_in"] as? Bool != true else {
                throw BridgeError.message("凭据刷新未成功，请重新授权。")
            }
            record("已刷新账号凭据 · " + account.email)
        } catch { report(error) }
        await refresh()
    }

    func toggleAccount(_ account: Account) async {
        guard running, !busy, accountOperation == nil else { return }
        accountOperation = account.id
        defer { accountOperation = nil }
        do {
            var target: [String: Any] = ["name": account.name, "disabled": !account.disabled]
            if !account.authIndex.isEmpty { target["auth_index"] = account.authIndex }
            _ = try await object("/v8/management/credentials/status", method: "PATCH", value: target)
            await refresh()
        } catch { report(error) }
    }

    func removeAccount(_ account: Account) async {
        guard running, !busy, accountOperation == nil else { return }
        accountOperation = account.id
        defer { accountOperation = nil }
        var backupSaved = false
        var disabledForDeletion = false
        do {
            let query = Self.query(account.name)
            let data = try await request("/v8/management/credentials/download?name=" + query)
            let backup = dataDirectory.appendingPathComponent("removed-accounts/" + UUID().uuidString + ".json")
            try privateWrite(data, to: backup)
            backupSaved = true
            // Unregister active models before deleting the file. The core can
            // otherwise retain Codex model entries after removing the account.
            var target: [String: Any] = ["name": account.name, "disabled": true]
            if !account.authIndex.isEmpty { target["auth_index"] = account.authIndex }
            _ = try await object("/v8/management/credentials/status", method: "PATCH", value: target)
            disabledForDeletion = !account.disabled
            _ = try await request("/v8/management/credentials?name=" + query, method: "DELETE")
            record("已移除账号并保存恢复副本 · " + account.email)
            await refresh()
        } catch {
            let deletionError = error
            var recovery = ""
            if disabledForDeletion {
                do {
                    var target: [String: Any] = ["name": account.name, "disabled": false]
                    if !account.authIndex.isEmpty { target["auth_index"] = account.authIndex }
                    _ = try await object("/v8/management/credentials/status", method: "PATCH", value: target)
                    recovery = "已恢复账号原来的启用状态。\n"
                } catch {
                    recovery = "未能确认账号已恢复启用，请检查列表中的账号状态。\n"
                }
            }
            if backupSaved {
                report(BridgeError.message("删除账号未完成，恢复副本已保留在 removed-accounts 文件夹。\n" + recovery + deletionError.localizedDescription))
                await refresh()
            } else { report(deletionError) }
        }
    }

    /// provider 为 `providers(for:)` 返回的 key；nil 时网关选默认供应商。
    func startModelTest(_ model: String, wire: String, mode: ModelTestMode, effort: ModelReasoningEffort = .unset, provider: String? = nil) {
        guard running, !model.isEmpty, !testing, modelTestTask == nil else { return }
        modelTestTask = Task { await testModel(model, wire: wire, mode: mode, effort: effort, provider: provider) }
    }

    func cancelModelTest() {
        modelTestTask?.cancel()
    }

    func testModel(_ model: String, wire: String = "chat", mode: ModelTestMode = .quick, effort: ModelReasoningEffort = .unset,
                   provider: String? = nil) async {
        guard running, !testing, !model.isEmpty else { return }
        testing = true
        defer { testing = false; modelTestTask = nil }
        let chosen = providers(for: model).first { $0.key == provider } ?? providers(for: model).first
        let probes = ModelTestProbe.make(for: mode, contextLimit: chosen?.capability?.contextLength)
        let route = ModelRouteExpectation(model: model, catalog: availableModels, settings: settings,
                                          effort: mode == .reasoning && effort != .unset ? effort.rawValue : nil, provider: provider)
        var report = ModelTestReport(mode: mode, model: model, wire: wire, effort: effort, route: route, plannedCount: probes.count)
        // Keep the endpoint and key consistent for every sample in this run.
        let endpoint = URL(string: baseURL)!
        let key = settings.clientKey
        var thinking = AnthropicThinkingStyle.adaptive
        testReport = report
        for (index, probe) in probes.enumerated() {
            if Task.isCancelled { break }
            testResult = "正在测试 \(index + 1) / \(probes.count) · \(probe.title)"
            var sample = await modelTestSample(endpoint: endpoint, key: key, model: model, wire: wire, mode: mode,
                                               probe: probe, index: index, effort: effort, thinking: thinking, provider: provider)
            // Older Claude models reject adaptive thinking; fall back to budget thinking once and keep it for the run.
            if wire == "anthropic", probe.usesEffort, thinking == .adaptive, sample.httpStatus == 400, !Task.isCancelled {
                thinking = .budget
                sample = await modelTestSample(endpoint: endpoint, key: key, model: model, wire: wire, mode: mode,
                                               probe: probe, index: index, effort: effort, thinking: thinking, provider: provider)
            }
            if Task.isCancelled { break }
            sample.error = sample.error.map(redacted)
            sample.text = redacted(sample.text)
            sample.returnedModels = sample.returnedModels.map(redacted)
            report.samples.append(sample)
            testReport = report
            if mode.stopsOnFailure, !sample.succeeded || sample.answerCorrect == false { break }
        }
        report.finished = true
        report.cancelled = Task.isCancelled
        testReport = report
        testResult = report.cancelled ? "测试已取消，保留已完成的结果。" : "测试完成 · 成功 \(report.successful) / \(report.samples.count) 次"
        if mode == .longContext, !report.cancelled, let chosen, chosen.model.cursorRoute == nil, chosen.model.workModel == nil {
            await recordVerifiedContexts(report, routeID: chosen.model.id)
        }
        record("\(mode.title) · \(model) · \(testResult)", failed: !report.cancelled && report.successful < report.samples.count)
    }

    /// 只记录实测取回全部埋点的档位；之后 Cursor 菜单的上下文选项即为这些档位。
    private func recordVerifiedContexts(_ result: ModelTestReport, routeID: String) async {
        let passed = result.samples.filter { $0.succeeded && $0.answerCorrect == true }.compactMap(\.probe.contextTier).sorted()
        var next = settings
        next.verifiedContexts[routeID] = passed.isEmpty ? nil : passed
        guard next.verifiedContexts != settings.verifiedContexts else { return }
        do {
            try await update(next)
            let labels = passed.map(ModelPublishing.tokenLabel).joined(separator: " / ")
            record("已按长上下文检测记录 \(result.model) 的上下文档位 · " + (labels.isEmpty ? "无通过档位" : labels))
        } catch { report(error) }
    }

    private func modelTestSample(endpoint: URL, key: String, model: String, wire: String, mode: ModelTestMode, probe: ModelTestProbe,
                                 index: Int, effort: ModelReasoningEffort, thinking: AnthropicThinkingStyle,
                                 provider: String? = nil) async -> ModelTestSample {
        do {
            let request = try ModelTestHTTP.request(baseURL: endpoint, key: key, model: model, wire: wire, probe: probe,
                                                    streaming: mode.streaming, effort: effort, thinking: thinking, provider: provider)
            return await ModelTestHTTP.perform(request, probe: probe, index: index)
        } catch {
            return ModelTestSample(id: index, probe: probe, error: error.localizedDescription)
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func rememberLaunch(_ agent: EditingAgent, project: String) throws {
        var next = settings
        next.lastOpenedAgent = agent
        next.lastOpenedProject = project
        try persist(next)
        settings = next
    }

    func showDataDirectory() { NSWorkspace.shared.open(dataDirectory) }
    static func query(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}
