import Foundation
import SwiftUI

struct KiroCredentialImportResult {
    let savedCount: Int
    let failedCount: Int
    let failedEntries: [Int]
    let refreshedCount: Int
    let refreshNeededCount: Int

    var summary: String {
        var text = "已保存 \(savedCount) 条 Kiro 凭据。"
        if refreshedCount > 0 { text += "\(refreshedCount) 条凭据刷新成功，可测试模型。" }
        if refreshNeededCount > 0 { text += "其中 \(refreshNeededCount) 条需刷新或重新授权，已保存的账号仍会保留。" }
        if failedCount > 0 { text += "另有 \(failedCount) 条保存未确认，请检查本地服务后重试去重后的第 \(failedEntries.map(String.init).joined(separator: "、")) 条。" }
        return text
    }
}

extension BridgeStore {
    /// Validation finishes before the first write. Each valid account is then
    /// saved independently, preserving existing routing and disabled state.
    func importKiroCredentials(_ data: Data) async throws -> KiroCredentialImportResult {
        guard running, !busy, accountOperation == nil, login == nil else {
            throw BridgeError.message("请启动本地服务，并等待当前账号操作完成。")
        }
        let documents = try LocalSubscriptionCredentials.kiroDocuments(data)
        busy = true
        defer { busy = false }

        var occupied = Set(settings.channels.map(\.prefix))
        var prefixesVerified = true
        let knownAccounts = accounts
        for account in knownAccounts {
            do {
                let options = try await loadAccountOptions(account)
                if !options.prefix.isEmpty { occupied.insert(options.prefix) }
            } catch {
                // Updating an existing credential can still proceed. New
                // prefixes wait until all current prefixes can be checked.
                prefixesVerified = false
            }
        }

        var saved = 0
        var refreshed = 0
        var refreshNeeded = 0
        var failed: [Int] = []
        let accountDirectory = dataDirectory.appendingPathComponent("accounts", isDirectory: true)
        for (index, data) in documents.enumerated() {
            guard running else { failed.append(index + 1); continue }
            do {
                guard var document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw BridgeError.message("Kiro 凭据格式无效。")
                }
                let name = LocalSubscriptionIdentity.filename(provider: "kiro", document: document)
                let exists = FileManager.default.fileExists(atPath: accountDirectory.appendingPathComponent(name).path)
                    || knownAccounts.contains(where: { $0.name == name })
                if exists {
                    let oldData = try await request("/v8/management/credentials/download?name=" + Self.query(name), timeout: 10)
                    guard let existing = try JSONSerialization.jsonObject(with: oldData) as? [String: Any] else {
                        throw BridgeError.message("现有账号配置无法读取。")
                    }
                    for field in ["note", "prefix", "proxy_url", "proxy-url", "priority", "disabled"] {
                        if let value = existing[field] { document[field] = value }
                    }
                } else {
                    guard prefixesVerified else { throw BridgeError.message("暂时无法核对现有账号前缀。") }
                    let prefix = LocalSubscriptionIdentity.prefix(provider: "kiro", occupied: occupied)
                    document["prefix"] = prefix
                    occupied.insert(prefix)
                    document["disabled"] = false
                    let email = (document["email"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    document["note"] = email.isEmpty ? "Kiro 账号" : email
                }
                _ = try await request("/v8/management/credentials?name=" + Self.query(name), method: "POST",
                                      body: jsonData(document), timeout: 15)
                saved += 1
                do {
                    let account = try await awaitImportedKiroAccount(name: name)
                    var fields: [String: Any] = ["name": name]
                    if !account.authIndex.isEmpty { fields["auth_index"] = account.authIndex }
                    let responseData = try await request("/v8/management/credentials/refresh", method: "POST",
                                                         body: jsonData(fields), timeout: 30)
                    guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                          response["ok"] as? Bool == true,
                          (response["auth"] as? [String: Any])?["requires_sign_in"] as? Bool != true else {
                        throw BridgeError.message("Kiro 凭据仍需要刷新或重新授权。")
                    }
                    refreshed += 1
                } catch {
                    // A refresh failure must not erase a successfully saved
                    // credential or be reported as an upload failure.
                    refreshNeeded += 1
                }
            } catch {
                // Never forward a server response that could echo submitted
                // credential fields into the UI or the activity log.
                failed.append(index + 1)
            }
        }
        await refresh()
        let result = KiroCredentialImportResult(savedCount: saved, failedCount: failed.count, failedEntries: failed,
                                               refreshedCount: refreshed, refreshNeededCount: refreshNeeded)
        localSubscriptionStatus["kiro"] = result.summary
        record("Kiro 凭据导入：已保存 \(saved) 条，刷新成功 \(refreshed) 条，需重新授权 \(refreshNeeded) 条，保存未确认 \(failed.count) 条。",
               failed: !failed.isEmpty || refreshNeeded > 0)
        return result
    }

    private func awaitImportedKiroAccount(name: String) async throws -> Account {
        for attempt in 0..<12 {
            guard running else { throw BridgeError.message("本地服务已停止。") }
            let data = try await request("/v8/management/credentials", timeout: 5)
            if let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rows = response["files"] as? [[String: Any]],
               let row = rows.first(where: { $0["name"] as? String == name }) {
                let account = Account(row)
                if !account.authIndex.isEmpty { return account }
            }
            if attempt < 11 { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        throw BridgeError.message("账号已保存，等待本地反代加载后可重试刷新。")
    }
}

struct KiroCredentialImportView: View {
    @EnvironmentObject var store: BridgeStore
    @Environment(\.dismiss) private var dismiss
    @State private var credentialText = ""
    @State private var showingCredentials = false
    @State private var saving = false
    @State private var message = ""

    private let tint = Color(red: 0.69, green: 0.32, blue: 0.22)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("粘贴 Kiro 凭据登录").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("关闭") { close() }.disabled(saving).keyboardShortcut(.cancelAction)
            }
            Text("支持单个 JSON 对象或多个账号组成的数组。Google / GitHub 凭据会识别为社交登录；每个账号可分别设置模型前缀和出站代理。")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Kiro 凭据 JSON").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Toggle("显示凭据", isOn: $showingCredentials).toggleStyle(.checkbox).font(.system(size: 12)).disabled(saving)
                }
                if showingCredentials {
                    TextEditor(text: $credentialText)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8).frame(height: 210)
                        .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                        .disabled(saving)
                } else {
                    SecureField("粘贴包含 accessToken / refreshToken 的 JSON", text: $credentialText)
                        .textFieldStyle(.roundedBorder).disabled(saving)
                }
                Text("会保留邮箱、令牌及 Kiro 必需信息；不会保存密码、Cookie 或 TOTP 密钥。已有账号的备注、前缀、代理和停用状态会保留。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button(saving ? "正在保存…" : "导入登录") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || !store.running || store.busy || store.login != nil || store.accountOperation != nil
                              || credentialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(30).frame(width: 620)
        .background(Color(red: 0.97, green: 0.96, blue: 0.93))
        .preferredColorScheme(.light).tint(tint)
        .interactiveDismissDisabled(saving)
        .onDisappear { credentialText = ""; showingCredentials = false }
    }

    private func save() async {
        saving = true
        message = ""
        defer { saving = false }
        do {
            let result = try await store.importKiroCredentials(Data(credentialText.utf8))
            credentialText = ""
            showingCredentials = false
            message = result.summary
            if result.failedCount == 0 && result.refreshNeededCount == 0 { dismiss() }
        } catch {
            // Parsing and precondition errors are fixed, credential-free text.
            message = error.localizedDescription
        }
    }

    private func close() {
        credentialText = ""
        showingCredentials = false
        dismiss()
    }
}
