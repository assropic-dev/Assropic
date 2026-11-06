import Foundation

enum ModelTestMode: String, CaseIterable, Identifiable {
    case quick, connectivity, reasoning, longContext
    var id: String { rawValue }
    var title: String {
        switch self {
        case .quick: return "快速调用"
        case .connectivity: return "联通程度"
        case .reasoning: return "降智检测"
        case .longContext: return "长上下文"
        }
    }
    var detail: String {
        switch self {
        case .quick: return "发送一次简短请求，检查当前协议能否正常调用。"
        case .connectivity: return "连续发送 3 次流式请求，核验随机标记，测量成功率、首字延迟与总耗时。"
        case .reasoning: return "按指定推理强度发送 3 道随机生成的糖果抽屉难题，统计正确率与推理 token；Anthropic 协议同时核对 thinking 签名，并核对返回模型标识。"
        case .longContext: return "按模型声明的上限，从小到大逐档做大海捞针（每档填到约 90%），任一档失败即停止。通过的档位会成为 Cursor 中可选的上下文。会消耗大量输入 token。"
        }
    }
    var summary: String {
        switch self {
        case .quick: return "确认能否正常调用"
        case .connectivity: return "成功率与首字延迟"
        case .reasoning: return "答题正确率与路由"
        case .longContext: return "实测可用上下文"
        }
    }
    var cost: String {
        switch self {
        case .quick: return "1 次请求"
        case .connectivity: return "3 次流式请求"
        case .reasoning: return "3 道题 · 较慢"
        case .longContext: return "大量输入 token"
        }
    }
    var symbol: String {
        switch self {
        case .quick: return "bolt"
        case .connectivity: return "antenna.radiowaves.left.and.right"
        case .reasoning: return "brain"
        case .longContext: return "doc.text.magnifyingglass"
        }
    }
    var streaming: Bool { self == .connectivity }
    var stopsOnFailure: Bool { self == .longContext }
}

/// 档位 ID 原样取自上游（low / high / max / xhigh …），不再限定固定集合。
struct ModelReasoningEffort: RawRepresentable, Hashable, Identifiable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let unset = Self(rawValue: "unset")
    static let low = Self(rawValue: "low")
    static let medium = Self(rawValue: "medium")
    static let high = Self(rawValue: "high")
    static let allCases: [Self] = [.unset, .low, .medium, .high]
    var id: String { rawValue }
    var title: String { self == .unset ? "不指定" : rawValue }
}

struct ModelTestProbe {
    let title: String
    let prompt: String
    var expectedJSON: String?
    var marker: String?
    var maxTokens = 2048
    var timeout: TimeInterval = 120
    var usesEffort = false
    var estimatedInputTokens: Int?
    /// 长上下文检测中本题验证的上下文档位。
    var contextTier: Int?

    /// `contextLimit` 为所选供应商声明的上下文上限；未知时只测 32K、128K 两档。
    static func make(for mode: ModelTestMode, contextLimit: Int? = nil) -> [ModelTestProbe] {
        switch mode {
        case .quick:
            return [ModelTestProbe(title: "快速调用", prompt: "Reply with OK only.")]
        case .connectivity:
            return (1...3).map { index in
                let marker = "BD_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                return ModelTestProbe(title: "联通测试 \(index)", prompt: "Reply with this exact text only: \(marker)", marker: marker)
            }
        case .reasoning:
            return (1...3).map { candy(index: $0) }
        case .longContext:
            let tiers = contextLimit.map(ModelPublishing.contextBudgets) ?? [32_768, 131_072]
            return tiers.map { tier in
                var probe = needle(tokens: tier * 9 / 10, title: "上下文 " + ModelPublishing.tokenLabel(tier))
                probe.contextTier = tier
                probe.timeout = max(300, Double(tier) / 1000)
                return probe
            }
        }
    }

    /// Randomized variant of the candy pigeonhole puzzle from haowang02/codex-candy-eval (original answer 21).
    static func candy(index: Int, round: [Int]? = nil, star: [Int]? = nil, flavors: [String]? = nil) -> ModelTestProbe {
        let names = flavors ?? Array(["苹果", "桃子", "西瓜", "葡萄", "橙子", "草莓", "柠檬"].shuffled().prefix(3))
        let round = round ?? (0..<3).map { _ in Int.random(in: 4...12) }
        let star = star ?? (0..<3).map { _ in Int.random(in: 3...10) }
        let cell = { (value: Int) in String(repeating: " ", count: value < 10 ? 6 : 5) + String(value) }
        let prompt = """
        不使用任何外部工具回答以下问题：

        在一个黑色的袋子里放有三种口味的糖果，每种糖果有两种不同的形状（圆形和五角星形，不同的形状靠手感可以分辨）。现已知不同口味的糖和不同形状的数量统计如下表。参赛者需要在活动前决定摸出的糖果数目，那么，最少取出多少个糖果才能保证手中同时拥有不同形状的\(names[0])味和\(names[1])味的糖？（同时手中有圆形\(names[0])味匹配五角星\(names[1])味糖果，或者有圆形\(names[1])味匹配五角星\(names[0])味糖果都满足要求）

                \(names.map { $0 + "味" }.joined(separator: "  "))
        圆形    \(round.map(cell).joined())
        五角星形\(star.map(cell).joined())

        最终只返回一个 JSON 对象，包含一个整数字段 answer。
        """
        return ModelTestProbe(title: "糖果难题 \(index)", prompt: prompt,
                              expectedJSON: "{\"answer\":\(candyAnswer(round: round, star: star))}",
                              maxTokens: 32_000, timeout: 600, usesEffort: true)
    }

    /// Shapes are distinguishable, so the player picks R round and S star candies; the bag picks flavors adversarially.
    /// Index 0 and 1 are the two target flavors, index 2 is the filler flavor.
    static func candyAnswer(round: [Int], star: [Int]) -> Int {
        var best = Int.max
        for r in 0...round.reduce(0, +) {
            for s in 0...star.reduce(0, +) where r + s < best {
                let noRoundEither = r <= round[2]
                let noFirstFlavor = r <= round[1] + round[2] && s <= star[1] + star[2]
                let noSecondFlavor = r <= round[0] + round[2] && s <= star[0] + star[2]
                let noStarEither = s <= star[2]
                if !(noRoundEither || noFirstFlavor || noSecondFlavor || noStarEither) { best = r + s }
            }
        }
        return best
    }

    /// Needle-in-a-haystack at roughly 10%, 50% and 90% depth. One record line is about 10 tokens.
    static func needle(tokens: Int, title: String) -> ModelTestProbe {
        let count = tokens / 10
        let values = (0..<count).map { _ in String(UUID().uuidString.prefix(8)).lowercased() }
        let positions = [count / 10, count / 2, count * 9 / 10].map { $0 + Int.random(in: -count / 20...count / 20) }
        let records = values.enumerated().map { "record_\($0.offset)=\($0.element)" }.joined(separator: "\n")
        let expected = positions.map { "\"\(values[$0])\"" }.joined(separator: ",")
        let prompt = "Read the data below. Return the exact values of \(positions.map { "record_\($0)" }.joined(separator: ", ")) in that order. Return only JSON with one field values containing an array of three strings.\n<records>\n\(records)\n</records>"
        return ModelTestProbe(title: title, prompt: prompt, expectedJSON: "{\"values\":[\(expected)]}",
                              timeout: 300, estimatedInputTokens: tokens)
    }

    func grade(_ text: String) -> Bool? {
        guard let expectedJSON else { return nil }
        var answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept a single Markdown fence while keeping the actual answer strict.
        if answer.hasPrefix("```"), answer.hasSuffix("```"), let newline = answer.firstIndex(of: "\n") {
            answer = String(answer[answer.index(after: newline)...].dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let expected = try? JSONSerialization.jsonObject(with: Data(expectedJSON.utf8)) as? [String: Any],
              let expectedData = try? JSONSerialization.data(withJSONObject: expected, options: .sortedKeys),
              let actual = Self.finalObject(answer),
              let actualData = try? JSONSerialization.data(withJSONObject: actual, options: .sortedKeys) else { return false }
        return actualData == expectedData
    }

    /// The whole answer as JSON, or else the trailing JSON object after a worked solution.
    private static func finalObject(_ text: String) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { return object }
        guard let end = text.lastIndex(of: "}") else { return nil }
        var start = text[..<end].lastIndex(of: "{")
        while let index = start {
            if let object = try? JSONSerialization.jsonObject(with: Data(text[index...end].utf8)) as? [String: Any] { return object }
            start = text[..<index].lastIndex(of: "{")
        }
        return nil
    }
}

enum ThinkingEvidence: Equatable {
    case notRequested, missing, unsigned, shortSignature(Int), signed(Int)
    static let minimumSignatureLength = 50
    var summary: String {
        switch self {
        case .notRequested: return "未请求 thinking"
        case .missing: return "未返回 thinking 块"
        case .unsigned: return "有 thinking 块但无签名"
        case .shortSignature(let length): return "签名过短（\(length) 字符）"
        case .signed(let length): return "签名正常（\(length) 字符）"
        }
    }
    var warning: Bool { self != .notRequested && !isSigned }
    var isSigned: Bool { if case .signed = self { return true }; return false }
}

struct ModelRouteExpectation {
    let publicID: String
    let coreID: String
    let source: String
    let upstreamIDs: [String]

    init(model: String, catalog: [PublishedModel], settings: AppSettings, effort: String? = nil, provider: String? = nil) {
        let candidates = catalog.filter { $0.publicID == model }
        let route = candidates.first { $0.sourceID == provider } ?? candidates.first { $0.isEnabled } ?? candidates.first
        publicID = model
        coreID = (try? route?.cursorRoute?.modelID(effort: effort)) ?? route?.id ?? model
        source = route?.sourceName ?? "未在当前目录找到"
        let channel = settings.channels.first { "channel:" + $0.id == route?.sourceID }
        let mappings = channel?.models.filter { $0["alias"] == route?.modelName }.compactMap { $0["name"] } ?? []
        if route?.cursorRoute != nil {
            upstreamIDs = [coreID.split(separator: "/", maxSplits: 1).last.map(String.init) ?? coreID]
        } else {
            upstreamIDs = mappings.isEmpty ? [route?.modelName ?? model] : Array(Set(mappings)).sorted()
        }
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
    var reasoningTokens: Int?
    var inputTokens: Int?
    var thinking = ThinkingEvidence.notRequested
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
    var effort = ModelReasoningEffort.unset
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
    var averageReasoningTokens: Int? {
        let values = samples.filter(\.succeeded).compactMap(\.reasoningTokens)
        return values.isEmpty ? nil : values.reduce(0, +) / values.count
    }
    var thinkingSamples: [ModelTestSample] { samples.filter { $0.succeeded && $0.thinking != .notRequested } }
}

/// Parses only protocol-defined response fields. Model self-descriptions are never identity evidence.
struct ModelTestPayload {
    var text = ""
    var models: Set<String> = []
    var outputTokens: Int?
    var reasoningTokens: Int?
    var inputTokens: Int?
    var thinkingBlocks = 0
    var signature = ""
    var complete = false
    var truncated = false
    var error: String?
    private var eventData: [String] = []

    func thinking(requested: Bool) -> ThinkingEvidence {
        guard requested else { return .notRequested }
        if thinkingBlocks == 0 { return .missing }
        if signature.isEmpty { return .unsigned }
        return signature.count < ThinkingEvidence.minimumSignatureLength ? .shortSignature(signature.count) : .signed(signature.count)
    }

    private mutating func thinkingBlock(_ block: [String: Any]) {
        guard ["thinking", "redacted_thinking"].contains(block["type"] as? String ?? "") else { return }
        thinkingBlocks += 1
        signature += block["signature"] as? String ?? ""
    }

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
            (object["content"] as? [[String: Any]] ?? []).forEach { thinkingBlock($0) }
            if object["content"] != nil { text += Self.contentText(object["content"]) }
            if object["output"] != nil || object["output_text"] != nil { text += Self.outputText(object) }
            complete = object["choices"] != nil || object["content"] != nil || object["output"] != nil || object["output_text"] != nil
            if ["queued", "in_progress"].contains(object["status"] as? String ?? "") { complete = false }
        }
        switch type {
        case "content_block_delta":
            let delta = object["delta"] as? [String: Any] ?? [:]
            text += delta["text"] as? String ?? ""
            signature += delta["signature"] as? String ?? ""
        case "content_block_start":
            if let block = object["content_block"] as? [String: Any] {
                text += block["text"] as? String ?? ""
                thinkingBlock(block)
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
        if let usage = object["usage"] as? [String: Any] {
            if let tokens = usage["output_tokens"] as? Int ?? usage["completion_tokens"] as? Int { outputTokens = tokens }
            if let tokens = usage["input_tokens"] as? Int ?? usage["prompt_tokens"] as? Int { inputTokens = tokens }
            let details = usage["output_tokens_details"] as? [String: Any] ?? usage["completion_tokens_details"] as? [String: Any]
            if let tokens = details?["reasoning_tokens"] as? Int { reasoningTokens = tokens }
        }
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

enum AnthropicThinkingStyle {
    /// Opus 4.7 and later reject budget thinking and need adaptive thinking with output_config.effort.
    case adaptive, budget
}

enum ModelTestHTTP {
    static let thinkingBudget = 16_000

    static func request(baseURL: URL, key: String, model: String, wire: String, probe: ModelTestProbe, streaming: Bool,
                        effort: ModelReasoningEffort = .unset, thinking: AnthropicThinkingStyle = .adaptive,
                        provider: String? = nil) throws -> URLRequest {
        let path: String
        var body: [String: Any] = ["model": model, "stream": streaming]
        let effortValue = probe.usesEffort && effort != .unset ? effort.rawValue : nil
        switch wire {
        case "responses":
            path = "/v1/responses"
            body["input"] = probe.prompt
            body["max_output_tokens"] = probe.maxTokens
            if let effortValue { body["reasoning"] = ["effort": effortValue] }
        case "chat":
            path = "/v1/chat/completions"
            body["messages"] = [["role": "user", "content": probe.prompt]]
            body["max_tokens"] = probe.maxTokens
            if let effortValue { body["reasoning_effort"] = effortValue }
        case "anthropic":
            path = "/v1/messages"
            body["messages"] = [["role": "user", "content": probe.prompt]]
            body["max_tokens"] = probe.maxTokens
            if probe.usesEffort {
                switch thinking {
                case .adaptive:
                    body["thinking"] = ["type": "adaptive", "display": "summarized"]
                    if let effortValue { body["output_config"] = ["effort": effortValue] }
                case .budget:
                    body["thinking"] = ["type": "enabled", "budget_tokens": min(thinkingBudget, probe.maxTokens / 2)]
                }
            }
        default: throw BridgeError.message("不支持此测试协议。")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: probe.timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(streaming ? "text/event-stream, application/json" : "application/json", forHTTPHeaderField: "Accept")
        if wire == "anthropic" { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        if let provider, !provider.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: [["id": "provider", "value": provider]]),
           let header = String(data: data, encoding: .utf8)?.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            request.setValue(header, forHTTPHeaderField: "X-BridgeDock-Parameters")
        }
        return request
    }

    static func perform(_ request: URLRequest, probe: ModelTestProbe, index: Int) async -> ModelTestSample {
        let started = ProcessInfo.processInfo.systemUptime
        var result = ModelTestSample(id: index, probe: probe)
        var payload = ModelTestPayload()
        let thinkingRequested = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["thinking"] != nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = probe.timeout
        configuration.timeoutIntervalForResource = probe.timeout
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
                    guard count <= 8 * 1024 * 1024 else { throw BridgeError.message("测试响应超过 8 MB，已停止读取。") }
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
        result.reasoningTokens = payload.reasoningTokens
        result.inputTokens = payload.inputTokens
        result.thinking = payload.thinking(requested: thinkingRequested)
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
