import Foundation

extension BridgeStore {
    // Work secrets are resolved only for the private core configuration. state.json
    // retains an account binding, never a copy of the desktop's Work/Web tokens.
    func settingsForCore(_ value: AppSettings) -> AppSettings {
        let result = KimiWorkRouting.resolve(value)
        if value.channels.indices.contains(where: { value.channels[$0].isKimiWork && value.channels[$0].enabled && !result.channels[$0].enabled }) {
            kimiWorkStatus = "Work 登录不可用或账号已切换，通道已暂停。请在桌面端登录后重新连接。"
        } else if result.channels.contains(where: { $0.isKimiWork && $0.enabled }) {
            kimiWorkStatus = "本机 Work 已连接 · 会员月度共享额度"
        }
        return result
    }

    func kimiWorkFingerprint() -> String { KimiWorkRouting.fingerprint(settings) }

    func synchronizeKimiWork(force: Bool = false) async {
        guard running, !workSyncing, force || !busy else { return }
        let fingerprint = kimiWorkFingerprint()
        guard fingerprint != workAppliedFingerprint else { return }
        workSyncing = true
        defer { workSyncing = false }
        do {
            _ = try await request("/v8/management/config.yaml", method: "PUT", body: jsonData(coreDocument(settings)), contentType: "application/yaml")
            workAppliedFingerprint = fingerprint
            if !fingerprint.contains("unavailable"), !fingerprint.isEmpty {
                kimiWorkStatus = "本机 Work 登录已同步，使用会员月度共享额度。"
            }
        } catch {
            kimiWorkStatus = "Work 凭据同步失败，请刷新或重新连接本机 Work。"
        }
    }

    func connectKimiWork() async {
        guard running, !busy, !workSyncing else { return }
        busy = true
        kimiWorkStatus = "正在读取本机 Work 登录并查询模型…"
        do {
            let session = try KimiWorkSession.read()
            let payload = try await kimiWorkRequest(path: KimiWorkSession.baseURL + "/models", token: session.apiKey)
            let names = ModelListRequest.names(in: payload)
            guard !names.isEmpty else { throw BridgeError.message("Work 网关没有返回模型，请在 Kimi 桌面端重新登录后再试。") }
            _ = try KimiWorkSession.read(expectedAccountHash: session.accountHash)
            var channel: Channel
            if let existing = settings.channels.first(where: \.isKimiWork) { channel = existing }
            else {
                channel = Channel()
                channel.name = "Kimi Work"
                channel.prefix = Channel.unusedPrefix("kimi-work", channels: settings.channels, accounts: accounts)
            }
            let sameAccount = channel.desktopAccountHash == session.accountHash
            channel.kind = "Kimi Work · 本机桌面登录"
            channel.credentialSource = "kimi-work-desktop"
            channel.desktopAccountHash = session.accountHash
            channel.apiKey = ""
            channel.baseURL = KimiWorkSession.baseURL
            channel.wire = .chat
            channel.balanceMode = .kimiWork
            channel.balancePath = ""
            channel.enabled = true
            if !sameAccount || channel.modelLines.isEmpty { channel.modelLines = names.joined(separator: "\n") }
            channel.capabilities = ModelListRequest.capabilities(in: payload)
            busy = false
            try await saveChannel(channel)
            kimiWorkStatus = "Work 已连接 · \(names.count) 个模型 · 前缀 \(channel.prefix) · 会员月度共享额度"
            record("已连接本机 Kimi Work 独立网关")
        } catch {
            busy = false
            kimiWorkStatus = error.localizedDescription
            report(error)
        }
    }

    func kimiWorkModels(_ channel: Channel) async throws -> [String] {
        try await kimiWorkCatalog(channel).0
    }

    func kimiWorkCatalog(_ channel: Channel) async throws -> ([String], [String: ModelCapability]) {
        let session = try KimiWorkSession.read(expectedAccountHash: channel.desktopAccountHash)
        let data = try await kimiWorkRequest(path: KimiWorkSession.baseURL + "/models", token: session.apiKey, proxy: channel.proxyURL)
        let names = ModelListRequest.names(in: data)
        guard !names.isEmpty else { throw BridgeError.message("Work 网关未返回模型列表。") }
        return (names, ModelListRequest.capabilities(in: data))
    }

    func kimiWorkQuota(_ channel: Channel) async throws -> [String: Any] {
        let session = try KimiWorkSession.read(expectedAccountHash: channel.desktopAccountHash)
        return try await kimiWorkRequest(path: "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats",
                                         token: session.webToken, proxy: channel.proxyURL, membership: true)
    }

    private func kimiWorkRequest(path: String, token: String, proxy: String = "", membership: Bool = false) async throws -> [String: Any] {
        let modelsURL = KimiWorkSession.baseURL + "/models"
        let membershipURL = "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats"
        guard path == (membership ? membershipURL : modelsURL) else { throw BridgeError.message("无效的 Work 网关请求。") }
        var headers = ["Authorization": "Bearer " + token, "User-Agent": "BridgeDock/1.3.2", "Accept": "application/json"]
        var value: [String: Any] = ["method": membership ? "POST" : "GET", "url": path, "header": headers, "proxy_url": proxy]
        if membership {
            headers["Content-Type"] = "application/json"
            headers["Connect-Protocol-Version"] = "1"
            value["header"] = headers
            value["data"] = "{}"
        }
        let result = try await object("/v8/management/requests/api-call", method: "POST", value: value)
        guard let status = result["status_code"] as? Int, (200..<300).contains(status) else {
            let status = result["status_code"] as? Int ?? 0
            if status == 401 {
                throw BridgeError.message(membership ? "会员额度登录已过期，请在 Kimi 桌面端重新登录；这不代表 Work 模型不可用。" : "Work 登录已过期，请在 Kimi 桌面端登录后重新连接。")
            }
            throw BridgeError.message("Kimi Work 接口暂不可用（HTTP \(status)）。")
        }
        guard let text = result["body"] as? String, let data = text.data(using: .utf8), data.count <= 2_000_000,
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.message("Work 接口返回了无法识别的数据。")
        }
        return payload
    }
}
