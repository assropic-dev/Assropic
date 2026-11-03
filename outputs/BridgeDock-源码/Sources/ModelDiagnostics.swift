import Foundation

enum ModelTestMode: String, CaseIterable, Identifiable {
    case quick, connectivity, routing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .quick: return "快速调用"
        case .connectivity: return "联通程度"
        case .routing: return "路由与能力"
        }
    }
    var detail: String {
        switch self {
        case .quick: return "发送一次简短请求，检查当前协议能否正常调用。"
        case .connectivity: return "连续发送 3 次流式请求，核验随机标记，测量成功率、首字延迟与总耗时。"
        case .routing: return "发送 3 道有标准答案的题目，核对模型返回标识，分别检查计算、逻辑与上下文提取。"
        }
    }
}

struct ModelTestProbe {
    let title: String
    let prompt: String
    var expectedJSON: String?
    var marker: String?

    static func make(for mode: ModelTestMode) -> [ModelTestProbe] {
        if mode == .quick { return [ModelTestProbe(title: "快速调用", prompt: "Reply with OK only.")] }
        if mode == .connectivity {
            return (1...3).map { index in
                let marker = "BD_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                return ModelTestProbe(title: "联通测试 \(index)", prompt: "Reply with this exact text only: \(marker)", marker: marker)
            }
        }
        let a = Int.random(in: 211...887), b = Int.random(in: 113...761), c = Int.random(in: 31...197)
        let arithmetic = ModelTestProbe(title: "整数计算", prompt: "Compute (\(a) * \(b) + \(c)) modulo 97. Return only a JSON object with one integer field named answer.", expectedJSON: "{\"answer\":\((a * b + c) % 97)}")
        let boxes = ["Amber", "Birch", "Coral", "Dune", "Elm"].shuffled()
        let logic = ModelTestProbe(title: "条件推理", prompt: "A key is in exactly one of three boxes: \(boxes[0]), \(boxes[1]), \(boxes[2]). Exactly ONE of these three statements is true. Statement 1: the key is in \(boxes[1]). Statement 2: the key is not in \(boxes[2]). Statement 3: the key is not in \(boxes[1]). Which box contains the key? Return only a JSON object with one string field named box.", expectedJSON: "{\"box\":\"\(boxes[2])\"}")
        let values = (0..<90).map { _ in String(UUID().uuidString.prefix(8)).lowercased() }
        let positions = [Int.random(in: 10...25), Int.random(in: 38...53), Int.random(in: 65...80)]
        let records = values.enumerated().map { "record_\($0.offset)=\($0.element)" }.joined(separator: "\n")
        let expected = positions.map { "\"\(values[$0])\"" }.joined(separator: ",")
        let context = ModelTestProbe(title: "上下文提取", prompt: "Read the data below. Return the exact values of \(positions.map { "record_\($0)" }.joined(separator: ", ")) in that order. Return only JSON with one field values containing an array of three strings.\n<records>\n\(records)\n</records>", expectedJSON: "{\"values\":[\(expected)]}")
        return [arithmetic, logic, context]
    }

    func grade(_ text: String) -> Bool? {
        guard let expectedJSON else { return nil }
        var answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept a single Markdown fence while keeping the actual answer strict.
        if answer.hasPrefix("```"), answer.hasSuffix("```"), let newline = answer.firstIndex(of: "\n") {
            answer = String(answer[answer.index(after: newline)...].dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let actual = try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any],
              let expected = try? JSONSerialization.jsonObject(with: Data(expectedJSON.utf8)) as? [String: Any],
              let actualData = try? JSONSerialization.data(withJSONObject: actual, options: .sortedKeys),
              let expectedData = try? JSONSerialization.data(withJSONObject: expected, options: .sortedKeys) else { return false }
        return actualData == expectedData
    }
}

struct ModelRouteExpectation {
    let publicID: String
    let coreID: String
    let source: String
    let upstreamIDs: [String]

    init(model: String, catalog: [PublishedModel], settings: AppSettings) {
        let route = catalog.first { $0.publicID == model }
        publicID = model
        coreID = route?.id ?? model
        source = route?.sourceName ?? "未在当前目录找到"
        let channel = settings.channels.first { "channel:" + $0.id == route?.sourceID }
        let mappings = channel?.models.filter { $0["alias"] == route?.modelName }.compactMap { $0["name"] } ?? []
        upstreamIDs = mappings.isEmpty ? [route?.modelName ?? model] : Array(Set(mappings)).sorted()
    }

    func finding(for returned: [String]) -> (title: String, detail: String, warning: Bool) {
        guard !returned.isEmpty else { return ("模型身份信息不足", "响应未提供可核对的 model 字段。", false) }
        let different = returned.filter { !upstreamIDs.contains($0) && $0 != publicID && $0 != coreID }
        if !different.isEmpty {
            return ("返回模型标识存在差异", "返回了 \(different.joined(separator: "、"))。请核对渠道别名、模型版本和上游路由记录。", true)
        }
        if returned.allSatisfy({ upstreamIDs.contains($0) }) {
            return ("返回标识与配置相符", "响应中的 model 与配置的上游模型一致。", false)
        }
        return ("响应回显了路由别名", "返回值包含本地请求名或路由名，尚无法据此核实上游模型。", false)
    }
}

struct ModelTestSample: Identifiable {
    let id: Int
    let probe: ModelTestProbe
    var httpStatus: Int?
    var firstTextSeconds: Double?
    var duration = 0.0
    var streaming = false
    var outputTokens: Int?
    var returnedModels: [String] = []
    var text = ""
    var error: String?
    var answerCorrect: Bool?
    var succeeded: Bool { error == nil }
}

struct ModelTestReport {
    let mode: ModelTestMode
    let model: String
    let wire: String
    let route: ModelRouteExpectation
    let plannedCount: Int
    var samples: [ModelTestSample] = []
    var finished = false
    var cancelled = false
    var successful: Int { samples.filter(\.succeeded).count }
    var returnedModels: [String] { Array(Set(samples.flatMap(\.returnedModels))).sorted() }
    var scored: [ModelTestSample] { samples.filter { $0.answerCorrect != nil } }
    var correct: Int { scored.filter { $0.answerCorrect == true }.count }
    var averageDuration: Double? {
        let values = samples.filter(\.succeeded).map(\.duration)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    var averageFirstText: Double? {
        let values = samples.filter(\.succeeded).compactMap(\.firstTextSeconds)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

/// Parses only protocol-defined response fields. Model self-descriptions are never identity evidence.
struct ModelTestPayload {
    var text = ""
    var models: Set<String> = []
    var outputTokens: Int?
    var complete = false
    var truncated = false
    var error: String?
    private var eventData: [String] = []

    mutating func line(_ line: String) throws {
        if line.isEmpty { try flushEvent(); return }
        guard line.hasPrefix("data:") else { return }
        var value = String(line.dropFirst(5))
        if value.hasPrefix(" ") { value.removeFirst() }
        eventData.append(value)
    }

    mutating func flushEvent() throws {
        guard !eventData.isEmpty else { return }
        let data = eventData.joined(separator: "\n")
        eventData.removeAll(keepingCapacity: true)
        if data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { complete = true; return }
        try consume(Data(data.utf8), streaming: true)
    }

    mutating func consume(_ data: Data, streaming: Bool) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        metadata(object)
        let type = object["type"] as? String ?? ""
        if let nested = object["message"] as? [String: Any] { metadata(nested) }
        if let response = object["response"] as? [String: Any] {
            metadata(response)
            if text.isEmpty { text = Self.outputText(response) }
        }
        if let choices = object["choices"] as? [[String: Any]], let choice = choices.first {
            let message = choice[streaming ? "delta" : "message"] as? [String: Any] ?? [:]
            text += Self.contentText(message["content"])
            if choice["finish_reason"] as? String == "length" { truncated = true }
        }
        if !streaming {
            if object["content"] != nil { text += Self.contentText(object["content"]) }
            if object["output"] != nil || object["output_text"] != nil { text += Self.outputText(object) }
            complete = object["choices"] != nil || object["content"] != nil || object["output"] != nil || object["output_text"] != nil
            if ["queued", "in_progress"].contains(object["status"] as? String ?? "") { complete = false }
        }
        switch type {
        case "content_block_delta":
            text += (object["delta"] as? [String: Any])?["text"] as? String ?? ""
        case "content_block_start":
            if let block = object["content_block"] as? [String: Any] {
                text += block["text"] as? String ?? ""
                metadata(block)
            }
        case "message_delta":
            if let delta = object["delta"] as? [String: Any] { metadata(delta) }
        case "response.output_text.delta": text += object["delta"] as? String ?? ""
        case "message_stop", "response.completed": complete = true
        case "response.incomplete": complete = true; truncated = true
        case "response.failed", "error": error = error ?? "上游返回错误事件。"
        default: break
        }
    }

    private mutating func metadata(_ object: [String: Any]) {
        if let model = object["model"] as? String, !model.isEmpty { models.insert(String(model.prefix(256))) }
        if let usage = object["usage"] as? [String: Any], let tokens = usage["output_tokens"] as? Int ?? usage["completion_tokens"] as? Int { outputTokens = tokens }
        if object["stop_reason"] as? String == "max_tokens" || object["status"] as? String == "incomplete" { truncated = true }
        if let value = object["error"], !(value is NSNull) {
            let detail = (value as? [String: Any])?["message"] as? String ?? value as? String ?? "上游返回错误。"
            error = String(detail.prefix(400))
        }
        if object["status"] as? String == "failed" { error = error ?? "上游生成失败。" }
    }

    private static func contentText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }
    private static func outputText(_ object: [String: Any]) -> String {
        if let text = object["output_text"] as? String { return text }
        return (object["output"] as? [[String: Any]] ?? []).map { contentText($0["content"]) }.joined()
    }
}

private final class ModelTestRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum ModelTestHTTP {
    static func request(baseURL: URL, key: String, model: String, wire: String, probe: ModelTestProbe, streaming: Bool) throws -> URLRequest {
        let path: String
        var body: [String: Any] = ["model": model, "stream": streaming]
        switch wire {
        case "responses":
            path = "/v1/responses"
            body["input"] = probe.prompt
            body["max_output_tokens"] = 2048
        case "anthropic", "chat":
            path = wire == "anthropic" ? "/v1/messages" : "/v1/chat/completions"
            body["messages"] = [["role": "user", "content": probe.prompt]]
            body["max_tokens"] = 2048
        default: throw BridgeError.message("不支持此测试协议。")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(streaming ? "text/event-stream, application/json" : "application/json", forHTTPHeaderField: "Accept")
        if wire == "anthropic" { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        return request
    }

    static func perform(_ request: URLRequest, probe: ModelTestProbe, index: Int) async -> ModelTestSample {
        let started = ProcessInfo.processInfo.systemUptime
        var result = ModelTestSample(id: index, probe: probe)
        var payload = ModelTestPayload()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration, delegate: ModelTestRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                result.httpStatus = http.statusCode
                result.streaming = http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
                var buffer = Data()
                var count = 0
                for try await byte in bytes {
                    try Task.checkCancellation()
                    count += 1
                    guard count <= 2 * 1024 * 1024 else { throw BridgeError.message("测试响应超过 2 MB，已停止读取。") }
                    if result.streaming && byte == 10 {
                        if buffer.last == 13 { buffer.removeLast() }
                        guard let line = String(data: buffer, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
                        try payload.line(line)
                        buffer.removeAll(keepingCapacity: true)
                        if result.firstTextSeconds == nil, !payload.text.isEmpty {
                            result.firstTextSeconds = ProcessInfo.processInfo.systemUptime - started
                        }
                    } else { buffer.append(byte) }
                }
                if result.streaming {
                    if !buffer.isEmpty {
                        try payload.line(String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .newlines))
                    }
                    try payload.flushEvent()
                    if result.firstTextSeconds == nil, !payload.text.isEmpty {
                        result.firstTextSeconds = ProcessInfo.processInfo.systemUptime - started
                    }
                } else if !buffer.isEmpty {
                    try? payload.consume(buffer, streaming: false)
                }
                if !(200..<300).contains(http.statusCode) {
                    throw BridgeError.message(httpFailure(http.statusCode) + (payload.error.map { "\n" + $0 } ?? ""))
                }
                if let error = payload.error { throw BridgeError.message(error) }
                guard payload.complete else { throw BridgeError.message("响应未完整结束，可能发生断流或返回了不兼容的数据。") }
                guard !payload.truncated else { throw BridgeError.message("输出达到上限或生成未完成，本轮无法完整验证。") }
                guard !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BridgeError.message("接口已响应，但未返回可验证的正文。") }
                if let marker = probe.marker, !payload.text.contains(marker) { throw BridgeError.message("已收到正文，但未返回本轮随机校验标记。") }
                result.answerCorrect = probe.grade(payload.text)
            } onCancel: { session.invalidateAndCancel() }
        } catch {
            result.error = Task.isCancelled ? "测试已取消。" : error.localizedDescription
        }
        result.duration = ProcessInfo.processInfo.systemUptime - started
        result.text = String(payload.text.prefix(8000))
        result.returnedModels = payload.models.sorted()
        result.outputTokens = payload.outputTokens
        return result
    }

    private static func httpFailure(_ code: Int) -> String {
        let detail: String
        switch code {
        case 401, 403: detail = "认证或模型权限受限"
        case 404: detail = "模型未发布或接口不存在"
        case 408, 504: detail = "请求超时"
        case 429: detail = "触发限流或额度不足"
        case 500...599: detail = "上游或反代服务异常"
        default: detail = "请求未成功"
        }
        return "HTTP \(code) · " + detail
    }
}
