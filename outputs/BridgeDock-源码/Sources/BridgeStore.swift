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
    @Published var accounts: [Account] = []
    @Published var activities: [Activity] = []
    @Published var login: LoginSession?
    @Published var loginStatus = ""
    @Published var testResult = ""
    @Published var testing = false
    let dataDirectory: URL
    private let stateURL: URL
    private let configURL: URL
    private let pluginDirectory: URL
    private var core: Process?
    private var outputHandle: FileHandle?
    private var loginTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var validState = true
    private var shuttingDown = false
    private let session: URLSession
    var baseURL: String { "http://127.0.0.1:\(settings.port)" }
    var apiURL: String { baseURL + "/v1" }
    var coreURL: URL { Bundle.main.resourceURL!.appendingPathComponent("cli-proxy-api") }

    init() {
        let override = ProcessInfo.processInfo.environment["BRIDGEDOCK_DATA_DIR"]
        dataDirectory = override.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BridgeDock")
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
            } else {
                try persist(settings)
            }
        } catch {
            validState = false
            self.error = "读取本地配置失败。请先检查数据目录中的 state.json。\n" + error.localizedDescription
            status = "配置需要检查"
        }
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
        let secrets = settings.channels.map(\.apiKey) + [settings.clientKey, settings.managementKey]
        for secret in secrets where !secret.isEmpty { result = result.replacingOccurrences(of: secret, with: "••••••") }
        return String(result.prefix(1000))
    }

    private func persist(_ value: AppSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try privateWrite(encoder.encode(value), to: stateURL)
    }

    private func prepareCore() throws {
        let target = pluginDirectory.appendingPathComponent("darwin/arm64")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let plugin = Bundle.main.resourceURL!.appendingPathComponent("kiro.dylib")
        let destination = target.appendingPathComponent("kiro.dylib")
        let bundledPlugin = try Data(contentsOf: plugin)
        if (try? Data(contentsOf: destination)) != bundledPlugin {
            try bundledPlugin.write(to: destination, options: .atomic)
        }
        try FileManager.default.createDirectory(at: dataDirectory.appendingPathComponent("accounts"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try privateWrite(jsonData(settings.coreConfig(dataDirectory: dataDirectory, pluginDirectory: pluginDirectory)), to: configURL)
    }

    func start() async {
        guard validState, !busy, !running else { return }
        busy = true
        shuttingDown = false
        status = "正在启动反代内核"
        defer { busy = false }
        do {
            // A previous app crash can leave its child alive. Only reconnect to a
            // server authenticated with this installation's private management key.
            if let _ = try? await request("/v8/management/config", timeout: 1) {
                running = true
                status = "本地服务已连接"
                record("重新连接已有的 BridgeDock 本地服务")
                beginRefreshing()
                await refresh()
                return
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
                throw BridgeError.message("反代内核未能启动。端口 \(settings.port) 可能已被占用，请在设置中换一个端口。诊断日志位于数据目录。")
            }
            running = true
            status = "本地服务运行中"
            record("反代已启动 · 127.0.0.1:\(settings.port)")
            beginRefreshing()
            await refresh()
        } catch { status = "启动失败"; report(error) }
    }

    func stop() {
        shuttingDown = true
        refreshTask?.cancel()
        loginTask?.cancel()
        login = nil
        if let core, core.isRunning {
            core.terminate()
            let deadline = Date().addingTimeInterval(2)
            while core.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if core.isRunning { kill(core.processIdentifier, SIGKILL) }
        } else {
            stopOrphan()
        }
        core = nil
        try? outputHandle?.close()
        outputHandle = nil
        running = false
        status = "服务已停止"
        record("反代已停止")
    }

    private func stopOrphan() {
        let url = dataDirectory.appendingPathComponent("process.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int32, pid > 1,
              let path = object["executable"] as? String else { return }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/ps")
        check.arguments = ["-p", String(pid), "-o", "comm="]
        let pipe = Pipe()
        check.standardOutput = pipe
        check.standardError = FileHandle.nullDevice
        guard (try? check.run()) != nil else { return }
        let actual = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        check.waitUntilExit()
        if actual == path && path == coreURL.path {
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(2)
            while kill(pid, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        }
    }

    func request(_ path: String, method: String = "GET", body: Data? = nil,
                 management: Bool = true, timeout: TimeInterval = 65, contentType: String = "application/json") async throws -> Data {
        guard let url = URL(string: baseURL + path) else { throw BridgeError.message("无效的本地 API 地址。") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("Bearer " + (management ? settings.managementKey : settings.clientKey), forHTTPHeaderField: "Authorization")
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
        guard !busy else { throw BridgeError.message("另一项配置操作正在进行，请稍后重试。") }
        guard (1024...65535).contains(candidate.port) else { throw BridgeError.message("端口应为 1024–65535。") }
        try validateProxyURL(candidate.proxyURL)
        if running && candidate.port != settings.port { throw BridgeError.message("请先停止反代服务，再修改端口。") }
        busy = true
        defer { busy = false }
        let previous = settings
        try persist(candidate)
        do {
            if running {
                let data = try jsonData(candidate.coreConfig(dataDirectory: dataDirectory, pluginDirectory: pluginDirectory))
                _ = try await request("/v8/management/config.yaml", method: "PUT", body: data, contentType: "application/yaml")
            }
            settings = candidate
        } catch {
            try? persist(previous)
            // A lost response can follow a successful server commit. Reapply the
            // previous document so the disk/UI and live server agree on rollback.
            if running {
                let old = try? jsonData(previous.coreConfig(dataDirectory: dataDirectory, pluginDirectory: pluginDirectory))
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
        let value = try channel.validated()
        var next = settings
        guard !next.channels.contains(where: { $0.id != value.id && $0.prefix == value.prefix }) else {
            throw BridgeError.message("该前缀已被其他渠道使用，请换一个前缀。")
        }
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
        do {
            async let modelData = request("/v1/models", management: false, timeout: 5)
            async let accountData = request("/v8/management/credentials", timeout: 5)
            let (m, a) = try await (modelData, accountData)
            let modelObject = try JSONSerialization.jsonObject(with: m) as? [String: Any]
            models = (modelObject?["data"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["id"] as? String else { return nil }
                return ModelItem(id: id, owner: $0["owned_by"] as? String ?? "")
            }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            let accountObject = try JSONSerialization.jsonObject(with: a) as? [String: Any]
            accounts = (accountObject?["files"] as? [[String: Any]] ?? []).map(Account.init)
                .filter { !["api-key", "apikey"].contains($0.provider) }
            status = "本地服务运行中"
        } catch {
            status = "本地连接异常，请检查服务"
        }
    }

    func fetchModels(for channel: Channel) async throws -> String {
        guard running else { throw BridgeError.message("请先启动本地服务。") }
        var base = channel.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base), ["http", "https"].contains(url.scheme ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil else { throw BridgeError.message("请先填写有效的 Base URL。") }
        guard !channel.apiKey.isEmpty else { throw BridgeError.message("请先填写 API Key。") }
        var headers = ["Authorization": "Bearer " + channel.apiKey]
        if channel.wire == .anthropic { headers = ["x-api-key": channel.apiKey, "anthropic-version": "2023-06-01"] }
        let suffix = channel.wire == .anthropic && !base.hasSuffix("/v1") ? "/v1/models" : "/models"
        let result = try await object("/v8/management/requests/api-call", method: "POST", value: [
            "method": "GET", "url": base + suffix, "header": headers, "proxy_url": channel.proxyURL
        ])
        guard let code = result["status_code"] as? Int, (200..<300).contains(code),
              let text = result["body"] as? String, let data = text.data(using: .utf8) else {
            throw BridgeError.message("获取模型失败（HTTP \(result["status_code"] ?? "?")）。该服务可能需要手动填写模型 ID。")
        }
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = value?["data"] as? [[String: Any]] ?? value?["models"] as? [[String: Any]] ?? []
        let names = rows.compactMap { $0["id"] as? String ?? $0["slug"] as? String }.sorted()
        guard !names.isEmpty else { throw BridgeError.message("接口未返回模型列表，请手动填写服务商提供的模型 ID。") }
        return names.joined(separator: "\n")
    }

    func beginLogin(_ provider: String) async {
        guard running, login == nil else { return }
        loginStatus = "正在创建登录会话…"
        busy = true
        defer { busy = false }
        do {
            let result = try await object("/v8/management/oauth/auth-url?provider=\(provider)&is_webui=true")
            guard let url = result["url"] as? String, let state = result["state"] as? String,
                  let destination = URL(string: url), ["https", "http"].contains(destination.scheme ?? "") else {
                throw BridgeError.message("登录服务未返回有效的授权地址。")
            }
            let item = LoginSession(provider: provider, state: state, url: url, userCode: result["user_code"] as? String ?? "")
            login = item
            loginStatus = "请在浏览器完成授权，完成后这里会自动更新。"
            NSWorkspace.shared.open(destination)
            loginTask = Task { [weak self] in
                for _ in 0..<240 {
                    do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                    guard let self, self.login?.id == item.id else { return }
                    do {
                        let value = try await self.object("/v8/management/oauth/status?state=" + Self.query(item.state))
                        let status = value["status"] as? String
                        if status == "ok" {
                            self.login = nil
                            self.loginStatus = "账号已保存，请在模型页测试实际调用。"
                            self.record("账号登录完成 · \(provider)")
                            await self.refresh()
                            return
                        }
                        if status == "error" {
                            self.loginStatus = "登录失败 · " + self.redacted(value["error"] as? String ?? "请重新登录")
                            return
                        }
                    } catch { self.loginStatus = "等待授权结果，暂时无法连接本地服务。" }
                }
                self?.loginStatus = "登录会话已超时，请取消后重试。"
            }
        } catch { report(error); loginStatus = "登录会话创建失败" }
    }

    func cancelLogin() async {
        loginTask?.cancel()
        if let login { _ = try? await request("/v8/management/oauth/session?state=" + Self.query(login.state), method: "DELETE") }
        login = nil
        loginStatus = ""
    }

    func submitCallback(_ text: String) async {
        guard let login else { return }
        do {
            _ = try await object("/v8/management/oauth/callback", method: "POST", value: ["provider": login.provider, "redirect_url": text])
            loginStatus = "回调已提交，正在等待登录完成。"
        } catch { report(error) }
    }

    func importAccount() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "选择 CLIProxyAPI 格式的账号凭据 JSON。Kiro 支持包含 accessToken / refreshToken 的凭据。"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 2_000_000,
                      let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], !value.isEmpty else {
                    throw BridgeError.message("\(url.lastPathComponent) 不是有效的账号 JSON。")
                }
                _ = try await request("/v0/management/auth-files?name=" + Self.query(UUID().uuidString + ".json"), method: "POST", body: data)
                record("已导入账号文件 · \(url.lastPathComponent)")
            } catch { report(error) }
        }
        await refresh()
    }

    func toggleAccount(_ account: Account) async {
        do {
            _ = try await object("/v8/management/credentials/status", method: "PATCH", value: ["name": account.name, "disabled": !account.disabled])
            await refresh()
        } catch { report(error) }
    }

    func removeAccount(_ account: Account) async {
        do {
            let query = Self.query(account.name)
            let data = try await request("/v8/management/credentials/download?name=" + query)
            let backup = dataDirectory.appendingPathComponent("removed-accounts/" + UUID().uuidString + ".json")
            try privateWrite(data, to: backup)
            _ = try await request("/v8/management/credentials?name=" + query, method: "DELETE")
            record("已移除账号并保存恢复副本 · " + account.email)
            await refresh()
        } catch { report(error) }
    }

    func testModel(_ model: String, wire: String = "chat") async {
        guard running, !testing, !model.isEmpty else { return }
        testing = true
        testResult = "正在发送简短测试请求…"
        defer { testing = false }
        let start = Date()
        do {
            let path: String
            let body: [String: Any]
            if wire == "responses" {
                path = "/v1/responses"
                body = ["model": model, "input": "Reply with OK only.", "max_output_tokens": 64, "stream": false]
            } else if wire == "anthropic" {
                path = "/v1/messages"
                body = ["model": model, "messages": [["role": "user", "content": "Reply with OK only."]], "max_tokens": 64, "stream": false]
            } else {
                path = "/v1/chat/completions"
                body = ["model": model, "messages": [["role": "user", "content": "Reply with OK only."]], "max_tokens": 64, "stream": false]
            }
            let data = try await request(path, method: "POST", body: jsonData(body), management: false, timeout: 120)
            let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            if response["error"] != nil && !(response["error"] is NSNull) { throw BridgeError.message("上游返回了错误，请检查账号与模型权限。") }
            let text: String
            if let choices = response["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any] {
                text = message["content"] as? String ?? "返回了工具调用或推理结果"
            } else if let content = response["content"] as? [[String: Any]] {
                text = content.compactMap { $0["text"] as? String }.joined()
            } else {
                text = (response["output"] as? [[String: Any]] ?? []).flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }.joined()
            }
            testResult = "调用成功 · \(String(format: "%.2f", Date().timeIntervalSince(start))) 秒\n\(text.isEmpty ? "请求已完成，未返回可显示文本。" : text)"
            record("测试通过 · \(model) · \(wire)")
        } catch { testResult = redacted(error.localizedDescription); record("模型测试失败 · \(model)", failed: true) }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func showDataDirectory() { NSWorkspace.shared.open(dataDirectory) }
    static func query(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}
