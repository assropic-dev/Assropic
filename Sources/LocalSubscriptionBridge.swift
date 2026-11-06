import Foundation

extension BridgeStore {
    private struct LocalCredentialImportResult {
        let provider: String
        let name: String
        let modelCount: Int
        let disabled: Bool
        let updated: Bool
        let source: String
        let hasRefreshToken: Bool

        var title: String {
            SubscriptionProvider.find(provider)?.title ?? provider
        }
    }

    /// Copy a normalized credential into Assropic's own accounts directory.
    /// The source client is only read during this operation; the saved account
    /// is later refreshed and routed by Assropic itself.
    private func saveManagedLocalCredential(_ local: LocalSubscriptionCredential) async throws -> LocalCredentialImportResult {
        let provider = local.provider
        guard var document = try JSONSerialization.jsonObject(with: local.data) as? [String: Any] else {
            throw BridgeError.message("本机登录凭据格式不正确，请在官方客户端重新登录。")
        }
        let name = LocalSubscriptionIdentity.filename(provider: provider, document: document)
        let localEmail = (document["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
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
            // Claude Desktop may expose only a short-lived access token in its
            // process environment. Never discard a durable refresh token that
            // Assropic already saved from Keychain or Claude Code.
            if (document["refresh_token"] as? String)?.isEmpty != false,
               let refresh = existing["refresh_token"] as? String, !refresh.isEmpty {
                document["refresh_token"] = refresh
            }
            // Migrate the legacy local-import label without overwriting a
            // note the user entered themselves.
            if provider == "claude", let localEmail, !localEmail.isEmpty,
               let note = existing["note"] as? String,
               note == "本机 Claude" || note == "本机 Anthropic" {
                document["note"] = localEmail
            }
        } else {
            var occupied = Set(settings.channels.map(\.prefix))
            for account in accounts {
                let options = try await loadAccountOptions(account)
                if !options.prefix.isEmpty { occupied.insert(options.prefix) }
            }
            if settings.runtimeMode == .ccbaga && provider == "claude" {
                // Each CCBaga-mode account gets its own stable route.  The
                // source client can be switched independently afterwards.
                document["prefix"] = LocalSubscriptionIdentity.isolatedPrefix(
                    provider: provider, identity: name, occupied: occupied)
            } else {
                // Traditional mode keeps the existing provider account pool.
                document["prefix"] = AccountPools.prefix(forNew: provider, accounts: accounts,
                                                         independent: Set(settings.independentAccounts), occupied: occupied)
            }
            document["note"] = (provider == "claude" && !(localEmail ?? "").isEmpty)
                ? localEmail! : "本机 " + (SubscriptionProvider.find(provider)?.title ?? provider)
            document["disabled"] = false
        }
        // These fields are non-secret metadata. They make the ownership visible
        // in the UI and allow future migrations to distinguish BD-managed copies
        // from a path that still belongs to an external client.
        document["bridgedock_managed"] = true
        document["bridgedock_origin"] = local.source
        document["bridgedock_saved_at"] = ISO8601DateFormatter().string(from: Date())
        document["bridgedock_has_refresh_token"] = (document["refresh_token"] as? String)?.isEmpty == false
        _ = try await request("/v8/management/credentials?name=" + Self.query(name), method: "POST", body: jsonData(document))

        if settings.runtimeMode == .ccbaga && provider == "claude" {
            var next = settings
            if next.ccbagaEnvironments[name] == nil {
                next.ccbagaEnvironments[name] = CCBagaEnvironment(
                    identityID: name, claudeConfigDir: "", browserProfilePath: "",
                    useBrowser: true, status: "待绑定", lastSync: Date())
                try persistSettings(next)
                settings = next
            }
        }

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
        return LocalCredentialImportResult(provider: provider, name: name, modelCount: modelIDs.count,
                                           disabled: disabled, updated: existing != nil, source: local.source,
                                           hasRefreshToken: (document["refresh_token"] as? String)?.isEmpty == false)
    }

    func connectLocalSubscription(_ provider: String) async {
        guard running, !busy, login == nil, accountOperation == nil,
              SubscriptionProvider.find(provider)?.supportsLocalLogin == true else { return }
        busy = true
        localSubscriptionStatus[provider] = "正在读取本机登录…"
        defer { busy = false }
        do {
            let locals = try await Task.detached(priority: .userInitiated) {
                try LocalSubscriptionCredentials.loadAll(provider: provider)
            }.value
            guard !locals.isEmpty else { throw BridgeError.message("未找到本机登录凭据。") }
            var imported: [LocalCredentialImportResult] = []
            var failures: [String] = []
            for local in locals {
                do { imported.append(try await saveManagedLocalCredential(local)) }
                catch { failures.append(redacted(error.localizedDescription)) }
            }
            guard !imported.isEmpty else { throw BridgeError.message(failures.joined(separator: "\n")) }
            let result: String
            if imported.count == 1 {
                let item = imported[0]
                let source = URL(fileURLWithPath: item.source).lastPathComponent
                if item.disabled { result = "已读取本机 \(source)；由 Assropic 独立保存并保留该账号的停用状态。" }
                else if item.modelCount == 0 { result = "已读取本机 \(source) 并由 Assropic 独立保存，尚无可用模型。请刷新列表或重新授权。" }
                else if item.hasRefreshToken {
                    result = "已读取本机 \(source) · 独立保存本机登录 · \(item.modelCount) 个模型。删除源 Agent 后仍可在 Assropic 运行。"
                } else {
                    result = "已读取本机 \(source) · 已独立保存当前凭据 · \(item.modelCount) 个模型。当前来源没有 refresh token，凭据过期后需要重新授权。"
                }
            } else {
                let sources = imported.map { URL(fileURLWithPath: $0.source).lastPathComponent }.joined(separator: "、")
                result = "已读取本机 \(imported.count) 个 Claude 登录来源（\(sources)）· 均已由 Assropic 独立保存。"
            }
            localSubscriptionStatus[provider] = failures.isEmpty ? result : result + "\n部分来源失败：" + failures.joined(separator: "；")
            record((SubscriptionProvider.find(provider)?.title ?? provider) + " · " + result, failed: !failures.isEmpty)
        } catch {
            localSubscriptionStatus[provider] = redacted(error.localizedDescription)
            report(error)
        }
    }

    /// Read every supported local subscription source and import all credentials
    /// that are present. Missing providers are summarized instead of interrupting
    /// the other imports, so one absent client never blocks the whole scan.
    func scanLocalSubscriptions() async {
        guard running, !busy, login == nil, accountOperation == nil else { return }
        busy = true
        localSubscriptionStatus["__all__"] = "正在扫描本机登录…"
        defer { busy = false }
        let providers = SubscriptionProvider.all.filter { $0.available && $0.supportsLocalLogin }
        var saved = 0
        var updated = 0
        var missing = 0
        var failed: [String] = []
        for provider in providers {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[LocalSubscriptionCredential], BridgeError> in
                do { return .success(try LocalSubscriptionCredentials.loadAll(provider: provider.id)) }
                catch { return .failure(.message(error.localizedDescription)) }
            }.value
            switch result {
            case .success(let locals):
                for local in locals {
                    do {
                        let imported = try await saveManagedLocalCredential(local)
                        saved += 1
                        if imported.updated { updated += 1 }
                    } catch { failed.append(provider.title + "：" + redacted(error.localizedDescription)) }
                }
            case .failure(let failure):
                let message = redacted(failure.localizedDescription)
                // A missing file is expected during a full scan; malformed or
                // mismatched material needs to remain visible so the user can
                // repair that client instead of seeing a misleading "not
                // found" summary.
                if message.hasPrefix("未找到") {
                    missing += 1
                } else {
                    failed.append(provider.title + "：" + message)
                    localSubscriptionStatus[provider.id] = message
                }
            }
        }
        await refresh()
        var summary = "已扫描本机登录：保存 \(saved) 个"
        if updated > 0 { summary += "，更新 \(updated) 个" }
        if missing > 0 { summary += "，未发现 \(missing) 个" }
        if !failed.isEmpty { summary += "，失败 \(failed.count) 个" }
        summary += "。已保存的凭据由 Assropic 独立管理。"
        localSubscriptionStatus["__all__"] = summary
        record(summary, failed: !failed.isEmpty)
        if !failed.isEmpty { error = failed.joined(separator: "\n") }
    }
}
