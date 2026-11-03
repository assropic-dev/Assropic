import Foundation

extension BridgeStore {
    func connectLocalSubscription(_ provider: String) async {
        guard running, !busy, login == nil, accountOperation == nil,
              SubscriptionProvider.find(provider)?.supportsLocalLogin == true else { return }
        busy = true
        localSubscriptionStatus[provider] = "正在读取本机登录…"
        defer { busy = false }
        do {
            let local = try await Task.detached(priority: .userInitiated) {
                try LocalSubscriptionCredentials.load(provider: provider)
            }.value
            guard var document = try JSONSerialization.jsonObject(with: local.data) as? [String: Any] else {
                throw BridgeError.message("本机登录凭据格式不正确，请在官方客户端重新登录。")
            }
            let name = LocalSubscriptionIdentity.filename(provider: provider, document: document)
            var existing: [String: Any]?
            let accountDirectory = dataDirectory.appendingPathComponent("accounts")
            if FileManager.default.fileExists(atPath: accountDirectory.appendingPathComponent(name).path) || accounts.contains(where: { $0.name == name }) {
                let data = try await request("/v8/management/credentials/download?name=" + Self.query(name))
                existing = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            if existing == nil, LocalSubscriptionIdentity.stableIdentity(document) == nil {
                let filenames = (try? FileManager.default.contentsOfDirectory(atPath: accountDirectory.path)) ?? []
                guard !filenames.contains(where: { $0.hasPrefix("local-" + provider + "-") && $0.hasSuffix(".json") }) else {
                    throw BridgeError.message("本机凭据已变化，但缺少账号标识，无法确认是否仍为原账号。请使用浏览器授权，或先移除旧本机账号再连接。")
                }
            }
            if let existing {
                // Renewal must preserve routing and an explicitly disabled state.
                for key in ["note", "prefix", "proxy_url", "proxy-url", "priority", "disabled"] {
                    if let value = existing[key] { document[key] = value }
                }
            } else {
                var occupied = Set(settings.channels.map(\.prefix))
                for account in accounts {
                    let options = try await loadAccountOptions(account)
                    if !options.prefix.isEmpty { occupied.insert(options.prefix) }
                }
                document["prefix"] = LocalSubscriptionIdentity.prefix(provider: provider, occupied: occupied)
                document["note"] = "本机 " + (SubscriptionProvider.find(provider)?.title ?? provider)
                document["disabled"] = false
            }
            _ = try await request("/v8/management/credentials?name=" + Self.query(name), method: "POST", body: jsonData(document))
            // Core registration happens asynchronously after the credential write.
            var modelIDs: [String] = []
            for _ in 0..<8 {
                await refresh()
                if let account = accounts.first(where: { $0.name == name }) {
                    modelIDs = (try? await loadAccountModels(account)) ?? []
                    if account.disabled || !modelIDs.isEmpty { break }
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            let disabled = accounts.first(where: { $0.name == name })?.disabled == true
            let prefix = document["prefix"] as? String ?? ""
            let result: String
            if disabled { result = "本机凭据已更新；保留该账号的停用状态。" }
            else if modelIDs.isEmpty { result = "本机凭据已导入，尚无可用模型。请刷新列表或重新授权。" }
            else { result = "已接入本机登录 · \(modelIDs.count) 个模型 · 前缀 \(prefix)。请在模型页测试调用。" }
            localSubscriptionStatus[provider] = result
            record((SubscriptionProvider.find(provider)?.title ?? provider) + " · " + result)
        } catch {
            localSubscriptionStatus[provider] = redacted(error.localizedDescription)
            report(error)
        }
    }
}
