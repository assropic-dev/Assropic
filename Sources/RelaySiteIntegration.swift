import Foundation

enum RelayError: LocalizedError {
    case unauthorized
    var errorDescription: String? { "中转站登录已失效，请在 Assropic 中重新网页登录。" }
}

/// 登录中转站：内嵌网页登录取得令牌 → Assropic 自己续期 → 列出 / 新建 Key → 一键接入为渠道。
/// 所有请求经本地内核的 api-call 发出，沿用站点或全局出站代理；令牌只写在 relay-sites/ 私有文件里。
extension BridgeStore {
    var relaySessions: RelaySessionStore { RelaySessionStore(dataDirectory: dataDirectory) }

    func relaySite(_ id: String) -> RelaySite? { settings.relaySites.first { $0.id == id } }

    // MARK: - HTTP

    /// 调用站点 /api/v1 接口并取出 data。401 抛出 `RelayError.unauthorized`。
    func relayCall(_ site: RelaySite, _ path: String, method: String = "GET", body: [String: Any]? = nil, token: String?) async throws -> Any {
        guard running else { throw BridgeError.message("请先启动本地服务。") }
        guard path.hasPrefix("/"), !path.contains("://"), !path.contains("..") else { throw BridgeError.message("无效的中转站请求。") }
        var headers = ["Accept": "application/json",
                       "User-Agent": site.userAgent.isEmpty ? "Assropic" : site.userAgent]
        if let token { headers["Authorization"] = "Bearer " + token }
        var value: [String: Any] = ["method": method, "url": site.origin + "/api/v1" + path, "proxy_url": site.proxyURL]
        if let body {
            headers["Content-Type"] = "application/json"
            value["data"] = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        }
        value["header"] = headers
        let result = try await object("/v8/management/requests/api-call", method: "POST", value: value)
        let status = result["status_code"] as? Int ?? 0
        let text = result["body"] as? String ?? ""
        let payload = text.data(using: .utf8).flatMap { $0.count <= 8_000_000 ? try? JSONSerialization.jsonObject(with: $0) : nil } as? [String: Any]
        guard (200..<300).contains(status) else {
            if status == 401 { throw RelayError.unauthorized }
            let message = (payload?["message"] as? String).map { "：" + String($0.prefix(200)) } ?? ""
            throw BridgeError.message("中转站接口 HTTP \(status)" + message)
        }
        guard let payload else { throw BridgeError.message("中转站返回了无法识别的数据，确认地址是 Sub2API 站点的后台地址。") }
        return try Sub2API.data(payload)
    }

    /// 带登录令牌的请求；令牌被拒时强制刷新一次再重试。
    func relayAuthorized(_ site: RelaySite, _ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
        let token = try await relayAccessToken(site)
        do { return try await relayCall(site, path, method: method, body: body, token: token) }
        catch RelayError.unauthorized {
            let refreshed = try await refreshRelaySession(site, force: true)
            return try await relayCall(site, path, method: method, body: body, token: refreshed.accessToken)
        }
    }

    // MARK: - Session

    func relayAccessToken(_ site: RelaySite) async throws -> String {
        let session = try relaySessions.read(site.id)
        if session.needsRefresh() { return try await refreshRelaySession(site).accessToken }
        return session.accessToken
    }

    /// 刷新令牌会被轮换，同一站点同时只允许一次刷新，并且先落盘再使用。
    @discardableResult
    func refreshRelaySession(_ site: RelaySite, force: Bool = false) async throws -> RelaySession {
        for _ in 0..<100 where relayRefreshing.contains(site.id) { try await Task.sleep(nanoseconds: 100_000_000) }
        let session = try relaySessions.read(site.id)
        if !force && !session.needsRefresh() { return session }
        relayRefreshing.insert(site.id)
        defer { relayRefreshing.remove(site.id) }
        do {
            let data = try await relayCall(site, "/auth/refresh", method: "POST", body: ["refresh_token": session.refreshToken], token: nil)
            guard let object = data as? [String: Any], let access = object["access_token"] as? String, !access.isEmpty,
                  let refresh = object["refresh_token"] as? String, !refresh.isEmpty else {
                throw BridgeError.message("中转站没有返回新的登录令牌。")
            }
            let lifetime = Double(Sub2API.int(object["expires_in"]) ?? 86_400)
            let next = RelaySession(siteID: site.id, accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(lifetime))
            try relaySessions.save(next)
            relayStatus[site.id] = "登录有效 · 已自动续期"
            return next
        } catch RelayError.unauthorized {
            markRelayNeedsLogin(site.id)
            throw RelayError.unauthorized
        }
    }

    func markRelayNeedsLogin(_ siteID: String, _ needsLogin: Bool = true) {
        relayStatus[siteID] = needsLogin ? "登录已失效，请重新网页登录。已接入的 Key 不受影响。" : "登录有效"
        guard let index = settings.relaySites.firstIndex(where: { $0.id == siteID }), settings.relaySites[index].needsLogin != needsLogin else { return }
        var sites = settings.relaySites
        sites[index].needsLogin = needsLogin
        try? saveRelaySites(sites)
    }

    /// 读取站点公开设置，确认它是 Sub2API。
    func relayPublicSettings(origin: String, proxy: String = "") async throws -> [String: Any] {
        var probe = RelaySite()
        probe.origin = try Sub2API.origin(origin)
        probe.proxyURL = proxy
        guard let settings = try await relayCall(probe, "/settings/public", token: nil) as? [String: Any], Sub2API.looksLikeSub2API(settings) else {
            throw BridgeError.message("这个地址不是 Sub2API 中转站，暂时只支持 Sub2API（New API 站点请继续用 Key 或“导入 CC Switch”接入）。")
        }
        return settings
    }

    /// 内嵌网页登录完成后调用：核对身份并保存为 Assropic 自己的登录。
    @discardableResult
    func connectRelaySite(origin: String, accessToken: String, refreshToken: String, expiresAt: Date?, userAgent: String, proxy: String) async throws -> RelaySite {
        let origin = try Sub2API.origin(origin)
        let publicSettings = try await relayPublicSettings(origin: origin, proxy: proxy)
        var site = RelaySite()
        site.origin = origin
        site.proxyURL = proxy
        site.userAgent = String(userAgent.prefix(400))
        guard let me = try await relayCall(site, "/auth/me", token: accessToken) as? [String: Any],
              let userID = Sub2API.int(me["id"]), userID > 0 else {
            throw BridgeError.message("没有取得登录用户信息，请重新登录。")
        }
        if let existing = settings.relaySites.first(where: { $0.origin == origin && $0.userID == userID }) {
            site.id = existing.id
            site.autoReplaceKeys = existing.autoReplaceKeys
            if proxy.isEmpty { site.proxyURL = existing.proxyURL }
        }
        site.userID = userID
        site.email = me["email"] as? String ?? (me["username"] as? String ?? "")
        site.name = String((publicSettings["site_name"] as? String ?? "").prefix(40))
        site.version = publicSettings["version"] as? String ?? ""
        site.logoURL = Sub2API.logoURL(publicSettings["site_logo"], origin: origin)
        site.apiBaseURL = (publicSettings["api_base_url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let base = URLComponents(string: site.apiBaseURL), base.scheme != "https" || base.host == nil { site.apiBaseURL = "" }
        site.needsLogin = false
        let expiry = expiresAt.flatMap { $0 > Date() ? $0 : nil } ?? Date().addingTimeInterval(86_400)
        try relaySessions.save(RelaySession(siteID: site.id, accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiry))
        var sites = settings.relaySites
        if let index = sites.firstIndex(where: { $0.id == site.id }) { sites[index] = site } else { sites.append(site) }
        try saveRelaySites(sites)
        relayStatus[site.id] = "登录有效 · Assropic 独立续期"
        relayAccounts[site.id] = Sub2API.account(me: me, stats: nil)
        // 下一轮刷新就检查一次已接入的 Key（重新登录前可能有 Key 被删）。
        relayAttempts["upkeep:" + site.id] = nil
        record("已登录中转站 · \(site.title) · \(site.email)")
        relayFocus = site.id
        Task { await self.loadRelayAccount(site) }
        return site
    }

    func removeRelaySite(_ site: RelaySite) async {
        if let session = try? relaySessions.read(site.id) {
            _ = try? await relayCall(site, "/auth/logout", method: "POST", body: ["refresh_token": session.refreshToken], token: session.accessToken)
        }
        relaySessions.delete(site.id)
        do {
            try saveRelaySites(settings.relaySites.filter { $0.id != site.id })
            relayStatus[site.id] = nil
            relayAccounts[site.id] = nil
            record("已退出中转站登录 · \(site.title)；已接入的渠道保留")
        } catch { report(error) }
    }

    func updateRelaySite(_ site: RelaySite) {
        var sites = settings.relaySites
        guard let index = sites.firstIndex(where: { $0.id == site.id }) else { return }
        sites[index] = site
        do { try saveRelaySites(sites) } catch { report(error) }
    }

    // MARK: - Account, groups and keys

    func loadRelayAccount(_ site: RelaySite) async {
        do {
            guard let me = try await relayAuthorized(site, "/auth/me") as? [String: Any] else { return }
            let stats = try? await relayAuthorized(site, "/usage/dashboard/stats") as? [String: Any]
            relayAccounts[site.id] = Sub2API.account(me: me, stats: stats)
            if site.needsLogin { markRelayNeedsLogin(site.id, false) }
        } catch {
            if case RelayError.unauthorized = error { return }
            relayStatus[site.id] = redacted(error.localizedDescription)
        }
    }

    func relayGroups(_ site: RelaySite) async throws -> [RelayGroup] {
        Sub2API.groups(try await relayAuthorized(site, "/groups/available")).filter(\.active)
    }

    func relayKeys(_ site: RelaySite) async throws -> [RelayKey] {
        var result: [RelayKey] = []
        var page = 1
        while page <= 20 {
            let (keys, pages) = Sub2API.keys(try await relayAuthorized(site, "/keys?page=\(page)&page_size=100"))
            result += keys
            if page >= pages || keys.isEmpty { break }
            page += 1
        }
        return result
    }

    func createRelayKey(_ site: RelaySite, name: String, groupID: Int, quota: Double? = nil, expiresInDays: Int? = nil) async throws -> RelayKey {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = Sub2API.createBody(name: trimmed.isEmpty ? Sub2API.managedKeyName() : String(trimmed.prefix(60)),
                                      groupID: groupID, quota: quota, expiresInDays: expiresInDays)
        guard let object = try await relayAuthorized(site, "/keys", method: "POST", body: body) as? [String: Any],
              let key = RelayKey(object), key.usable else {
            throw BridgeError.message("中转站没有返回新 Key，请到站点后台确认是否已创建。")
        }
        record("已在 \(site.title) 新建 Key · \(key.name)")
        return key
    }

    /// 把 Key 接入为渠道并开放模型；分组没有公布模型时再查一次 /models。
    @discardableResult
    func importRelayKey(_ site: RelaySite, key: RelayKey, group: RelayGroup? = nil) async throws -> Channel {
        var channel = try Sub2API.channel(for: key, group: group, site: site, existing: settings.channels, accounts: accounts)
        if channel.models.isEmpty, let found = try? await discoverModels(for: channel), !found.modelLines.isEmpty {
            channel.modelLines = found.modelLines
            if !found.capabilities.isEmpty { channel.capabilities = found.capabilities }
        }
        try await saveChannel(channel)
        await publishModels(of: channel.id)
        return channel
    }

    // MARK: - Background upkeep

    /// 每轮刷新时调用：续期令牌；每 10 分钟更新账户概况、检查已接入的 Key；最后安排到期的定时核验。
    func synchronizeRelaySites() async {
        guard running, !relaySyncing else { return }
        relaySyncing = true
        defer { relaySyncing = false }
        for site in settings.relaySites where !site.needsLogin {
            if let session = try? relaySessions.read(site.id), session.needsRefresh(),
               Date().timeIntervalSince(relayAttempts["refresh:" + site.id] ?? .distantPast) > 60 {
                relayAttempts["refresh:" + site.id] = Date()
                do { try await refreshRelaySession(site) }
                catch { if !(error is RelayError) { relayStatus[site.id] = "自动续期失败，稍后重试：" + redacted(error.localizedDescription) } }
            }
            // 换 Key 要保存渠道；启动或其他配置操作进行中时先跳过，下一轮再查，不记时间。
            guard !busy, !workSyncing,
                  Date().timeIntervalSince(relayAttempts["upkeep:" + site.id] ?? .distantPast) > 600 else { continue }
            relayAttempts["upkeep:" + site.id] = Date()
            await loadRelayAccount(site)
            await checkRelayKeys(site)
        }
        scheduleDueVerifications()
    }

    /// 已接入的 Key 被删除，或 BD 新建的 Key 停用 / 到期 / 额度用完时，在原分组换一个新 Key。
    private func checkRelayKeys(_ site: RelaySite) async {
        let linked = settings.channels.filter { $0.relaySiteID == site.id && $0.relayKeyID > 0 }
        guard !linked.isEmpty, let keys = try? await relayKeys(site) else { return }
        for channel in linked {
            let key = keys.first { $0.id == channel.relayKeyID }
            guard key == nil || key!.exhausted() else { continue }
            let reason = key == nil ? "已在站点删除" : "已停用、到期或额度用完"
            let groupID = key?.groupID ?? channel.relayGroupID
            guard site.autoReplaceKeys, key == nil || key!.managedByBridgeDock, groupID > 0 else {
                relayStatus[site.id] = "渠道“\(channel.name)”的 Key \(reason)，请在站点处理或重新接入。"
                record("中转站 Key \(reason) · \(channel.name)", failed: true)
                continue
            }
            guard !busy, !workSyncing else { relayAttempts["upkeep:" + site.id] = nil; return }
            do {
                let fresh = try await createRelayKey(site, name: Sub2API.managedKeyName(), groupID: groupID)
                var updated = channel
                updated.apiKey = fresh.key
                updated.relayKeyID = fresh.id
                updated.relayGroupID = groupID
                do { try await saveChannel(updated) }
                catch {
                    // 没存进渠道的新 Key 删掉，免得下一轮再建一个。
                    _ = try? await relayAuthorized(site, "/keys/\(fresh.id)", method: "DELETE")
                    throw error
                }
                record("渠道“\(channel.name)”的 Key \(reason)，已自动换成新 Key · \(fresh.name)")
            } catch {
                record("自动换 Key 失败 · \(channel.name) · " + redacted(error.localizedDescription), failed: true)
            }
        }
    }
}
