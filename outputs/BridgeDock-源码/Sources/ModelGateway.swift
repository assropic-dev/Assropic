import Foundation
import Network

/// Public loopback endpoint. The core's private key never leaves this process.
/// Model filtering is applied to both discovery and inference before any upstream request.
final class ModelGateway: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.bridgedock.model-gateway")
    private let lock = NSLock()
    private var listener: NWListener?
    private var clients: [UUID: GatewayClient] = [:]
    private var configuration = GatewayConfiguration()

    /// `coreModels` is the full core route list; image requests always use the best GPT image model in it,
    /// whatever model the client asked for.
    func update(port: Int, corePort: Int, clientKey: String, coreKey: String, catalog: [PublishedModel], coreModels: [String] = []) {
        lock.lock()
        configuration = GatewayConfiguration(port: port, corePort: corePort, clientKey: clientKey, coreKey: coreKey,
                                             catalog: catalog.filter(\.isEnabled), imageModel: Self.preferredImageModel(coreModels))
        lock.unlock()
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
        do {
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
        } catch { stop(); throw error }
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

private struct GatewayConfiguration {
    var port = 18417
    var corePort = 18419
    var clientKey = ""
    var coreKey = ""
    var catalog: [PublishedModel] = []
    var imageModel: String?
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
    private var continueSent = false
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var pendingBytes = 0
    private var suspended = false
    private let maximumBody = 32 * 1024 * 1024
    private static let inferencePaths: Set<String> = ["/v1/chat/completions", "/v1/completions", "/v1/responses", "/v1/responses/compact", "/v1/messages", "/v1/messages/count_tokens", "/v1/embeddings"]
    private static let imagePaths: Set<String> = ["/v1/images/generations", "/v1/images/edits"]
    private static let hopHeaders: Set<String> = ["connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade", "host", "content-length", "authorization", "x-api-key", "accept-encoding", "expect"]

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
            respond(200, object: ["object": "list", "data": configuration.catalog.map(modelJSON)])
            return
        }
        if method == "GET", path.hasPrefix("/v1/models/") {
            // URLComponents.path has already decoded percent escapes once.
            let id = String(path.dropFirst("/v1/models/".count))
            guard let model = configuration.catalog.first(where: { $0.publicID == id }) else { error(404, "模型未开放。"); return }
            respond(200, object: modelJSON(model)); return
        }
        if Self.imagePaths.contains(path) { forwardImage(method: method, target: target, headers: headers, body: body); return }
        guard method == "POST", Self.inferencePaths.contains(path) else { error(405, "该接口不支持此方法。"); return }
        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let model = object["model"] as? String else { error(400, "请提供 JSON model 字段。"); return }
        guard let route = configuration.catalog.first(where: { $0.publicID == model }) else { error(404, "该模型未开放或名称已更新，请刷新模型列表。"); return }
        object["model"] = route.id
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { error(400, "无效的 JSON 请求体。"); return }
        forward(path: target, headers: headers, body: data)
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

    private func modelJSON(_ model: PublishedModel) -> [String: Any] {
        var value = model.metadata
        value["id"] = model.publicID
        value["object"] = "model"
        value["created"] = value["created"] ?? 0
        value["owned_by"] = model.sourceName
        return value
    }

    private func forwardImage(method: String, target: String, headers: [String: String], body: Data) {
        guard method == "POST" else { error(405, "该接口不支持此方法。"); return }
        guard let model = configuration.imageModel else {
            error(503, "未找到可用的 GPT 生图模型，请先在订阅账号中连接 GPT / Codex 登录。"); return
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

    private func forward(path: String, headers: [String: String], body: Data, contentType: String = "application/json") {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(configuration.corePort)" + path)!)
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 600
        for (key, value) in headers where !Self.hopHeaders.contains(key) { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("Bearer " + configuration.coreKey, forHTTPHeaderField: "Authorization")
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
            if failure != nil {
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
