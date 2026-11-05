import Foundation
import Network

/// Public loopback endpoint. The core's private key never leaves this process.
/// Model filtering is applied to both discovery and inference before any upstream request.
final class ModelGateway: @unchecked Sendable {
    /// Native picker selections travel in a local-only header. Validate them
    /// against this route before translating to an upstream ID or API field.
    static func parameterSelection(_ header: String?) throws -> [String: String]? {
        guard let header else { return nil }
        guard header.utf8.count <= 16_384, let text = header.removingPercentEncoding,
              let rows = try? JSONDecoder().decode([CursorModelCatalog.Parameter].self, from: Data(text.utf8)),
              rows.count <= 32 else { throw BridgeError.message("模型参数格式无效，请重新选择模型。") }
        var result: [String: String] = [:]
        for row in rows {
            guard result[row.id] == nil else { throw BridgeError.message("模型参数重复，请重新选择模型。") }
            result[row.id] = row.value
        }
        return result
    }

    /// Older clients sometimes persisted a provider-qualified public name such
    /// as `Work/kimi-k3.1-pro` even though the v2 catalogue exposes the same
    /// model under its canonical bare ID. Resolve that form only when the
    /// qualifier matches a real published provider name; an arbitrary
    /// `prefix/model` never bypasses the publication allowlist.
    static func qualifiedProviders(for publicID: String, in catalog: [PublishedModel]) -> (bareID: String, providers: [ModelPublishing.Provider])? {
        guard let slash = publicID.firstIndex(of: "/"), slash > publicID.startIndex else { return nil }
        let qualifier = String(publicID[..<slash])
        let bareID = String(publicID[publicID.index(after: slash)...])
        guard !bareID.isEmpty else { return nil }
        let candidates = ModelPublishing.providers(in: catalog, publicID: bareID)
        guard !candidates.isEmpty else { return nil }
        func compact(_ value: String) -> String {
            value.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let wanted = compact(qualifier)
        let matches = candidates.filter { provider in
            let name = compact(provider.name)
            // `route:` and `provider:` entries are inferred from raw core
            // model IDs. Treating those prefixes as aliases would let a raw
            // core route such as `fixture/model-a` bypass the public catalog.
            let isPublishedSource = !provider.key.hasPrefix("route:") && !provider.key.hasPrefix("provider:")
            return isPublishedSource && wanted == name
        }
        return matches.isEmpty ? nil : (bareID, matches)
    }

    /// 按 parameters 里 id 为 provider 的值选渠道，缺省取第一个；provider 键会被消费掉。
    /// 所选渠道未声明的思考强度、上下文和 Fast 会去掉，改用该渠道的默认值。
    static func provider(for publicID: String, in catalog: [PublishedModel],
                         parameters: inout [String: String]?) throws -> PublishedModel? {
        var providers = ModelPublishing.providers(in: catalog, publicID: publicID)
        if providers.isEmpty, let qualified = qualifiedProviders(for: publicID, in: catalog) {
            providers = qualified.providers
            var values = parameters ?? [:]
            if values["provider"] == nil, providers.count == 1 { values["provider"] = providers[0].key }
            parameters = values
        }
        if providers.isEmpty, let legacy = legacyCursorRoute(for: publicID, in: catalog) {
            // 客户端刷新模型列表前仍会发送旧的带后缀 ID：钉住原供应商与思考强度。
            providers = ModelPublishing.providers(in: catalog, publicID: legacy.model.publicID)
            var values = parameters ?? [:]
            if values["provider"] == nil { values["provider"] = legacy.model.sourceID }
            if values["reasoning"] == nil, let effort = legacy.effort { values["reasoning"] = effort }
            parameters = values
        }
        if providers.isEmpty, let base = ModelPublishing.fastBase(of: publicID) {
            // 合并前发布的高速模型 ID 仍可调用：改为基础模型并打开快速模式，钉住原渠道。
            let tail = String(base.split(separator: "/", maxSplits: 1).last ?? Substring(base))
            let candidates = ModelPublishing.providers(in: catalog, publicID: base)
                + (tail == base ? [] : ModelPublishing.providers(in: catalog, publicID: tail))
            if let owner = candidates.first(where: { $0.model.fastModelID.map { $0.hasSuffix("/" + publicID) || $0 == publicID } == true }) {
                providers = candidates
                var values = parameters ?? [:]
                if values["provider"] == nil { values["provider"] = owner.key }
                values["fast"] = "true"
                parameters = values
            }
        }
        guard !providers.isEmpty else { return nil }
        let requested = parameters?.removeValue(forKey: "provider")
        // Existing clients may still call Kiro's dotted Claude ID. Preserve that
        // route unless they explicitly choose another provider of the merged model.
        let legacy = publicID == ModelPublishing.publicModelID(publicID) ? nil : providers.first { $0.model.modelName == publicID }
        guard let chosen = requested.map({ key in providers.first { $0.key == key } }) ?? legacy ?? providers.first else {
            throw BridgeError.message("所选供应商已不可用，请刷新模型列表后重新选择。")
        }
        if var values = parameters {
            if let effort = values["reasoning"], effort != "none", chosen.capability?.reasoningEfforts?.contains(effort) != true {
                values.removeValue(forKey: "reasoning")
            }
            if let context = values["context"] {
                let options = chosen.contextOptions
                let size = Int(context)
                if size.map(options.contains) != true { values.removeValue(forKey: "context") }
            }
            if values["fast"] != nil, !chosen.supportsFast { values.removeValue(forKey: "fast") }
            parameters = values
        }
        return chosen.model
    }

    /// 旧公开 ID（`Curs-f3e5cf18/kimi-k3-high` 或 `kimi-k3-high`）对应的合并路由和其中的思考强度。
    static func legacyCursorRoute(for publicID: String, in catalog: [PublishedModel]) -> (model: PublishedModel, effort: String?)? {
        let slug = ModelPublishing.migratedPublicID(publicID)
        for model in catalog where model.isEnabled {
            guard let route = model.cursorRoute,
                  let member = route.memberModelIDs.first(where: { $0 == slug || $0.hasSuffix("/" + slug) }) else { continue }
            return (model, route.modelsByEffort.first { $0.value == member }?.key)
        }
        return nil
    }

    static func routedBody(_ source: [String: Any], route: PublishedModel, path: String,
                           parameters: [String: String]?) throws -> [String: Any] {
        var body = source
        guard let parameters, !parameters.isEmpty else {
            body["model"] = try route.cursorRoute?.modelID(body: body, path: path) ?? route.id
            return body
        }
        if let work = route.workModel {
            _ = try work.headers(parameters: parameters)
            body["model"] = route.id
        } else if let cursor = route.cursorRoute, !cursor.variants.isEmpty {
            body["model"] = try cursor.modelID(parameters: parameters)
        } else {
            let capability = ModelCapability(definition: route.metadata) ?? route.capability
            guard Set(parameters.keys).isSubset(of: ["context", "reasoning", "fast"]) else {
                throw BridgeError.message("当前渠道不支持所选模型参数，请刷新模型列表。")
            }
            if let fast = parameters["fast"] {
                guard ["true", "false"].contains(fast), fast == "false" || route.fastModelID != nil else {
                    throw BridgeError.message("当前渠道没有该模型的高速版，请刷新模型列表。")
                }
            }
            if let value = parameters["context"] {
                guard let limit = capability?.contextLength, let size = Int(value), size > 0, size <= limit else {
                    throw BridgeError.message("所选上下文预算超过当前渠道的模型上限。")
                }
            }
            let effort = parameters["reasoning"]
            if let effort, effort != "none", capability?.reasoningEfforts?.contains(effort) != true {
                throw BridgeError.message("当前渠道不支持思考档位 \(effort)，请刷新模型列表。")
            }
            if let cursor = route.cursorRoute { body["model"] = try cursor.modelID(effort: effort == "none" ? nil : effort) }
            else { body["model"] = parameters["fast"] == "true" ? route.fastModelID! : route.id }
        }
        if let effort = parameters["reasoning"] {
            // Cursor's "none" variant is encoded in its exact upstream model ID.
            // Other providers use "none" in this menu to retain their default.
            body.removeValue(forKey: "reasoning_effort")
            var reasoning = body["reasoning"] as? [String: Any] ?? [:]
            var output = body["output_config"] as? [String: Any] ?? [:]
            reasoning.removeValue(forKey: "effort")
            output.removeValue(forKey: "effort")
            if effort != "none" {
                if path.hasPrefix("/v1/responses") { reasoning["effort"] = effort }
                else if path.hasPrefix("/v1/messages") {
                    output["effort"] = effort
                    body["thinking"] = ["type": "adaptive"]
                } else { body["reasoning_effort"] = effort }
            }
            body["reasoning"] = reasoning.isEmpty ? nil : reasoning
            body["output_config"] = output.isEmpty ? nil : output
        }
        return body
    }

    /// Clients sometimes persist an aborted turn as an empty assistant message;
    /// Kimi and others reject the whole request for it, and it carries nothing.
    static func droppingEmptyAssistantMessages(_ source: [String: Any]) -> [String: Any] {
        func blank(_ value: Any?) -> Bool {
            switch value {
            case nil, is NSNull: return true
            case let text as String: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case let parts as [Any]:
                return parts.allSatisfy { part in
                    guard let part = part as? [String: Any] else { return blank(part) }
                    guard let type = part["type"] as? String, ["text", "output_text", "input_text"].contains(type) else { return false }
                    return blank(part["text"])
                }
            default: return false
            }
        }
        func empty(_ item: Any) -> Bool {
            guard let message = item as? [String: Any], message["role"] as? String == "assistant",
                  (message["type"] as? String ?? "message") == "message" else { return false }
            for key in ["tool_calls", "function_call", "reasoning_content", "audio", "refusal"] where !blank(message[key]) {
                if let calls = message[key] as? [Any], calls.isEmpty { continue }
                return false
            }
            return blank(message["content"])
        }
        var body = source
        for key in ["messages", "input"] {
            if let items = body[key] as? [Any] { body[key] = items.filter { !empty($0) } }
        }
        return body
    }

    static func routedHeaders(_ source: [String: String], route: PublishedModel,
                              parameters: [String: String]?) throws -> [String: String] {
        var result = source.filter { !["x-kimi-model-speed", "x-kimi-context-length"].contains($0.key.lowercased()) }
        if let work = route.workModel {
            let incoming = Dictionary(source.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
            result.merge(try work.headers(parameters: parameters ?? [:], incoming: incoming)) { _, fresh in fresh }
        }
        return result
    }

    private let queue = DispatchQueue(label: "local.bridgedock.model-gateway")
    private let lock = NSLock()
    private var listener: NWListener?
    private var clients: [UUID: GatewayClient] = [:]
    private var configuration = GatewayConfiguration()

    /// `coreModels` is the full core route list; image requests always use the best GPT image model in it,
    /// whatever model the client asked for.
    func update(port: Int, corePort: Int, clientKey: String, coreKey: String, catalog: [PublishedModel], coreModels: [String] = []) {
        lock.lock()
        let kiro = configuration.kiro
        configuration = GatewayConfiguration(port: port, corePort: corePort, clientKey: clientKey, coreKey: coreKey,
                                             catalog: catalog.filter(\.isEnabled), imageModel: Self.preferredImageModel(coreModels), kiro: kiro)
        lock.unlock()
    }

    /// Connection-level failures where kiro2cc produced no response, so retrying on the core is safe.
    static func isUnreachable(_ failure: Error) -> Bool {
        guard let code = (failure as? URLError)?.code else { return false }
        return [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet].contains(code)
    }

    /// Kiro inference bypasses the core when the streaming runtime is up; nil sends it back to the core.
    func updateKiro(_ route: KiroGatewayRoute?) {
        lock.withLock { configuration.kiro = route }
    }

    /// Kiro models are owned by "kiro" in the core catalog; their prefix selects the account pool,
    /// or the shared pool when two or more Kiro accounts are enabled.
    static func kiroTarget(for model: PublishedModel, route: KiroGatewayRoute?) -> (port: Int, key: String, model: String)? {
        guard let route, model.owner.lowercased() == "kiro" else { return nil }
        let parts = model.id.split(separator: "/", maxSplits: 1).map(String.init)
        let prefix = parts.count == 2 ? parts[0] : ""
        // A known prefix joins the shared pool when one exists, so the model picked in the
        // client no longer pins every request to one account.
        guard let own = route.keys[prefix] else { return nil }
        let pool = route.pooledPrefixes.contains(prefix) ? route.keys[KiroGatewayRoute.poolKey] : nil
        let key = pool ?? own
        return (route.port, key, parts.count == 2 ? parts[1] : model.id)
    }

    /// Newest `gpt-image-X.Y` wins; the plain model is preferred over suffixed variants of the same version.
    static func preferredImageModel(_ ids: [String]) -> String? {
        let marker = "gpt-image-"
        let candidates: [(id: String, version: [Int], plain: Bool)] = ids.compactMap { id in
            let name = id.split(separator: "/").last.map(String.init) ?? id
            guard name.hasPrefix(marker) else { return nil }
            let rest = name.dropFirst(marker.count)
            let versionText = rest.prefix { $0.isNumber || $0 == "." }
            let version = versionText.split(separator: ".").compactMap { Int($0) }
            guard !version.isEmpty else { return nil }
            return (id, version, rest.count == versionText.count)
        }
        return candidates.max { a, b in
            if a.version != b.version { return a.version.lexicographicallyPrecedes(b.version) }
            if a.plain != b.plain { return !a.plain }
            if a.id.hasPrefix("gpt/") != b.id.hasPrefix("gpt/") { return !a.id.hasPrefix("gpt/") }
            return a.id > b.id
        }?.id
    }

    /// Converts any OpenAI- or xAI-style image body into one a GPT image model accepts.
    static func gptImageBody(_ source: [String: Any], model: String) -> [String: Any] {
        var object = source
        object["model"] = model
        if object["size"] == nil, let ratio = object["aspect_ratio"] as? String {
            let parts = ratio.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2, parts[0] > 0, parts[1] > 0 {
                object["size"] = parts[0] > parts[1] ? "1536x1024" : parts[0] < parts[1] ? "1024x1536" : "1024x1024"
            }
        }
        // GPT image models always return base64 and reject these xAI/DALL·E parameters.
        for key in ["aspect_ratio", "resolution", "response_format", "style"] { object.removeValue(forKey: key) }
        if object["quality"] == nil { object["quality"] = "high" }
        return object
    }

    /// Replaces (or adds) the `model` field of a multipart/form-data body.
    static func multipartReplacingModel(_ body: Data, boundary: String, model: String) -> Data? {
        let delimiter = Data(("--" + boundary).utf8)
        var pieces: [Data] = []
        var index = body.startIndex
        while let range = body.range(of: delimiter, in: index..<body.endIndex) {
            pieces.append(body[index..<range.lowerBound]); index = range.upperBound
        }
        pieces.append(body[index...])
        // pieces: preamble, parts..., closing "--\r\n"
        guard pieces.count >= 2, pieces.last!.starts(with: Data("--".utf8)) else { return nil }
        let separator = Data("\r\n\r\n".utf8)
        let parts = pieces.dropFirst().dropLast().filter { part in
            guard let end = part.range(of: separator), let head = String(data: part[..<end.lowerBound], encoding: .utf8) else { return true }
            return !head.lowercased().contains("name=\"model\"")
        }
        let modelPart = Data("\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n".utf8)
        var output = Data()
        for part in [modelPart] + parts { output.append(delimiter); output.append(part) }
        output.append(delimiter); output.append(pieces.last!)
        return output
    }

    func start() async throws {
        guard listener == nil else { return }
        let port = lock.withLock { configuration.port }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!)
        do {
            let value = try NWListener(using: parameters)
            listener = value
            value.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                let id = UUID()
                let client = GatewayClient(connection: connection, configuration: { [weak self] in
                    guard let self else { return GatewayConfiguration() }
                    return self.lock.withLock { self.configuration }
                }, queue: self.queue) { [weak self] in self?.clients.removeValue(forKey: id) }
                self.clients[id] = client
                client.start()
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                value.stateUpdateHandler = { state in
                    switch state {
                    case .ready: value.stateUpdateHandler = nil; continuation.resume()
                    case .failed(let error): value.stateUpdateHandler = nil; continuation.resume(throwing: error)
                    case .cancelled: value.stateUpdateHandler = nil; continuation.resume(throwing: CancellationError())
                    default: break
                    }
                }
                value.start(queue: queue)
            }
        } catch {
            stop()
            if let failure = error as? NWError, case .posix(.EADDRINUSE) = failure {
                throw BridgeError.message("本地端口 \(port) 已被占用。请关闭重复打开的 BridgeDock；如果该端口用于其他程序，可在“设置与诊断”中更换端口。")
            }
            throw error
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        queue.async {
            let active = Array(self.clients.values)
            active.forEach { $0.finish() }
            self.clients.removeAll()
        }
    }
}

struct KiroGatewayRoute {
    let port: Int
    let keys: [String: String]
    /// Prefixes routed to the shared pool key.
    var pooledPrefixes: Set<String> = []
    /// `keys` entry of the key bound to every pooled account. Prefixes come from
    /// `LocalSubscriptionIdentity` and never contain "*", so it cannot collide with one.
    static let poolKey = "*"
}

private struct GatewayConfiguration {
    var port = 18417
    var corePort = 18419
    var clientKey = ""
    var coreKey = ""
    var catalog: [PublishedModel] = []
    var imageModel: String?
    var kiro: KiroGatewayRoute?
}

private final class GatewayClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private let configurationProvider: () -> GatewayConfiguration
    private var configuration = GatewayConfiguration()
    private let queue: DispatchQueue
    private let completed: () -> Void
    private var buffer = Data()
    private var handled = false
    private var closed = false
    private var responseStarted = false
    /// The core-bound form of a request sent to kiro2cc, replayed once if kiro2cc cannot be reached
    /// (for example in the seconds between a crash and its automatic restart).
    private var kiroFallback: (path: String, headers: [String: String], body: Data)?
    private var continueSent = false
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var pendingBytes = 0
    private var suspended = false
    private let maximumBody = 32 * 1024 * 1024
    private static let inferencePaths: Set<String> = ["/v1/chat/completions", "/v1/completions", "/v1/responses", "/v1/responses/compact", "/v1/messages", "/v1/messages/count_tokens", "/v1/embeddings"]
    private static let imagePaths: Set<String> = ["/v1/images/generations", "/v1/images/edits"]
    private static let hopHeaders: Set<String> = ["connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade", "host", "content-length", "authorization", "x-api-key", "accept-encoding", "expect", "x-bridgedock-parameters", "x-bridgedock-model-parameters"]

    init(connection: NWConnection, configuration: @escaping () -> GatewayConfiguration, queue: DispatchQueue, completed: @escaping () -> Void) {
        self.connection = connection; self.configurationProvider = configuration; self.queue = queue; self.completed = completed
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish() }
            if case .cancelled = state { self?.finish() }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, !self.handled else { return }
            self.error(408, "请求体接收超时。")
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if error != nil { self.finish(); return }
            self.buffer.append(data ?? Data())
            if self.buffer.count > self.maximumBody + 65536 { self.error(413, "请求体超过 32 MB。") ; return }
            if !self.handled { self.parse() }
            if complete {
                if !self.handled { self.error(400, "请求体不完整。") }
                return
            }
            if !self.closed { self.receive() }
        }
    }

    private func parse() {
        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 65536 { error(431, "请求头过大。") }
            return
        }
        guard split.lowerBound <= 65536, let head = String(data: buffer[..<split.lowerBound], encoding: .utf8) else { error(400, "无效请求头。"); return }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3 else { error(400, "无效请求。"); return }
        let method = String(first[0]); let target = String(first[1])
        guard target.hasPrefix("/"), !target.hasPrefix("//"), let components = URLComponents(string: target), components.scheme == nil, components.host == nil, components.fragment == nil else { error(400, "无效的请求路径。"); return }
        let path = components.path
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { error(400, "无效请求头。"); return }
            let key = parts[0].lowercased()
            guard headers[key] == nil else { error(400, "不接受重复请求头。"); return }
            headers[key] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        configuration = configurationProvider()
        let known = path == "/v1/models" || path.hasPrefix("/v1/models/") || Self.inferencePaths.contains(path) || Self.imagePaths.contains(path)
        guard known else { error(404, "此接口未通过 BridgeDock 开放。"); return }
        if method == "OPTIONS" { handled = true; respond(204, data: Data()); return }
        let bearer = headers["authorization"]
        guard !configuration.clientKey.isEmpty,
              bearer == "Bearer " + configuration.clientKey || headers["x-api-key"] == configuration.clientKey else { error(401, "无效的 BridgeDock API Key。"); return }
        if let expect = headers["expect"] {
            guard expect.lowercased() == "100-continue" else { error(417, "不支持此 Expect 请求头。"); return }
            if !continueSent { continueSent = true; send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }
        }
        let start = split.upperBound
        let body: Data
        if let encoding = headers["transfer-encoding"] {
            guard encoding.lowercased() == "chunked", headers["content-length"] == nil else { error(400, "无效的请求传输编码。"); return }
            do {
                guard let parsed = try decodedChunks(Data(buffer[start...])) else { return }
                body = parsed
            } catch { self.error(400, "无效的分块请求体。"); return }
        } else {
            let length: Int
            if let raw = headers["content-length"] {
                guard let parsed = Int(raw), parsed >= 0 else { error(400, "无效的请求长度。"); return }
                length = parsed
            } else { length = 0 }
            guard length <= maximumBody else { error(413, "请求体超过 32 MB。"); return }
            guard buffer.count - start >= length else { return }
            body = Data(buffer[start..<(start + length)])
        }
        handled = true
        buffer.removeAll(keepingCapacity: false)
        if method == "GET", path == "/v1/models" {
            respond(200, object: ["object": "list", "data": ModelPublishing.catalogEntries(configuration.catalog)])
            return
        }
        if method == "GET", path.hasPrefix("/v1/models/") {
            // URLComponents.path has already decoded percent escapes once.
            let id = String(path.dropFirst("/v1/models/".count))
            let providers = ModelPublishing.providers(in: configuration.catalog, publicID: id)
                .isEmpty ? ModelGateway.qualifiedProviders(for: id, in: configuration.catalog)?.providers ?? []
                : ModelPublishing.providers(in: configuration.catalog, publicID: id)
            guard let entry = ModelPublishing.catalogEntry(providers) else { error(404, "模型未开放。"); return }
            respond(200, object: entry); return
        }
        if Self.imagePaths.contains(path) { forwardImage(method: method, target: target, headers: headers, body: body); return }
        guard method == "POST", Self.inferencePaths.contains(path) else { error(405, "该接口不支持此方法。"); return }
        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let model = object["model"] as? String else { error(400, "请提供 JSON model 字段。"); return }
        let route: PublishedModel
        let forwardedHeaders: [String: String]
        do {
            var parameters = try ModelGateway.parameterSelection(headers["x-bridgedock-parameters"])
            guard let chosen = try ModelGateway.provider(for: model, in: configuration.catalog, parameters: &parameters) else {
                error(404, "该模型未开放或名称已更新，请刷新模型列表。"); return
            }
            route = chosen
            object = try ModelGateway.routedBody(object, route: route, path: path,
                                                parameters: parameters)
            object = ModelGateway.droppingEmptyAssistantMessages(object)
            forwardedHeaders = try ModelGateway.routedHeaders(headers, route: route, parameters: parameters)
        } catch { self.error(400, error.localizedDescription); return }
        let kiro = ModelGateway.kiroTarget(for: route, route: configuration.kiro)
        // kiro2cc serves chat, messages and responses only; other paths stay on the core.
        let kiroPaths: Set<String> = ["/v1/chat/completions", "/v1/messages", "/v1/messages/count_tokens", "/v1/responses"]
        if let kiro, kiroPaths.contains(path) {
            let coreBody = try? JSONSerialization.data(withJSONObject: object)
            object["model"] = kiro.model
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { error(400, "无效的 JSON 请求体。"); return }
            if let coreBody { kiroFallback = (target, forwardedHeaders, coreBody) }
            forward(path: target, headers: headers, body: data, port: kiro.port, key: kiro.key)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { error(400, "无效的 JSON 请求体。"); return }
        forward(path: target, headers: forwardedHeaders, body: data)
    }

    private func decodedChunks(_ data: Data) throws -> Data? {
        var index = data.startIndex; var decoded = Data()
        while true {
            guard let lineEnd = data.range(of: Data("\r\n".utf8), in: index..<data.endIndex) else { return nil }
            guard let text = String(data: data[index..<lineEnd.lowerBound], encoding: .ascii),
                  let sizeText = text.split(separator: ";", maxSplits: 1).first,
                  let size = Int(sizeText, radix: 16), size >= 0 else { throw URLError(.cannotParseResponse) }
            index = lineEnd.upperBound
            guard size <= maximumBody - decoded.count else { throw URLError(.dataLengthExceedsMaximum) }
            if size == 0 {
                guard data.count - index >= 2 else { return nil }
                guard data[index..<(index + 2)] == Data("\r\n".utf8) else { throw URLError(.cannotParseResponse) }
                return decoded
            }
            guard data.count - index >= size + 2 else { return nil }
            decoded.append(data[index..<(index + size)]); index += size
            guard data[index..<(index + 2)] == Data("\r\n".utf8) else { throw URLError(.cannotParseResponse) }
            index += 2
        }
    }

    private func forwardImage(method: String, target: String, headers: [String: String], body: Data) {
        guard method == "POST" else { error(405, "该接口不支持此方法。"); return }
        guard let model = configuration.imageModel else {
            error(503, "未找到可用的 GPT 生图模型，请先在“账号与渠道”中连接 GPT / Codex 登录。"); return
        }
        let contentType = headers["content-type"] ?? "application/json"
        if contentType.lowercased().hasPrefix("multipart/form-data") {
            guard let boundary = contentType.components(separatedBy: ";").lazy
                    .map({ $0.trimmingCharacters(in: .whitespaces) })
                    .first(where: { $0.lowercased().hasPrefix("boundary=") })
                    .map({ String($0.dropFirst("boundary=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }),
                  !boundary.isEmpty,
                  let data = ModelGateway.multipartReplacingModel(body, boundary: boundary, model: model) else {
                error(400, "无效的 multipart 请求体。"); return
            }
            forward(path: target, headers: headers, body: data, contentType: contentType)
            return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: ModelGateway.gptImageBody(object, model: model)) else {
            error(400, "无效的 JSON 请求体。"); return
        }
        forward(path: target, headers: headers, body: data)
    }

    private func forward(path: String, headers: [String: String], body: Data, contentType: String = "application/json",
                         port: Int? = nil, key: String? = nil) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port ?? configuration.corePort)" + path)!)
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 600
        for (key, value) in headers where !Self.hopHeaders.contains(key) { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("Bearer " + (key ?? configuration.coreKey), forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]; config.timeoutIntervalForRequest = 600; config.timeoutIntervalForResource = 3600
        let operations = OperationQueue(); operations.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: operations)
        task = session!.dataTask(with: request); task!.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        queue.async { [self] in
            guard !self.closed else { return }
            self.responseStarted = true
            var text = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\n"
            for (key, value) in http.allHeaderFields {
                guard let key = key as? String, !Self.hopHeaders.contains(key.lowercased()), !key.lowercased().hasPrefix("access-control-") else { continue }
                text += key + ": " + String(describing: value) + "\r\n"
            }
            text += "Transfer-Encoding: chunked\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
            self.send(Data(text.utf8))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async { [self] in
            guard !self.closed else { return }
            self.pendingBytes += data.count
            if self.pendingBytes >= 1024 * 1024, !self.suspended { dataTask.suspend(); self.suspended = true }
            var chunk = Data((String(data.count, radix: 16) + "\r\n").utf8)
            chunk.append(data); chunk.append(Data("\r\n".utf8))
            self.connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.finish(); return }
                self.pendingBytes -= data.count
                if self.suspended, self.pendingBytes < 512 * 1024 { self.suspended = false; dataTask.resume() }
            })
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError failure: Error?) {
        queue.async { [self] in
            guard !self.closed else { return }
            self.task = nil
            if let failure {
                if !self.responseStarted, let fallback = self.kiroFallback, ModelGateway.isUnreachable(failure) {
                    // Nothing reached the client yet, so the core's Kiro plugin can serve it instead.
                    self.kiroFallback = nil
                    self.session?.finishTasksAndInvalidate(); self.session = nil
                    self.forward(path: fallback.path, headers: fallback.headers, body: fallback.body)
                    return
                }
                if !self.responseStarted { self.error(502, "反代内核连接失败，请检查 BridgeDock 服务。"); return }
                // An interrupted SSE must not be reported as a successful, complete response.
                self.finish(); return
            }
            self.connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in self?.finish() })
        }
    }

    private func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in if error != nil { self?.finish() } })
    }

    private func error(_ status: Int, _ message: String) { handled = true; respond(status, object: ["error": ["message": message, "type": "bridgedock_gateway_error"]]) }
    private func respond(_ status: Int, object: [String: Any]) { respond(status, data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data()) }
    private func respond(_ status: Int, data: Data) {
        let text = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Authorization, Content-Type, X-API-Key, Anthropic-Version, Anthropic-Beta\r\n\r\n"
        connection.send(content: Data(text.utf8) + data, completion: .contentProcessed { [weak self] _ in self?.finish() })
    }

    func finish() {
        guard !closed else { return }
        closed = true; task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        connection.cancel(); completed()
    }
}
