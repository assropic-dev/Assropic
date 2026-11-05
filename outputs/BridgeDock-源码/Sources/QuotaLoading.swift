import Foundation
import CryptoKit

extension BridgeStore {
    var quotaTargets: [QuotaTarget] {
        accounts.map(QuotaTarget.init) + settings.channels.map(QuotaTarget.init)
    }

    func refreshQuotas(force: Bool = false, only id: String? = nil) async {
        guard running, !quotaRefreshing else { return }
        quotaRefreshing = true
        defer { quotaRefreshing = false }
        let targets = quotaTargets
        let currentIDs = Set(targets.map(\.id))
        quotaStates = quotaStates.filter { currentIDs.contains($0.key) }
        let pending = targets.filter { target in
            if let id, id != target.id { return false }
            if !target.queryAvailable { return false }
            let state = quotaStates[target.id]
            if state?.loading == true && state?.fingerprint == target.fingerprint { return false }
            if state?.fingerprint != target.fingerprint { return true }
            return force || Date().timeIntervalSince(state?.attemptedAt ?? .distantPast) >= 300
        }
        let generation = quotaGeneration
        // Three accounts at a time keeps both the local management API and providers responsive.
        for offset in stride(from: 0, to: pending.count, by: 3) {
            guard running, generation == quotaGeneration else { return }
            let batch = pending[offset..<min(offset + 3, pending.count)]
            await withTaskGroup(of: Void.self) { group in
                for target in batch {
                    group.addTask { await self.loadQuota(target, generation: generation) }
                }
            }
        }
    }

    private func loadQuota(_ target: QuotaTarget, generation: Int) async {
        guard generation == quotaGeneration, running else { return }
        if quotaStates[target.id]?.fingerprint != target.fingerprint { quotaStates[target.id] = QuotaState(fingerprint: target.fingerprint) }
        guard quotaStates[target.id]?.loading != true else { return }
        quotaStates[target.id]?.loading = true
        quotaStates[target.id]?.attemptedAt = Date()
        let result: Result<QuotaSnapshot, Error>
        do {
            var snapshot: QuotaSnapshot
            if let account = target.account { snapshot = try await fetchAccountQuota(account) }
            else if let channel = target.channel { snapshot = try await fetchChannelQuota(channel) }
            else { return }
            guard QuotaParser.hasValues(snapshot) else {
                throw BridgeError.message("接口没有返回可识别的余额或额度数值。请查看服务商账户页，或检查余额接口类型。")
            }
            snapshot.fetchedAt = Date()
            result = .success(snapshot)
        } catch { result = .failure(error) }
        guard generation == quotaGeneration,
              quotaTargets.contains(where: { $0.id == target.id && $0.fingerprint == target.fingerprint }) else { return }
        quotaStates[target.id]?.loading = false
        switch result {
        case .success(let snapshot):
            quotaStates[target.id]?.snapshot = snapshot
            quotaStates[target.id]?.error = nil
        case .failure(let error):
            quotaStates[target.id]?.error = redacted(error.localizedDescription)
        }
    }

    private func quotaCall(_ url: String, authIndex: String? = nil, headers: [String: String], proxy: String = "") async throws -> [String: Any] {
        var body: [String: Any] = ["method": "GET", "url": url, "header": headers, "proxy_url": proxy]
        if let authIndex { body["auth_index"] = authIndex }
        let data = try await request("/v8/management/requests/api-call", method: "POST", body: jsonData(body), timeout: 30)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = response["status_code"] as? Int else { throw BridgeError.message("余额接口没有返回有效响应。") }
        guard (200..<300).contains(code) else {
            let reason: String
            switch code {
            case 401, 403: reason = "授权过期、权限不足或该 Key 不支持额度查询，请重新授权或查看服务商账户页。"
            case 404: reason = "服务商没有提供这个余额接口，请在渠道配置中选择适用的查询类型。"
            case 429: reason = "服务商限制查询频率，稍后刷新。"
            default: reason = "服务商额度接口暂时无法访问。"
            }
            throw BridgeError.message("HTTP \(code) · " + reason)
        }
        guard let text = response["body"] as? String, let bytes = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw BridgeError.message("服务商返回了无法识别的额度格式。")
        }
        let hasError = payload["error"] as? Bool == true || QuotaParser.string(payload["error"]) != nil || payload["error"] is [String: Any]
        if payload["success"] as? Bool == false || payload["status"] as? Bool == false || hasError {
            throw BridgeError.message("服务商拒绝了额度查询，请检查当前授权或余额接口配置。")
        }
        return payload
    }

    private func credentialMetadata(_ account: Account) async throws -> [String: Any] {
        guard !account.runtimeOnly else { throw BridgeError.message("此内存凭据没有可读取的账户区域信息，暂时无法查询额度。") }
        let data = try await request("/v8/management/credentials/download?name=" + Self.query(account.name), timeout: 10)
        guard let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BridgeError.message("无法读取账户的区域信息。") }
        return metadata
    }

    private func fetchAccountQuota(_ account: Account) async throws -> QuotaSnapshot {
        guard !account.authIndex.isEmpty else { throw BridgeError.message("本地内核未返回这个账号的 auth_index，请刷新账号列表。") }
        var headers = ["Authorization": "Bearer $TOKEN$", "Accept": "application/json"]
        var snapshot: QuotaSnapshot
        let provider: String
        switch account.provider.lowercased() {
        case "anthropic": provider = "claude"
        case "gpt", "chatgpt": provider = "codex"
        case "grok": provider = "xai"
        case "zcode-bigmodel", "zcode-zai", "zai": provider = "zcode"
        default: provider = account.provider.lowercased()
        }
        switch provider {
        case "claude":
            headers["anthropic-beta"] = "oauth-2025-04-20"
            headers["User-Agent"] = "claude-cli/2.1.280 (external, cli)"
            snapshot = QuotaParser.claude(try await quotaCall("https://api.anthropic.com/api/oauth/usage", authIndex: account.authIndex, headers: headers))
            if let profile = try? await quotaCall("https://api.anthropic.com/api/oauth/profile", authIndex: account.authIndex, headers: headers) {
                let organization = profile["organization"] as? [String: Any] ?? [:]
                let user = profile["account"] as? [String: Any] ?? [:]
                snapshot.plan = QuotaParser.string(organization["rate_limit_tier"] ?? organization["organization_type"])
                let planNames = ["default_claude_max_20x": "Claude Max 20x", "default_claude_max_5x": "Claude Max 5x", "claude_team": "Claude Team"]
                if let plan = snapshot.plan, let name = planNames[plan] { snapshot.plan = name }
                if snapshot.plan == nil {
                    if user["has_claude_max"] as? Bool == true { snapshot.plan = "Claude Max" }
                    else if user["has_claude_pro"] as? Bool == true { snapshot.plan = "Claude Pro" }
                }
            } else { snapshot.notes.append("套餐资料暂时无法读取，额度数据已单独保留。") }
        case "codex":
            if !account.accountID.isEmpty { headers["ChatGPT-Account-Id"] = account.accountID }
            headers["User-Agent"] = "codex-tui/0.149.1"
            snapshot = QuotaParser.codex(try await quotaCall("https://chatgpt.com/backend-api/wham/usage", authIndex: account.authIndex, headers: headers))
            snapshot.plan = snapshot.plan ?? account.planName
            if let until = QuotaParser.date(account.subscriptionUntil) {
                snapshot.details.append(QuotaDetail(label: "订阅有效期（凭据声明）", value: until.formatted(date: .abbreviated, time: .shortened)))
            }
        case "kimi", "kimi-ai":
            let metadata = try await credentialMetadata(account)
            let domain = QuotaParser.string(metadata["domain"])?.lowercased()
            let host = URL(string: metadata["base_url"] as? String ?? metadata["base-url"] as? String ?? "")?.host
            let international: Bool
            if let domain { international = ["ai", "kimi-ai", "kimi.ai"].contains(domain) || domain.hasSuffix(".kimi.ai") }
            else if let host { international = host == "kimi.ai" || host.hasSuffix(".kimi.ai") }
            else { international = (metadata["type"] as? String ?? account.provider) == "kimi-ai" }
            let base = international ? "https://api.kimi.ai/coding/v1" : "https://api.kimi.com/coding/v1"
            snapshot = QuotaParser.kimi(try await quotaCall(base + "/usages", authIndex: account.authIndex, headers: headers))
            if let profile = try? await quotaCall(base + "/me", authIndex: account.authIndex, headers: headers) { snapshot.plan = QuotaParser.string(profile["user_level_name"]) }
        case "zcode":
            snapshot = try await fetchZCodeQuota(account)
        case "xai", "grok":
            headers["x-xai-token-auth"] = "xai-grok-cli"
            headers["x-grok-client-version"] = "1.0.46"
            headers["User-Agent"] = "grok-pager/1.0.46 grok-shell/1.0.46 (macos; aarch64)"
            snapshot = QuotaSnapshot(source: "Grok 订阅账单接口")
            for (suffix, label) in [("/v1/billing?format=credits", "本周订阅额度"), ("/v1/billing", "月度账单")] {
                do {
                    let payload = try await quotaCall("https://cli-chat-proxy.grok.com" + suffix, authIndex: account.authIndex, headers: headers)
                    let part = QuotaParser.xai(payload, label: label)
                    let existing = Set(snapshot.metrics.map(\.title))
                    snapshot.metrics += part.metrics.filter { !existing.contains($0.title) }
                } catch { snapshot.notes.append(label + " · " + error.localizedDescription) }
            }
            if let profile = try? await quotaCall("https://cli-chat-proxy.grok.com/v1/user?include=subscription", authIndex: account.authIndex, headers: headers) {
                snapshot.plan = QuotaParser.string(profile["subscriptionTier"] ?? profile["subscription_tier"])
            }
            if !QuotaParser.hasValues(snapshot) { throw BridgeError.message(snapshot.notes.first ?? "Grok 当前授权未提供余额查询。") }
        case "kiro":
            let metadata = try await credentialMetadata(account)
            // Kiro keeps tokens in plugin storage, outside the runtime metadata
            // read by the core's generic $TOKEN$ substitution.
            let token = metadata["accessToken"] as? String ?? metadata["access_token"] as? String ?? ""
            guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else {
                throw BridgeError.message("Kiro 凭据缺少可用令牌，请刷新凭据或重新授权。")
            }
            headers["Authorization"] = "Bearer " + token
            let region = metadata["region"] as? String ?? metadata["idcRegion"] as? String ?? "us-east-1"
            guard region.range(of: "^[a-z]{2}(?:-gov)?-[a-z]+-[0-9]+$", options: .regularExpression) != nil else { throw BridgeError.message("Kiro 账户区域无效，无法查询额度。") }
            var url = URLComponents(string: "https://q.\(region).amazonaws.com/getUsageLimits")!
            url.queryItems = [URLQueryItem(name: "isEmailRequired", value: "true"), URLQueryItem(name: "origin", value: "AI_EDITOR"), URLQueryItem(name: "resourceType", value: "AGENTIC_REQUEST")]
            if (metadata["authMethod"] as? String)?.lowercased() == "social", let arn = metadata["profileArn"] as? String {
                url.queryItems?.append(URLQueryItem(name: "profileArn", value: arn))
            }
            let identity = QuotaParser.string(metadata["profileArn"]) ?? QuotaParser.string(metadata["clientId"]) ?? "KIRO_DEFAULT_MACHINE"
            let machineID = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            headers["x-amz-user-agent"] = "aws-sdk-js/1.0.34 KiroIDE-0.11.63-" + machineID
            headers["User-Agent"] = "aws-sdk-js/1.0.34 ua/2.1 os/other lang/js md/nodejs#20.11.0 api/codewhispererstreaming#1.0.34 m/E KiroIDE-0.11.63-" + machineID
            headers["amz-sdk-invocation-id"] = UUID().uuidString
            headers["amz-sdk-request"] = "attempt=1; max=1"
            snapshot = QuotaParser.kiro(try await quotaCall(url.string!, authIndex: account.authIndex, headers: headers))
        default:
            throw BridgeError.message("\(account.provider) 暂未提供可用的额度适配，请在服务商账户页查看。")
        }
        let statusNames = ["ready": "可用", "active": "正常", "error": "异常", "disabled": "已停用"]
        snapshot.details.append(QuotaDetail(label: "账号状态", value: account.disabled ? "已停用" : statusNames[account.status] ?? account.status))
        return snapshot
    }

    private func fetchZCodeQuota(_ account: Account) async throws -> QuotaSnapshot {
        // The plugin owns ZCode session storage; the core's generic $TOKEN$
        // substitution cannot supply its Coding Plan key or gift JWT.
        var normalized: [String: Any] = [:]
        var pluginFailed = false
        do {
            normalized = try await object("/v0/management/quota/fetch", method: "POST",
                                          value: ["auth_index": account.authIndex])
        } catch { pluginFailed = true }
        var snapshot = QuotaParser.zcode(normalized)
        let groups = normalized["groups"] as? [[String: Any]] ?? []
        let codingGroups = groups.enumerated().filter {
            ($0.element["displayName"] ?? $0.element["display_name"]) as? String == "GLM Coding Plan"
        }
        let modelWindows = Set(codingGroups.flatMap { group in
            (group.element["buckets"] as? [[String: Any]] ?? []).compactMap { bucket -> String? in
                guard let window = bucket["window"] as? String, ["5h", "Weekly"].contains(window),
                      let ratio = QuotaParser.percent(bucket["remainingFraction"] ?? bucket["remaining_fraction"]), ratio <= 1 else { return nil }
                return window
            }
        })
        // Plugin 0.2.0 omits the newer CREDIT_LIMIT windows. Read those from
        // the same vendor endpoint, keeping gift balances and reset counts.
        if !modelWindows.isSuperset(of: ["5h", "Weekly"]) {
            do {
                let metadata = try await credentialMetadata(account)
                if let query = try ZCodeCodingPlanRequest(metadata: metadata) {
                    let payload = try await quotaCall(query.url, authIndex: account.authIndex,
                                                      headers: query.headers, proxy: query.proxyURL)
                    let coding = QuotaParser.balance(payload, mode: .zhipu)
                    guard QuotaParser.hasValues(coding) else {
                        throw BridgeError.message("Coding Plan 接口未返回可识别的额度。")
                    }
                    let replacedPrefixes = codingGroups.map { "zcode-\($0.offset)-" }
                    snapshot.metrics.removeAll { metric in replacedPrefixes.contains { metric.id.hasPrefix($0) } }
                    snapshot.metrics.insert(contentsOf: coding.metrics, at: 0)
                    snapshot.plan = snapshot.plan ?? QuotaParser.string(metadata["plan"]) ?? coding.plan
                    snapshot.details.append(QuotaDetail(label: "Coding Plan 查询来源", value: URL(string: query.url)?.host ?? ""))
                }
            } catch {
                snapshot.notes.append("Coding Plan 额度暂时无法读取，请稍后刷新或重新授权；已读到的赠送额度单独保留。")
            }
        }
        if pluginFailed {
            snapshot.notes.append("ZCode 赠送额度暂时无法读取，请稍后刷新或重新授权。")
        }
        guard QuotaParser.hasValues(snapshot) else {
            throw BridgeError.message("ZCode 未返回可用的套餐或赠送额度，请稍后刷新；如持续失败，请重新授权并检查官网套餐状态。")
        }
        return snapshot
    }

    private func fetchChannelQuota(_ channel: Channel) async throws -> QuotaSnapshot {
        if channel.isKimiWork {
            return QuotaParser.kimiWork(try await kimiWorkQuota(channel))
        }
        guard let base = URLComponents(string: channel.baseURL), let host = base.host?.lowercased() else { throw BridgeError.message("请先配置有效的服务商地址。") }
        let mode = channel.effectiveBalanceMode
        var parts = base
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        guard let origin = parts.string else { throw BridgeError.message("无法识别余额接口地址。") }
        let path: String
        switch mode {
        case .deepseek: path = "/user/balance"
        case .moonshot: path = "/v1/users/me/balance"
        case .kimi: path = "/coding/v1/usages"
        case .zhipu: path = "/api/monitor/usage/quota/limit"
        case .newAPI: path = "/api/usage/token/"
        case .sub2api: path = "/v1/usage"
        case .custom:
            guard channel.balancePath.hasPrefix("/"), !channel.balancePath.hasPrefix("//"), !channel.balancePath.contains("#") else { throw BridgeError.message("请填写自定义余额接口路径。") }
            path = channel.balancePath
        default:
            throw BridgeError.message("此渠道未启用余额查询，或服务商的普通 API Key 不开放余额接口。可在账户后台查看，或选择适用的查询类型。")
        }
        let authorization = mode == .zhipu ? channel.apiKey : "Bearer " + channel.apiKey
        let headers = ["Authorization": authorization, "Accept": "application/json"]
        let payload = try await quotaCall(origin + path, headers: headers, proxy: channel.proxyURL)
        var result: QuotaSnapshot
        if mode == .kimi {
            result = QuotaParser.kimi(payload)
            if let profile = try? await quotaCall(origin + "/coding/v1/me", headers: headers, proxy: channel.proxyURL) { result.plan = QuotaParser.string(profile["user_level_name"]) }
        } else { result = QuotaParser.balance(payload, mode: mode, currency: host == "api.moonshot.cn" ? "CNY" : host == "api.moonshot.ai" ? "USD" : "接口币种") }
        result.details.append(QuotaDetail(label: "查询来源", value: host + (URLComponents(string: path)?.path ?? "")))
        result.details.append(QuotaDetail(label: "渠道状态", value: channel.enabled ? "已启用" : "已停用"))
        return result
    }
}
