import Foundation

extension BridgeStore {
    var workCredentials: KimiWorkCredentialStore { KimiWorkCredentialStore(dataDirectory: dataDirectory) }

    /// Import each old account once, then never consult the desktop again.
    func migrateKimiWork(_ value: AppSettings) -> AppSettings {
        var next = value
        for index in next.channels.indices where next.channels[index].credentialSource == "kimi-work-desktop" {
            let hash = next.channels[index].desktopAccountHash
            do {
                if (try? workCredentials.read(hash)) == nil {
                    let imported = try KimiWorkSession.read(expectedAccountHash: hash)
                    // Do not import/consume the desktop's refresh token.
                    try workCredentials.save(imported)
                }
                if let catalog = KimiWorkCatalog.desktopCache(accountHash: hash) {
                    next.channels[index].workModels = catalog
                    next.channels[index].capabilities = catalog.mapValues(\.capability)
                    next.channels[index].modelLines = KimiWorkCatalog.merging(Array(catalog.keys), into: next.channels[index].modelLines)
                }
                next.channels[index].credentialSource = "kimi-work"
                next.channels[index].kind = "Kimi Work · 独立登录"
                kimiWorkStatus = "Work 登录已迁移至 BridgeDock，不再依赖 Kimi 客户端。"
            } catch {
                kimiWorkStatus = "旧 Work 登录无法迁移，请点击网页登录。"
            }
        }
        return next
    }

    func settingsForCore(_ value: AppSettings) -> AppSettings {
        KimiWorkRouting.resolve(value, read: workCredentials.read)
    }

    func kimiWorkFingerprint() -> String { KimiWorkRouting.fingerprint(settings, read: workCredentials.read) }

    func synchronizeKimiWork(force: Bool = false) async {
        guard running, !workSyncing, force || !busy else { return }
        workSyncing = true
        defer { workSyncing = false }
        for channel in settings.channels where channel.isKimiWork && channel.enabled {
            guard let saved = try? workCredentials.read(channel.desktopAccountHash), saved.needsRefresh,
                  let refreshToken = saved.refreshToken, !refreshToken.isEmpty,
                  Date().timeIntervalSince(workRefreshAttempts[channel.id] ?? .distantPast) > 60 else { continue }
            workRefreshAttempts[channel.id] = Date()
            do {
                let payload = try await workRequest(url: Self.workRefreshURL, token: refreshToken,
                                                    body: ["refreshToken": refreshToken], proxy: channel.proxyURL)
                guard let access = payload["accessToken"] as? String,
                      let refresh = payload["refreshToken"] as? String,
                      let userID = KimiWorkSession.claims(access)?["sub"] as? String,
                      KimiWorkSession.digest("kimi-work-account\0" + userID) == saved.accountHash else {
                    throw BridgeError.message("Work 返回的登录信息无效，请重新网页登录。")
                }
                try workCredentials.save(KimiWorkSession(apiKey: saved.apiKey, webToken: access,
                                                         accountHash: saved.accountHash, refreshToken: refresh, ownsAPIKey: saved.ownsAPIKey))
            } catch {
                kimiWorkStatus = "Work 网页登录需要更新；已保存的模型 Key 继续独立使用。"
            }
        }
        let fingerprint = kimiWorkFingerprint()
        guard fingerprint != workAppliedFingerprint else { return }
        do {
            _ = try await request("/v8/management/config.yaml", method: "PUT", body: jsonData(coreDocument(settings)), contentType: "application/yaml")
            workAppliedFingerprint = fingerprint
            kimiWorkStatus = fingerprint.contains("unavailable") ? "Work 凭据不可用，请重新网页登录。" : "Work 已独立连接 · 会员月度共享额度"
        } catch { kimiWorkStatus = "Work 配置同步失败，请刷新后重试。" }
    }

    static let workRefreshURL = "https://auth.kimi.com/api/account.gateway.v1.AuthService/RefreshToken"
    static let workKeyURL = "https://www.kimi.com/apiv2/kimi.gateway.credentials.v1.APIKeyService/CreateAPIKey"
    static let workQuotaURL = "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats"

    /// Called only after the user has signed into the dedicated BridgeDock web view.
    func connectKimiWork(accessToken: String, refreshToken: String) async throws {
        guard running, !busy, !workSyncing else { throw BridgeError.message("请等待当前操作完成后重试。") }
        guard let userID = KimiWorkSession.claims(accessToken)?["sub"] as? String, !userID.isEmpty else {
            throw BridgeError.message("未取得有效的 Kimi 登录，请重新登录。")
        }
        busy = true
        defer { busy = false }
        let hash = KimiWorkSession.digest("kimi-work-account\0" + userID)
        let existing = settings.channels.first { $0.isKimiWork && $0.desktopAccountHash == hash }
        let proxy = existing?.proxyURL ?? ""
        let payload = try await workRequest(url: KimiWorkCatalog.endpoint, token: accessToken, body: [:], proxy: proxy)
        let catalog = try KimiWorkCatalog.parse(payload)
        let previous = try? workCredentials.read(hash)
        // A new web login also detaches imported desktop keys, which that client
        // may revoke on sign-out. Only reuse keys originally issued for BridgeDock.
        var key = previous?.ownsAPIKey == true ? previous?.apiKey : nil
        if let oldKey = key, (try? await workRequest(url: KimiWorkSession.baseURL + "/models", token: oldKey, proxy: proxy)) == nil { key = nil }
        if key == nil {
            let issued = try await workRequest(url: Self.workKeyURL, token: accessToken,
                                               body: ["apiKey": ["name": "BridgeDock", "scope": ["FEATURE_WORK"]]], proxy: proxy)
            key = (issued["apiKey"] as? [String: Any])?["key"] as? String
        }
        guard let key, !key.isEmpty else { throw BridgeError.message("Kimi 未签发 Work Key，请重新登录后重试。") }
        let session = KimiWorkSession(apiKey: key, webToken: accessToken, accountHash: hash,
                                      refreshToken: refreshToken.isEmpty ? nil : refreshToken, ownsAPIKey: true)
        try workCredentials.save(session)
        var channel = existing ?? Channel()
        if existing == nil {
            channel.name = "Kimi Work"
            channel.prefix = Channel.unusedPrefix("kimi-work", channels: settings.channels, accounts: accounts)
        }
        channel.kind = "Kimi Work · 独立登录"
        channel.credentialSource = "kimi-work"
        channel.desktopAccountHash = hash
        channel.apiKey = ""
        channel.baseURL = KimiWorkSession.baseURL
        channel.wire = .chat
        channel.balanceMode = .kimiWork
        channel.workModels = catalog
        channel.capabilities = catalog.mapValues(\.capability)
        channel.modelLines = KimiWorkCatalog.merging(Array(catalog.keys), into: channel.modelLines)
        busy = false
        do { try await saveChannel(channel) }
        catch {
            if let previous { try? workCredentials.save(previous) }
            throw error
        }
        kimiWorkStatus = "Work 已独立登录 · \(catalog.count) 个模型 · 无需 Kimi 客户端"
        record("已连接 Kimi Work 独立登录")
    }

    func refreshKimiWorkModels(_ channel: Channel) async {
        do {
            let catalog = try await kimiWorkModelCatalog(channel)
            guard var updated = settings.channels.first(where: { $0.id == channel.id }) else { return }
            updated.workModels = catalog
            updated.capabilities = catalog.mapValues(\.capability)
            updated.modelLines = KimiWorkCatalog.merging(Array(catalog.keys), into: updated.modelLines)
            try await saveChannel(updated)
            kimiWorkStatus = "Work 目录已更新 · \(catalog.count) 个模型"
        } catch { kimiWorkStatus = error.localizedDescription; report(error) }
    }

    func kimiWorkModelCatalog(_ channel: Channel) async throws -> [String: KimiWorkModel] {
        let session = try workCredentials.read(channel.desktopAccountHash)
        let payload = try await workRequest(url: KimiWorkCatalog.endpoint, token: session.webToken, body: [:], proxy: channel.proxyURL)
        return try KimiWorkCatalog.parse(payload)
    }

    func kimiWorkQuota(_ channel: Channel) async throws -> [String: Any] {
        let session = try workCredentials.read(channel.desktopAccountHash)
        return try await workRequest(url: Self.workQuotaURL, token: session.webToken, body: [:], proxy: channel.proxyURL)
    }

    private func workRequest(url: String, token: String, body: [String: Any]? = nil, proxy: String = "") async throws -> [String: Any] {
        guard [KimiWorkCatalog.endpoint, Self.workRefreshURL, Self.workKeyURL, Self.workQuotaURL, KimiWorkSession.baseURL + "/models"].contains(url) else {
            throw BridgeError.message("无效的 Work 请求。")
        }
        var headers = ["Authorization": "Bearer " + token, "User-Agent": "BridgeDock", "Accept": "application/json"]
        var value: [String: Any] = ["method": body == nil ? "GET" : "POST", "url": url, "proxy_url": proxy]
        if let body {
            headers["Content-Type"] = "application/json"
            headers["Connect-Protocol-Version"] = "1"
            value["data"] = String(decoding: try jsonData(body), as: UTF8.self)
        }
        value["header"] = headers
        let result = try await object("/v8/management/requests/api-call", method: "POST", value: value)
        let status = result["status_code"] as? Int ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 { throw BridgeError.message("Kimi Work 网页登录已过期，请在 BridgeDock 中重新网页登录；已保存的模型 Key 不受影响。") }
            throw BridgeError.message("Kimi Work 接口暂不可用（HTTP \(status)）。")
        }
        guard let text = result["body"] as? String, let data = text.data(using: .utf8), data.count <= 2_000_000,
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.message("Work 接口返回了无法识别的数据。")
        }
        return payload
    }
}
