import Foundation

// MARK: - Running checks

extension BridgeStore {
    var verificationLogStore: VerificationLogStore { VerificationLogStore(dataDirectory: dataDirectory) }

    func verificationLog(_ channelID: String) -> VerificationLog {
        if let cached = verificationLogs[channelID] { return cached }
        let log = verificationLogStore.read(channelID)
        verificationLogs[channelID] = log
        return log
    }

    /// 定时核验：同一时间只跑一个渠道，避免突发请求触发站点风控。
    func scheduleDueVerifications() {
        guard running, verifyingChannels.isEmpty else { return }
        let due = settings.channels.first { channel in
            guard channel.enabled, channel.verifyHours > 0, !channel.isKimiWork, !channel.apiKey.isEmpty else { return false }
            guard let last = verificationLog(channel.id).lastDate else { return true }
            return Date().timeIntervalSince(last) >= Double(channel.verifyHours) * 3600
        }
        guard let due else { return }
        Task { await verifyChannel(due.id) }
    }

    func verifyChannel(_ channelID: String, models: [String]? = nil) async {
        guard running, !verifyingChannels.contains(channelID),
              let channel = settings.channels.first(where: { $0.id == channelID }) else { return }
        verifyingChannels.insert(channelID)
        defer { verifyingChannels.remove(channelID) }
        let names = models ?? (channel.verifyModels.isEmpty ? Array(channel.models.prefix(1).compactMap { $0["name"] }) : channel.verifyModels)
        for model in names {
            let run = await verify(channel, model: model)
            var log = verificationLog(channelID)
            if let delta = run.tokenDelta, log.baselines[model] == nil, run.verdict != .abnormal { log.baselines[model] = delta }
            log.append(run)
            verificationLogs[channelID] = log
            try? verificationLogStore.save(log, for: channelID)
            let summary = run.checks.filter { $0.outcome == .fail || $0.outcome == .warn }.map { $0.name + "：" + $0.detail }.joined(separator: "；")
            record("模型核验 · \(channel.name) · \(model) · \(run.verdict.title)" + (summary.isEmpty ? "" : " · " + summary),
                   failed: run.verdict == .abnormal || run.verdict == .suspicious)
            if run.verdict == .abnormal, channel.verifyAutoDisable,
               var current = settings.channels.first(where: { $0.id == channelID }), current.enabled {
                current.enabled = false
                do {
                    try await saveChannel(current)
                    record("模型核验确认异常，已自动停用渠道 · \(channel.name)", failed: true)
                } catch { report(error) }
            }
        }
    }

    private func verify(_ channel: Channel, model: String) async -> VerificationRun {
        var run = VerificationRun(model: model, wire: channel.wire.rawValue)
        let began = Date()
        let marker = ModelVerification.marker()
        let cacheKey = "bridgedock-verify-" + channel.id
        let upstream: (String, [String: Any]) async -> VerificationResponse = { path, body in
            await self.upstreamCall(channel, path: path, body: body)
        }
        func send(long: Bool, thinking: AnthropicThinkingStyle? = nil, reasoning: Bool = false,
                  via call: (String, [String: Any]) async -> VerificationResponse) async -> VerificationResponse {
            let request = ModelVerification.request(wire: channel.wire, model: model, marker: marker, long: long,
                                                    thinking: thinking, reasoning: reasoning, cacheKey: cacheKey)
            return await call(request.path, request.body)
        }

        let short = await send(long: false, via: upstream)
        if let error = short.error {
            run.checks = [VerificationCheck(name: "调用", outcome: .skip, detail: redacted(error))]
            run.verdict = .unavailable
            run.seconds = Date().timeIntervalSince(began)
            return run
        }
        run.checks.append(ModelVerification.protocolCheck(short, wire: channel.wire, model: model, marker: marker))
        let long = await send(long: true, via: upstream)
        var repeated: VerificationResponse?
        if long.error == nil { repeated = await send(long: true, via: upstream) }
        if let a = short.promptTokens, let b = long.promptTokens, long.error == nil { run.tokenDelta = b - a }

        var log = verificationLog(channel.id)
        let reference = await referenceDelta(channel: channel, model: model, log: &log, marker: marker)
        verificationLogs[channel.id] = log
        run.checks.append(ModelVerification.tokenizerCheck(delta: run.tokenDelta, reference: reference, baseline: log.baselines[model]))
        run.checks.append(ModelVerification.cacheCheck(repeated))

        var thinking: VerificationResponse?
        if channel.wire == .anthropic {
            thinking = await send(long: false, thinking: .adaptive, via: upstream)
            if thinking?.status == 400 { thinking = await send(long: false, thinking: .budget, via: upstream) }
            if thinking?.status == 400 { thinking = nil }
        } else if channel.wire == .responses {
            thinking = await send(long: false, reasoning: true, via: upstream)
            if thinking?.status == 400 { thinking = nil }
        }
        if channel.wire != .chat && channel.wire != .xai { run.checks.append(ModelVerification.thinkingCheck(thinking, wire: channel.wire)) }

        if let site = relaySite(channel.relaySiteID), !site.needsLogin, channel.relayKeyID > 0 {
            let sent = [short, long, repeated, thinking].compactMap { $0 }.compactMap { response -> ModelVerification.SentRequest? in
                guard response.error == nil, let input = response.promptTokens, let output = response.outputTokens else { return nil }
                return ModelVerification.SentRequest(model: model, started: response.started, finished: response.finished,
                                                     promptTokens: input, outputTokens: output)
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if let data = try? await relayAuthorized(site, "/usage?page=1&page_size=30&api_key_id=\(channel.relayKeyID)") {
                run.checks.append(ModelVerification.billingCheck(sent: sent, logs: Sub2API.usageLogs(data)))
            }
        }
        run.checks = run.checks.map { VerificationCheck(name: $0.name, outcome: $0.outcome, detail: redacted($0.detail)) }
        run.verdict = ModelVerification.verdict(run.checks)
        run.seconds = Date().timeIntervalSince(began)
        return run
    }

    /// 官方参照：BD 里有同名模型的订阅账号时，经本地网关发同样两次请求，得到官方分词差值。7 天内复用。
    private func referenceDelta(channel: Channel, model: String, log: inout VerificationLog, marker: String) async -> Int? {
        if let value = log.references[model], let date = log.referenceDates[model], Date().timeIntervalSince(date) < 7 * 86_400 { return value }
        guard let official = availableModels.first(where: {
            $0.isEnabled && !$0.sourceID.hasPrefix("channel:") && ModelVerification.sameModel($0.modelName, model)
        }), let base = URL(string: baseURL) else { return nil }
        let local: (String, [String: Any]) async -> VerificationResponse = { path, body in
            await self.localCall(base: base, wire: channel.wire, path: path, body: body)
        }
        func send(_ long: Bool) async -> VerificationResponse {
            let request = ModelVerification.request(wire: channel.wire, model: official.publicID, marker: marker, long: long,
                                                    cacheKey: "bridgedock-reference")
            return await local(request.path, request.body)
        }
        let short = await send(false), long = await send(true)
        guard short.error == nil, long.error == nil, let a = short.promptTokens, let b = long.promptTokens, b > a else { return nil }
        log.references[model] = b - a
        log.referenceDates[model] = Date()
        return b - a
    }

    /// 发往渠道上游，经内核 api-call 以沿用渠道代理。
    private func upstreamCall(_ channel: Channel, path: String, body: [String: Any]) async -> VerificationResponse {
        var response = VerificationResponse()
        response.started = Date()
        let url = channel.baseURL + path
        do {
            let value: [String: Any] = ["method": "POST", "url": url, "proxy_url": channel.proxyURL,
                                        "header": ModelVerification.headers(wire: channel.wire, key: channel.apiKey),
                                        "data": String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)]
            let result = try await object("/v8/management/requests/api-call", method: "POST", value: value)
            response.status = result["status_code"] as? Int ?? 0
            let text = result["body"] as? String ?? ""
            response.json = (text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? ["message": String(text.prefix(200))]
        } catch {
            response.status = 0
            response.json = ["message": redacted(error.localizedDescription)]
        }
        response.finished = Date()
        return response
    }

    /// 官方参照走本机网关。
    private func localCall(base: URL, wire: WireProtocol, path: String, body: [String: Any]) async -> VerificationResponse {
        var response = VerificationResponse()
        response.started = Date()
        // 本地网关的 OpenAI 路径都在 /v1 下。
        let fullPath = wire == .anthropic ? path : "/v1" + path
        var request = URLRequest(url: base.appendingPathComponent(fullPath), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        for (name, value) in ModelVerification.headers(wire: wire, key: settings.clientKey) { request.setValue(value, forHTTPHeaderField: name) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, http) = try await session.data(for: request)
            response.status = (http as? HTTPURLResponse)?.statusCode ?? 0
            response.json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        } catch { response.json = ["message": error.localizedDescription] }
        response.finished = Date()
        return response
    }
}
