import Foundation

/// 定时核验渠道里的模型是不是它声称的那个。
/// 不看模型自述，只看难以伪造的协议证据：响应格式、分词器算出的 token 差值、提示缓存、thinking 签名，
/// 以及（登录中转站时）站点计费记录与接口 usage 是否一致。没有一项能单独证明真伪，结论由多项合成。
enum VerificationVerdict: String, Codable {
    case trusted, suspicious, abnormal, unavailable
    var title: String {
        switch self {
        case .trusted: return "可信"
        case .suspicious: return "可疑"
        case .abnormal: return "确认异常"
        case .unavailable: return "无法检测"
        }
    }
    var symbol: String {
        switch self {
        case .trusted: return "checkmark.seal.fill"
        case .suspicious: return "exclamationmark.triangle.fill"
        case .abnormal: return "xmark.octagon.fill"
        case .unavailable: return "questionmark.circle"
        }
    }
}

enum CheckOutcome: String, Codable { case pass, warn, fail, skip }

struct VerificationCheck: Codable, Equatable, Identifiable {
    let name: String
    let outcome: CheckOutcome
    let detail: String
    var id: String { name }
}

struct VerificationRun: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var date = Date()
    var model = ""
    var wire = ""
    var checks: [VerificationCheck] = []
    var verdict: VerificationVerdict = .unavailable
    var tokenDelta: Int?
    var seconds: Double = 0
}

struct VerificationLog: Codable, Equatable {
    /// 每个模型第一次测得的分词差值；没有官方参照时，用它判断上游是否中途换了模型。
    var baselines: [String: Int] = [:]
    /// 官方渠道测得的分词差值及测量时间（7 天内复用，避免每次都花官方额度）。
    var references: [String: Int] = [:]
    var referenceDates: [String: Date] = [:]
    var runs: [VerificationRun] = []

    var lastDate: Date? { runs.first?.date }
    func latest(_ model: String) -> VerificationRun? { runs.first { $0.model == model } }

    mutating func append(_ run: VerificationRun) {
        runs.insert(run, at: 0)
        if runs.count > 60 { runs.removeLast(runs.count - 60) }
    }
}

struct VerificationLogStore {
    let directory: URL
    init(dataDirectory: URL) { directory = dataDirectory.appendingPathComponent("verification") }

    private func file(_ channelID: String) -> URL? {
        guard channelID.range(of: "^[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil else { return nil }
        return directory.appendingPathComponent(channelID + ".json")
    }

    func read(_ channelID: String) -> VerificationLog {
        guard let url = file(channelID), let data = try? Data(contentsOf: url), data.count < 4_000_000,
              let log = try? JSONDecoder().decode(VerificationLog.self, from: data) else { return VerificationLog() }
        return log
    }

    func save(_ log: VerificationLog, for channelID: String) throws {
        guard let url = file(channelID) else { return }
        try privateWrite(JSONEncoder().encode(log), to: url)
    }
}

/// 从一次非流式响应里读出的协议字段。
struct VerificationResponse {
    var status = 0
    var json: [String: Any] = [:]
    var started = Date()
    var finished = Date()

    var error: String? {
        guard !(200..<300).contains(status) else { return nil }
        let object = json["error"] as? [String: Any]
        let message = object?["message"] as? String ?? json["message"] as? String ?? json["error"] as? String ?? ""
        return "HTTP \(status)" + (message.isEmpty ? "" : " · " + String(message.prefix(200)))
    }

    var usage: [String: Any] { json["usage"] as? [String: Any] ?? [:] }
    var model: String { json["model"] as? String ?? "" }

    /// 全部输入 token。Anthropic 的 input_tokens 不含缓存读写部分，要加回来；OpenAI 的已包含。
    var promptTokens: Int? {
        if let input = Sub2API.int(usage["input_tokens"]) ?? Sub2API.int(usage["prompt_tokens"]) {
            if json["type"] as? String == "message" {
                return input + (Sub2API.int(usage["cache_read_input_tokens"]) ?? 0) + (Sub2API.int(usage["cache_creation_input_tokens"]) ?? 0)
            }
            return input
        }
        return nil
    }
    var outputTokens: Int? { Sub2API.int(usage["output_tokens"]) ?? Sub2API.int(usage["completion_tokens"]) }
    var cachedTokens: Int {
        let details = usage["input_tokens_details"] as? [String: Any] ?? usage["prompt_tokens_details"] as? [String: Any]
        return Sub2API.int(usage["cache_read_input_tokens"]) ?? Sub2API.int(details?["cached_tokens"]) ?? 0
    }
    var reasoningTokens: Int? {
        let details = usage["output_tokens_details"] as? [String: Any] ?? usage["completion_tokens_details"] as? [String: Any]
        return Sub2API.int(details?["reasoning_tokens"])
    }

    var text: String {
        if let blocks = json["content"] as? [[String: Any]] { return blocks.compactMap { $0["text"] as? String }.joined() }
        if let text = json["output_text"] as? String { return text }
        if let output = json["output"] as? [[String: Any]] {
            return output.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }.compactMap { $0["text"] as? String }.joined()
        }
        if let choices = json["choices"] as? [[String: Any]] {
            return choices.compactMap { ($0["message"] as? [String: Any])?["content"] as? String }.joined()
        }
        return ""
    }

    /// Anthropic thinking 块数与签名总长度。
    var thinking: (blocks: Int, signature: Int) {
        let blocks = (json["content"] as? [[String: Any]] ?? []).filter { ["thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }
        return (blocks.count, blocks.reduce(0) { $0 + (($1["signature"] as? String)?.count ?? ($1["data"] as? String)?.count ?? 0) })
    }
}

enum ModelVerification {
    /// 固定的长文本：约 4,500 token，超过各家提示缓存的最低长度（Claude 新模型为 4096）。
    static let filler: String = (0..<300).map { index in
        "Ledger line \(index): parcel \(index * 7919 % 10007) left depot \(index % 17) at \(index % 24):\((index * 13) % 60) carrying \(index * 37 % 997) units."
    }.joined(separator: "\n")

    static func prompt(marker: String) -> String { "Reply with exactly this token and nothing else: \(marker)" }

    /// 请求路径与请求体。base 为渠道 Base URL（Anthropic 不含 /v1，OpenAI 系含 /v1）。
    static func request(wire: WireProtocol, model: String, marker: String, long: Bool, thinking: AnthropicThinkingStyle? = nil,
                        reasoning: Bool = false, cacheKey: String) -> (path: String, body: [String: Any]) {
        let question = thinking != nil || reasoning ? "What is 17 * 23? Answer with just the number." : prompt(marker: marker)
        switch wire {
        case .anthropic:
            var content: [[String: Any]] = []
            if long { content.append(["type": "text", "text": filler, "cache_control": ["type": "ephemeral"]]) }
            content.append(["type": "text", "text": question])
            var body: [String: Any] = ["model": model, "max_tokens": thinking == nil ? 32 : 2048,
                                       "messages": [["role": "user", "content": content]]]
            switch thinking {
            case .adaptive?:
                body["thinking"] = ["type": "adaptive", "display": "summarized"]
                body["output_config"] = ["effort": "low"]
            case .budget?:
                body["thinking"] = ["type": "enabled", "budget_tokens": 1024]
            case nil: break
            }
            return ("/v1/messages", body)
        case .responses:
            var content: [[String: Any]] = []
            if long { content.append(["type": "input_text", "text": filler]) }
            content.append(["type": "input_text", "text": question])
            var body: [String: Any] = ["model": model, "max_output_tokens": 512, "store": false,
                                       "prompt_cache_key": cacheKey,
                                       "input": [["role": "user", "content": content]]]
            if reasoning { body["reasoning"] = ["effort": "low"] }
            return ("/responses", body)
        case .chat, .xai:
            let text = long ? filler + "\n\n" + question : question
            var body: [String: Any] = ["model": model, "max_tokens": 512, "messages": [["role": "user", "content": text]]]
            if reasoning { body["reasoning_effort"] = "low" }
            return ("/chat/completions", body)
        }
    }

    static func headers(wire: WireProtocol, key: String) -> [String: String] {
        var value = ["Authorization": "Bearer " + key, "Content-Type": "application/json", "Accept": "application/json"]
        if wire == .anthropic {
            value["x-api-key"] = key
            value["anthropic-version"] = "2023-06-01"
        }
        return value
    }

    // MARK: - Checks

    /// 响应是否是该协议的原生格式。字段缺失说明中间做了协议转换，常见于用别家模型冒充。
    static func protocolCheck(_ response: VerificationResponse, wire: WireProtocol, model: String, marker: String) -> VerificationCheck {
        let name = "响应格式"
        let json = response.json
        let id = json["id"] as? String ?? ""
        var problems: [String] = []
        var notes: [String] = []
        switch wire {
        case .anthropic:
            if json["type"] as? String != "message" { problems.append("type 不是 message") }
            if response.usage["input_tokens"] == nil { problems.append("缺少 usage.input_tokens") }
            if !id.hasPrefix("msg_") { notes.append("消息 ID 不是 msg_ 开头") }
        case .responses:
            if json["object"] as? String != "response" { problems.append("object 不是 response") }
            if response.usage["input_tokens"] == nil { problems.append("缺少 usage.input_tokens") }
            if !id.hasPrefix("resp_") { notes.append("响应 ID 不是 resp_ 开头") }
        case .chat, .xai:
            if json["object"] as? String != "chat.completion" { notes.append("object 不是 chat.completion") }
            if response.usage["prompt_tokens"] == nil && response.usage["input_tokens"] == nil { problems.append("缺少 usage") }
        }
        let returned = response.model
        if !returned.isEmpty && !sameModel(returned, model) { notes.append("返回模型标识为 \(returned)") }
        let text = response.text
        if !text.isEmpty && !text.contains(marker) { notes.append("没有按要求复述校验标记") }
        if !problems.isEmpty { return VerificationCheck(name: name, outcome: .fail, detail: (problems + notes).joined(separator: "；")) }
        if !notes.isEmpty { return VerificationCheck(name: name, outcome: .warn, detail: notes.joined(separator: "；")) }
        return VerificationCheck(name: name, outcome: .pass, detail: "原生 \(wire == .anthropic ? "Anthropic" : "OpenAI") 格式，模型标识一致")
    }

    /// 同一模型的日期后缀或厂商前缀不算不一致，例如 claude-x-20260101 与 claude-x、openai/gpt-x 与 gpt-x。
    static func sameModel(_ returned: String, _ requested: String) -> Bool {
        func core(_ text: String) -> String {
            var value = text.lowercased()
            if let slash = value.lastIndex(of: "/") { value = String(value[value.index(after: slash)...]) }
            value = value.replacingOccurrences(of: "-[0-9]{8}$", with: "", options: .regularExpression)
            value = value.replacingOccurrences(of: "-[0-9]{4}-[0-9]{2}-[0-9]{2}$", with: "", options: .regularExpression)
            return ModelPublishing.publicModelID(value)
        }
        return core(returned) == core(requested)
    }

    /// 长文本带来的输入 token 差值由分词器决定，换模型族就对不上；用差值可以排除站点附加系统提示的影响。
    static func tokenizerCheck(delta: Int?, reference: Int?, baseline: Int?) -> VerificationCheck {
        let name = "分词指纹"
        guard let delta else { return VerificationCheck(name: name, outcome: .warn, detail: "接口没有返回输入 token，无法比对分词器") }
        guard delta > 0 else { return VerificationCheck(name: name, outcome: .fail, detail: "加入约 4,500 token 文本后输入 token 没有增加（差值 \(delta)），usage 不是按实际输入计算的") }
        func close(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= max(3, b / 50) }
        if let reference {
            return close(delta, reference)
                ? VerificationCheck(name: name, outcome: .pass, detail: "差值 \(delta)，与官方渠道 \(reference) 一致")
                : VerificationCheck(name: name, outcome: .fail, detail: "差值 \(delta)，官方渠道为 \(reference)，分词器不同，上游很可能不是这个模型")
        }
        guard let baseline else { return VerificationCheck(name: name, outcome: .pass, detail: "差值 \(delta)，已记为基准；接入同名官方模型后可与官方比对") }
        return close(delta, baseline)
            ? VerificationCheck(name: name, outcome: .pass, detail: "差值 \(delta)，与首次基准 \(baseline) 一致（没有官方参照）")
            : VerificationCheck(name: name, outcome: .warn, detail: "差值 \(delta)，首次基准为 \(baseline)，上游可能换了模型（没有官方参照）")
    }

    static func cacheCheck(_ response: VerificationResponse?) -> VerificationCheck {
        let name = "提示缓存"
        guard let response, response.error == nil else { return VerificationCheck(name: name, outcome: .skip, detail: "重复请求失败，未检测") }
        let cached = response.cachedTokens
        return cached > 0
            ? VerificationCheck(name: name, outcome: .pass, detail: "重复请求命中缓存 \(cached) token")
            : VerificationCheck(name: name, outcome: .warn, detail: "重复约 4,500 token 的相同前缀没有命中缓存。官方接口会命中；也可能是站点关闭了缓存")
    }

    static func thinkingCheck(_ response: VerificationResponse?, wire: WireProtocol) -> VerificationCheck {
        let name = wire == .anthropic ? "thinking 签名" : "推理 token"
        guard let response else { return VerificationCheck(name: name, outcome: .skip, detail: "模型不支持思考参数，未检测") }
        if let error = response.error { return VerificationCheck(name: name, outcome: .skip, detail: "思考请求失败：" + error) }
        let answer = response.text.contains("391") ? "，答案正确" : (response.text.isEmpty ? "" : "，答案错误")
        if wire == .anthropic {
            let (blocks, signature) = response.thinking
            if blocks == 0 { return VerificationCheck(name: name, outcome: .warn, detail: "开启思考后没有返回 thinking 块" + answer) }
            if signature == 0 { return VerificationCheck(name: name, outcome: .fail, detail: "返回了 thinking 块但没有签名，不是 Anthropic 官方生成" + answer) }
            if signature < ThinkingEvidence.minimumSignatureLength {
                return VerificationCheck(name: name, outcome: .fail, detail: "thinking 签名只有 \(signature) 字符，疑似伪造" + answer)
            }
            return VerificationCheck(name: name, outcome: .pass, detail: "thinking 签名正常（\(signature) 字符）" + answer)
        }
        guard let reasoning = response.reasoningTokens else { return VerificationCheck(name: name, outcome: .skip, detail: "接口没有返回推理 token 字段" + answer) }
        return reasoning > 0
            ? VerificationCheck(name: name, outcome: .pass, detail: "推理 token \(reasoning)" + answer)
            : VerificationCheck(name: name, outcome: .warn, detail: "要求推理后推理 token 为 0，可能被换成了非推理模型" + answer)
    }

    struct SentRequest {
        let model: String
        let started: Date
        let finished: Date
        let promptTokens: Int
        let outputTokens: Int
    }

    /// 用站点计费记录核对每次请求：同模型、时间相近、输出 token 相同的记录，其输入 token 不应多于接口返回的。
    static func billingCheck(sent: [SentRequest], logs: [RelayUsageLog]) -> VerificationCheck {
        let name = "计费核对"
        guard !sent.isEmpty else { return VerificationCheck(name: name, outcome: .skip, detail: "没有可核对的请求") }
        var used = Set<Int>()
        var matched = 0
        var overcharged: [String] = []
        for request in sent {
            let candidates = logs.enumerated().filter { index, log in
                !used.contains(index) && sameModel(log.model, request.model) && log.outputTokens == request.outputTokens
                    && (log.createdAt.map { $0 >= request.started.addingTimeInterval(-60) && $0 <= request.finished.addingTimeInterval(180) } ?? false)
            }
            guard let best = candidates.min(by: { abs($0.element.promptTokens - request.promptTokens) < abs($1.element.promptTokens - request.promptTokens) }) else { continue }
            used.insert(best.offset)
            matched += 1
            // Sub2API 的 input_tokens 一般不含缓存部分；若站点按“已含缓存”记录，input_tokens 本身就等于接口值，也算一致。
            let tolerance = max(5, request.promptTokens / 20)
            let log = best.element
            if log.promptTokens > request.promptTokens + tolerance && abs(log.inputTokens - request.promptTokens) > tolerance {
                overcharged.append("接口返回 \(request.promptTokens)，计费 \(log.promptTokens)")
            }
        }
        if !overcharged.isEmpty { return VerificationCheck(name: name, outcome: .fail, detail: "站点多计输入 token：" + overcharged.joined(separator: "；")) }
        if matched == 0 { return VerificationCheck(name: name, outcome: .warn, detail: "站点计费记录里没找到这几次请求") }
        return VerificationCheck(name: name, outcome: .pass, detail: "\(matched) / \(sent.count) 次请求的计费与接口 usage 一致")
    }

    static func verdict(_ checks: [VerificationCheck]) -> VerificationVerdict {
        if checks.contains(where: { $0.outcome == .fail }) { return .abnormal }
        if checks.contains(where: { $0.outcome == .warn }) { return .suspicious }
        return checks.contains(where: { $0.outcome == .pass }) ? .trusted : .unavailable
    }

    static func marker() -> String { "BD-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased() }
}
