import SwiftUI
import WebKit

/// “自定义”分组里的登录中转站卡片：已登录站点、余额、Key 管理入口。
struct RelaySitesCard: View {
    @EnvironmentObject var store: BridgeStore
    @State private var loggingIn: RelayLoginRequest?
    @State private var managing: RelaySite?
    @State private var removing: RelaySite?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("登录中转站").font(.system(size: 16, weight: .semibold))
                        Text("在 BridgeDock 里打开站点登录页，用密码、QQ、微信等任意方式登录一次。之后 BD 自己续期登录，可随时新建 Key、一键接入，并定时核验模型。目前支持 Sub2API 站点。")
                            .captionText().fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button("登录中转站") { loggingIn = RelayLoginRequest(site: nil) }
                        .buttonStyle(WorkspaceButtonStyle(prominent: true)).disabled(!store.running)
                }
                if store.settings.relaySites.isEmpty {
                    Text("还没有登录任何中转站。").captionText()
                } else {
                    ForEach(store.settings.relaySites) { site in
                        Divider()
                        row(site)
                    }
                }
            }
        }
        .sheet(item: $loggingIn) { request in RelayLoginView(existing: request.site).environmentObject(store) }
        .sheet(item: $managing) { site in RelayKeysView(siteID: site.id).environmentObject(store) }
        .confirmationDialog("退出这个中转站的登录？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { site in
            Button("退出登录", role: .destructive) { Task { await store.removeRelaySite(site) }; removing = nil }
            Button("取消", role: .cancel) { removing = nil }
        } message: { _ in
            Text("BridgeDock 会注销这次登录并删除保存的令牌。已接入的渠道和 Key 保留，可继续使用。")
        }
    }

    private func row(_ site: RelaySite) -> some View {
        let account = store.relayAccounts[site.id]
        let channels = store.settings.channels.filter { $0.relaySiteID == site.id }
        return HStack(alignment: .top, spacing: 14) {
            Circle().fill(site.needsLogin ? warning : healthy).frame(width: 7, height: 7).padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(site.title).font(.system(size: 13, weight: .medium))
                    Pill(text: "Sub2API" + (site.version.isEmpty ? "" : " " + site.version), active: false)
                    if !channels.isEmpty { Pill(text: "已接入 \(channels.count) 个渠道") }
                }
                Text([site.email, site.origin].filter { !$0.isEmpty }.joined(separator: " · ")).captionText()
                if let account {
                    Text(accountLine(account)).captionText()
                }
                if let status = store.relayStatus[site.id], !status.isEmpty {
                    Text(status).font(.system(size: 11)).foregroundStyle(site.needsLogin ? warning : mutedInk).textSelection(.enabled)
                }
            }
            Spacer(minLength: 10)
            Button("打开") { store.relayFocus = site.id }.help("切到这个站点的管理卡片")
            Button("管理 Key") { managing = site }.disabled(!store.running || site.needsLogin)
            Menu {
                Button(site.needsLogin ? "重新网页登录" : "重新登录") { loggingIn = RelayLoginRequest(site: site) }
                Button("刷新余额") { Task { await store.loadRelayAccount(site) } }
                Button(site.autoReplaceKeys ? "关闭自动换 Key" : "开启自动换 Key") {
                    var value = site; value.autoReplaceKeys.toggle(); store.updateRelaySite(value)
                }
                Button("在浏览器打开后台") { if let url = URL(string: site.origin + "/dashboard") { NSWorkspace.shared.open(url) } }
                Divider()
                Button("退出登录…", role: .destructive) { removing = site }
            } label: { Text("更多") }.fixedSize()
        }.padding(.vertical, 4)
    }

    private func accountLine(_ account: RelayAccount) -> String {
        var parts: [String] = []
        if let balance = account.balance { parts.append("余额 " + Sub2API.amount(balance)) }
        if let frozen = account.frozen, frozen > 0 { parts.append("冻结 " + Sub2API.amount(frozen)) }
        if let today = account.todayCost { parts.append("今日消费 " + Sub2API.amount(today)) }
        if let requests = account.todayRequests { parts.append("今日请求 \(requests)") }
        if let concurrency = account.concurrency { parts.append("并发上限 \(concurrency)") }
        return parts.joined(separator: " · ")
    }
}

struct RelayLoginRequest: Identifiable {
    let id = UUID()
    let site: RelaySite?
}

/// 输入站点地址 → 内嵌网页登录 → 取走令牌交给 BD。网页使用独立的临时会话，关闭即清除。
struct RelayLoginView: View {
    @EnvironmentObject var store: BridgeStore
    @Environment(\.dismiss) private var dismiss
    let existing: RelaySite?
    @State private var address = ""
    @State private var proxy = ""
    @State private var origin: String?
    @State private var checking = false
    @State private var saving = false
    @State private var message = ""
    @State private var attempt = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(existing.map { "重新登录 · " + $0.title } ?? "登录中转站").font(.title2)
                Spacer()
                if checking || saving { ProgressView().controlSize(.small) }
                Button("关闭") { dismiss() }.disabled(saving)
            }
            if let origin {
                Text(message.isEmpty ? "请在下方站点登录页完成登录（密码、QQ、微信或验证码都可以）。登录成功后 BridgeDock 会自动保存，你的密码不会经过 BD。" : message)
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                RelayWebLogin(origin: origin) { tokens in
                    guard !saving else { return }
                    saving = true
                    message = "正在核对登录…"
                    Task { @MainActor in
                        do {
                            let site = try await store.connectRelaySite(origin: tokens.origin, accessToken: tokens.access, refreshToken: tokens.refresh,
                                                                        expiresAt: tokens.expiresAt, userAgent: tokens.userAgent, proxy: proxy)
                            store.importNotice = "已登录 \(site.title)（\(site.email)）。点“管理 Key”即可新建或接入 Key。"
                            dismiss()
                        } catch {
                            message = store.redacted(error.localizedDescription)
                            saving = false
                        }
                    }
                }.id(attempt)
                HStack {
                    Text(origin).font(.system(size: 11, design: .monospaced)).foregroundStyle(mutedInk)
                    Spacer()
                    Button("换个站点") { self.origin = nil; message = "" }.disabled(saving)
                    Button("重新加载") { attempt = UUID() }.disabled(saving)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("站点后台地址").font(.system(size: 12, weight: .medium))
                    TextField("例如 https://www.aiportx.com", text: $address).textFieldStyle(.roundedBorder)
                        .onSubmit(open)
                    DisclosureGroup("出站代理（可选）") {
                        SecureField("留空使用全局代理，例如 socks5://127.0.0.1:1080", text: $proxy).textFieldStyle(.roundedBorder).padding(.top, 6)
                    }.font(.system(size: 12))
                    if !message.isEmpty { NoticeBanner(text: message, tone: .failure) }
                    HStack {
                        Text("BD 会先确认这是 Sub2API 站点，再打开它的登录页。").captionText()
                        Spacer()
                        Button("打开登录页", action: open).buttonStyle(WorkspaceButtonStyle(prominent: true))
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                    }
                }
                Spacer()
            }
        }.padding(20).frame(width: 980, height: 720)
            .onAppear {
                if let existing {
                    address = existing.origin
                    proxy = existing.proxyURL
                    open()
                }
            }
    }

    private func open() {
        guard !checking else { return }
        checking = true
        message = ""
        Task { @MainActor in
            defer { checking = false }
            do {
                let value = try Sub2API.origin(address)
                _ = try await store.relayPublicSettings(origin: value, proxy: proxy)
                origin = value
            } catch { message = store.redacted(error.localizedDescription) }
        }
    }
}

struct RelayWebTokens {
    let origin: String
    let access: String
    let refresh: String
    let expiresAt: Date?
    let userAgent: String
}

private struct RelayWebLogin: NSViewRepresentable {
    let origin: String
    let connected: (RelayWebTokens) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(origin: origin, connected: connected) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 独立的临时会话：BD 拿到的是一次只属于自己的登录，关闭后网页数据随之清除。
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.start()
        if let url = URL(string: origin + "/login?redirect=/dashboard") { view.load(URLRequest(url: url)) }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
        coordinator.timer = nil
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var view: WKWebView?
        var timer: Timer?
        var delivered = false
        let host: String
        let connected: (RelayWebTokens) -> Void

        init(origin: String, connected: @escaping (RelayWebTokens) -> Void) {
            host = URLComponents(string: origin)?.host?.lowercased() ?? ""
            self.connected = connected
        }

        func start() {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkLogin() }
        }

        /// 站点和 www. 子域视为同一站点；QQ、微信等第三方授权页上的数据一律不读。
        private func sameSite(_ other: String?) -> Bool {
            guard let other = other?.lowercased() else { return false }
            func bare(_ value: String) -> String { value.hasPrefix("www.") ? String(value.dropFirst(4)) : value }
            return bare(other) == bare(host)
        }

        func checkLogin() {
            guard !delivered, let view, view.url?.scheme == "https" || view.url?.host == "localhost", sameSite(view.url?.host) else { return }
            let script = """
            (() => ({ origin: location.origin, access: localStorage.getItem('auth_token'), refresh: localStorage.getItem('refresh_token'),
                      expires: localStorage.getItem('token_expires_at'), ua: navigator.userAgent }))()
            """
            view.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self, !self.delivered, let value = result as? [String: Any],
                      let origin = value["origin"] as? String, self.sameSite(URLComponents(string: origin)?.host),
                      let access = value["access"] as? String, access.split(separator: ".").count == 3,
                      let refresh = value["refresh"] as? String, !refresh.isEmpty else { return }
                self.delivered = true
                let expires = (value["expires"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
                self.connected(RelayWebTokens(origin: origin, access: access, refresh: refresh, expiresAt: expires,
                                              userAgent: value["ua"] as? String ?? ""))
            }
        }

        /// 第三方登录常用新窗口打开授权页，这里改为在同一个视图里打开。
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}

/// 一个站点的 Key：查看、新建、一键接入为 BD 渠道。
struct RelayKeysView: View {
    @EnvironmentObject var store: BridgeStore
    @Environment(\.dismiss) private var dismiss
    let siteID: String
    @State private var keys: [RelayKey] = []
    @State private var groups: [RelayGroup] = []
    @State private var loading = false
    @State private var working: String?
    @State private var message = ""
    @State private var failed = false
    @State private var newName = Sub2API.managedKeyName()
    @State private var newGroup = 0
    @State private var newQuota = ""

    private var site: RelaySite? { store.relaySite(siteID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("管理 Key · " + (site?.title ?? "")).font(.title2)
                    Text(site?.email ?? "").captionText()
                }
                Spacer()
                if loading || working != nil { ProgressView().controlSize(.small) }
                Button("刷新") { Task { await load() } }.disabled(loading)
                Button("完成") { dismiss() }
            }
            if !message.isEmpty { NoticeBanner(text: message, tone: failed ? .failure : .success) }
            createSection
            Divider()
            Text("站点上的 Key · \(keys.count)").sectionTitle()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(keys) { key in
                        keyRow(key)
                        Divider()
                    }
                }
            }
        }.padding(22).frame(width: 860, height: 680)
            .task { await load() }
    }

    private var supportedGroups: [RelayGroup] { groups.filter { $0.wire != nil } }

    private var createSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("新建 Key 并接入 BridgeDock").sectionTitle()
            HStack(spacing: 10) {
                TextField("名称", text: $newName).textFieldStyle(.roundedBorder).frame(width: 190)
                Picker("分组", selection: $newGroup) {
                    Text("选择分组").tag(0)
                    ForEach(supportedGroups) { group in
                        Text(group.title + " · " + (group.wire?.title ?? "")).tag(group.id)
                    }
                }.frame(minWidth: 280)
                TextField("额度上限（可选）", text: $newQuota).textFieldStyle(.roundedBorder).frame(width: 130)
                Button("新建并接入") { Task { await createAndImport() } }
                    .buttonStyle(WorkspaceButtonStyle(prominent: true))
                    .disabled(newGroup == 0 || working != nil || store.busy)
            }
            if let group = groups.first(where: { $0.id == newGroup }) {
                Text((group.description.isEmpty ? "" : group.description + " · ") + "模型：" + (group.models.isEmpty ? "站点未公布，接入后自动查询" : group.models.joined(separator: "、")))
                    .captionText().lineLimit(3)
            }
            Text("以“\(Sub2API.managedKeyPrefix)”开头的 Key 由 BD 维护：被删、停用、到期或额度用完时会自动换新。设额度上限可以控制核验等自动请求的花费。")
                .captionText()
        }
    }

    private func keyRow(_ key: RelayKey) -> some View {
        let group = key.group ?? groups.first { $0.id == key.groupID }
        // 新版渠道用站点 + Key ID 匹配，Key 被站点轮换后仍显示“已接入”。
        // 两个回退分支兼容旧版没有 ID 的站点渠道和早期 CC Switch 导入。
        let linked = store.settings.channels.first {
            ($0.relaySiteID == siteID && $0.relayKeyID == key.id)
                || ($0.relaySiteID == siteID && $0.relayKeyID == 0 && !key.key.isEmpty && $0.apiKey == key.key)
                || ($0.relaySiteID.isEmpty && !key.key.isEmpty && $0.apiKey == key.key && $0.wire == group?.wire)
        }
        return HStack(alignment: .top, spacing: 12) {
            Circle().fill(key.exhausted() ? warning : healthy).frame(width: 7, height: 7).padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(key.name.isEmpty ? "未命名" : key.name).font(.system(size: 13, weight: .medium))
                    if let group { Pill(text: group.title, active: false) }
                    if key.managedByBridgeDock { Pill(text: "BD 维护") }
                    if key.status != "active" { Pill(text: key.status, tint: warning) }
                }
                Text(detail(key, group: group)).captionText().lineLimit(2)
                if let linked { Text("已接入 · " + linked.name).font(.system(size: 11)).foregroundStyle(healthy) }
            }
            Spacer(minLength: 10)
            if linked == nil {
                Button("接入 BD") { Task { await importKey(key, group: group) } }
                    .disabled(working != nil || store.busy || !key.usable || group?.wire == nil)
                    .help(group?.wire == nil ? "这个分组的协议 BridgeDock 暂不支持" : (key.usable ? "用这个 Key 新建 BD 渠道" : "Key 被打码，无法接入"))
            } else {
                Button("更新模型") { Task { await importKey(key, group: group) } }.disabled(working != nil || store.busy)
            }
        }.padding(.vertical, 9)
    }

    private func detail(_ key: RelayKey, group: RelayGroup?) -> String {
        var parts = [String(key.key.prefix(7)) + "…" + String(key.key.suffix(4))]
        if let wire = group?.wire { parts.append(wire.title) } else if let platform = group?.platform { parts.append(platform + "（暂不支持）") }
        if key.quota > 0 { parts.append("额度 \(Sub2API.amount(key.quotaUsed)) / \(Sub2API.amount(key.quota))") }
        if let expires = key.expiresAt { parts.append("到期 " + expires.formatted(date: .abbreviated, time: .omitted)) }
        if let used = key.lastUsedAt { parts.append("最近使用 " + used.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let site else { return }
        loading = true
        defer { loading = false }
        do {
            async let groupList = store.relayGroups(site)
            async let keyList = store.relayKeys(site)
            (groups, keys) = try await (groupList, keyList)
            if newGroup == 0 { newGroup = supportedGroups.first?.id ?? 0 }
        } catch { show(error) }
    }

    private func createAndImport() async {
        guard let site, let group = groups.first(where: { $0.id == newGroup }) else { return }
        working = "create"
        defer { working = nil }
        let quota = Double(newQuota.trimmingCharacters(in: .whitespaces))
        do {
            let key = try await store.createRelayKey(site, name: newName, groupID: group.id, quota: quota)
            let channel = try await store.importRelayKey(site, key: key, group: group)
            message = "已新建 \(key.name) 并接入为渠道“\(channel.name)”· \(channel.models.count) 个模型"
            failed = false
            newName = Sub2API.managedKeyName()
            await load()
        } catch { show(error) }
    }

    private func importKey(_ key: RelayKey, group: RelayGroup?) async {
        guard let site else { return }
        working = String(key.id)
        defer { working = nil }
        do {
            let channel = try await store.importRelayKey(site, key: key, group: group)
            message = "已接入渠道“\(channel.name)”· \(channel.models.count) 个模型"
            failed = false
        } catch { show(error) }
    }

    private func show(_ error: Error) {
        message = store.redacted(error.localizedDescription)
        failed = true
    }
}

/// 渠道的定时核验设置与历史。
struct ChannelVerificationView: View {
    @EnvironmentObject var store: BridgeStore
    @Environment(\.dismiss) private var dismiss
    let channelID: String
    @State private var hours = 0
    @State private var selected: Set<String> = []
    @State private var autoDisable = false
    @State private var saving = false
    @State private var message = ""

    private var channel: Channel? { store.settings.channels.first { $0.id == channelID } }
    private var log: VerificationLog { store.verificationLogs[channelID] ?? store.verificationLogStore.read(channelID) }
    private var running: Bool { store.verifyingChannels.contains(channelID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("模型核验 · " + (channel?.name ?? "")).font(.title2)
                    Text("每次核验对每个模型发 3–4 个小请求：响应格式、分词指纹、提示缓存、thinking 签名或推理 token；登录中转站的渠道还会核对站点计费。")
                        .captionText().fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if running { ProgressView().controlSize(.small) }
                Button("完成") { dismiss() }
            }
            if !message.isEmpty { NoticeBanner(text: message, tone: .info) }
            settingsSection
            Divider()
            Text("核验记录").sectionTitle()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if log.runs.isEmpty { Text("还没有核验记录。").captionText() }
                    ForEach(log.runs) { run in runView(run) }
                }
            }
        }.padding(22).frame(width: 820, height: 700)
            .onAppear {
                guard let channel else { return }
                hours = channel.verifyHours
                selected = Set(channel.verifyModels)
                autoDisable = channel.verifyAutoDisable
                _ = store.verificationLog(channelID)
            }
    }

    private var modelNames: [String] { channel?.models.compactMap { $0["name"] } ?? [] }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Picker("定时核验", selection: $hours) {
                    Text("关闭").tag(0)
                    Text("每 6 小时").tag(6)
                    Text("每 12 小时").tag(12)
                    Text("每天").tag(24)
                    Text("每周").tag(168)
                }.frame(width: 220)
                Toggle("确认异常时自动停用渠道", isOn: $autoDisable)
                Spacer()
                Button("保存设置") { Task { await save() } }.disabled(saving || store.busy)
                Button(running ? "核验中…" : "立即核验") {
                    let models = selected.isEmpty ? Array(modelNames.prefix(1)) : modelNames.filter(selected.contains)
                    Task { await store.verifyChannel(channelID, models: models) }
                }.buttonStyle(WorkspaceButtonStyle(prominent: true)).disabled(running || !store.running || modelNames.isEmpty)
            }
            Text("要核验的模型（不选则只核验第一个）").font(.system(size: 12, weight: .medium))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(modelNames, id: \.self) { name in
                        let isSelected = selected.contains(name)
                        Button {
                            if isSelected { selected.remove(name) } else { selected.insert(name) }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: isSelected ? "checkmark" : "plus")
                                    .font(.system(size: 9, weight: .bold))
                                Text(name).font(.system(size: 11, design: .monospaced))
                            }
                            .foregroundStyle(isSelected ? Color.white : ink)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(isSelected ? accent : panel, in: Capsule())
                            .overlay(Capsule().strokeBorder(isSelected ? accent : hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func runView(_ run: VerificationRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(run.verdict.title, systemImage: run.verdict.symbol).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color(run.verdict))
                Text(run.model).font(.system(size: 12, design: .monospaced))
                Spacer()
                Text(run.date.formatted(date: .abbreviated, time: .shortened) + String(format: " · %.0f 秒", run.seconds)).captionText()
            }
            ForEach(run.checks) { check in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol(check.outcome)).foregroundStyle(tint(check.outcome)).frame(width: 14)
                    Text(check.name).font(.system(size: 11, weight: .medium)).frame(width: 80, alignment: .leading)
                    Text(check.detail).font(.system(size: 11)).foregroundStyle(mutedInk).textSelection(.enabled)
                }
            }
        }.padding(12).background(panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hairline.opacity(0.7)))
    }

    private func color(_ verdict: VerificationVerdict) -> Color {
        switch verdict {
        case .trusted: return healthy
        case .suspicious: return warning
        case .abnormal: return failureTint
        case .unavailable: return mutedInk
        }
    }
    private func symbol(_ outcome: CheckOutcome) -> String {
        switch outcome {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.circle.fill"
        case .skip: return "minus.circle"
        }
    }
    private func tint(_ outcome: CheckOutcome) -> Color {
        switch outcome {
        case .pass: return healthy
        case .warn: return warning
        case .fail: return failureTint
        case .skip: return mutedInk
        }
    }

    private func save() async {
        guard var value = channel else { return }
        saving = true
        defer { saving = false }
        value.verifyHours = hours
        value.verifyModels = modelNames.filter(selected.contains)
        value.verifyAutoDisable = autoDisable
        do {
            try await store.saveChannel(value)
            message = hours == 0 ? "已关闭定时核验。" : "已保存：每 \(hours == 168 ? "周" : "\(hours) 小时") 自动核验一次。"
        } catch { message = store.redacted(error.localizedDescription) }
    }
}

/// 渠道行上的最新核验结论。
struct VerificationBadge: View {
    @EnvironmentObject var store: BridgeStore
    let channelID: String
    var body: some View {
        let latest = store.verificationLogs[channelID]?.runs.first
        Group {
            if store.verifyingChannels.contains(channelID) {
                Pill(text: "核验中", active: false)
            } else if let latest {
                Label(latest.verdict.title, systemImage: latest.verdict.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(latest.verdict == .trusted ? healthy : (latest.verdict == .unavailable ? mutedInk : warning))
                    .help("最近核验 " + latest.date.formatted(date: .abbreviated, time: .shortened) + " · " + latest.model)
            }
        }.onAppear { if store.verificationLogs[channelID] == nil { _ = store.verificationLog(channelID) } }
    }
}


/// 站点按钮图标：站点公布了 https Logo 时显示 Logo，否则显示站名首字。
struct RelaySiteIcon: View {
    let site: RelaySite
    var body: some View {
        let initial = String(site.title.first.map { String($0).uppercased() } ?? "?")
        let fallback = Text(initial).font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(accent)
            .frame(width: 30, height: 30).background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        if let url = URL(string: site.logoURL), !site.logoURL.isEmpty {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 7)) } else { fallback }
            }
        } else { fallback }
    }
}

/// 一个中转站的管理卡片：账户概况、登录状态、操作按钮，以及从这个站点接入的渠道与核验结论。
struct RelaySiteDetailView: View {
    @EnvironmentObject var store: BridgeStore
    let siteID: String
    @State private var managing = false
    @State private var relogin = false
    @State private var removing = false
    @State private var verifying: Channel?
    @State private var refreshing = false

    private var site: RelaySite? { store.relaySite(siteID) }
    private var channels: [Channel] { store.settings.channels.filter { $0.relaySiteID == siteID }.sorted { $0.name < $1.name } }

    var body: some View {
        if let site {
            VStack(alignment: .leading, spacing: 20) {
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        header(site)
                        metrics(store.relayAccounts[site.id])
                        if let status = store.relayStatus[site.id], !status.isEmpty {
                            NoticeBanner(text: status, tone: site.needsLogin ? .failure : .info)
                        }
                        actions(site)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("从 \(site.title) 接入的渠道 · \(channels.count)").sectionTitle()
                            Spacer()
                            Button("新建或接入 Key") { managing = true }.disabled(!store.running || site.needsLogin)
                        }
                        if channels.isEmpty {
                            Text("还没有接入这个站点的 Key。点“新建或接入 Key”选择分组，BD 会建好渠道并开放模型。").captionText()
                        }
                        ForEach(channels) { channel in
                            Divider()
                            channelRow(channel)
                        }
                    }
                }
            }
            .sheet(isPresented: $managing) { RelayKeysView(siteID: site.id).environmentObject(store) }
            .sheet(isPresented: $relogin) { RelayLoginView(existing: site).environmentObject(store) }
            .sheet(item: $verifying) { channel in ChannelVerificationView(channelID: channel.id).environmentObject(store) }
            .confirmationDialog("退出 \(site.title) 的登录？", isPresented: $removing, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) { Task { await store.removeRelaySite(site) } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("BridgeDock 会注销这次登录并删除保存的令牌。已接入的渠道和 Key 保留，可继续使用。")
            }
            .task(id: site.id) { if store.relayAccounts[site.id] == nil { await store.loadRelayAccount(site) } }
        }
    }

    private func header(_ site: RelaySite) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RelaySiteIcon(site: site).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(site.title).font(.system(size: 18, weight: .semibold))
                    Pill(text: "Sub2API" + (site.version.isEmpty ? "" : " " + site.version), active: false)
                    Pill(text: site.needsLogin ? "需要重新登录" : "登录有效", tint: site.needsLogin ? warning : healthy)
                }
                Text([site.email, "用户 \(site.userID)"].filter { !$0.isEmpty }.joined(separator: " · ")).captionText()
                Text("后台 " + site.origin + (site.apiBaseURL.isEmpty ? "" : " · 模型接口 " + site.apiBaseURL))
                    .monoSmall(10).foregroundStyle(mutedInk).textSelection(.enabled)
            }
            Spacer()
        }
    }

    private func metrics(_ account: RelayAccount?) -> some View {
        let items: [(String, String)] = [
            ("余额", account?.balance.map(Sub2API.amount) ?? "—"),
            ("冻结", account?.frozen.map(Sub2API.amount) ?? "—"),
            ("今日消费", account?.todayCost.map(Sub2API.amount) ?? "—"),
            ("今日请求", account?.todayRequests.map(String.init) ?? "—"),
            ("累计消费", account?.totalCost.map(Sub2API.amount) ?? "—"),
            ("累计充值", account?.totalRecharged.map(Sub2API.amount) ?? "—")
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.0).captionText(10)
                    Text(item.1).font(.system(size: 15, weight: .medium)).monospacedDigit().lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(canvas, in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private func actions(_ site: RelaySite) -> some View {
        HStack(spacing: 10) {
            Button("管理 Key") { managing = true }.buttonStyle(WorkspaceButtonStyle(prominent: true))
                .disabled(!store.running || site.needsLogin)
            Button(site.needsLogin ? "重新网页登录" : "重新登录") { relogin = true }.disabled(!store.running)
            Button(refreshing ? "刷新中…" : "刷新余额") {
                refreshing = true
                Task { await store.loadRelayAccount(site); refreshing = false }
            }.disabled(refreshing || site.needsLogin)
            Toggle("Key 失效时自动换新", isOn: Binding(get: { site.autoReplaceKeys },
                                                    set: { var value = site; value.autoReplaceKeys = $0; store.updateRelaySite(value) }))
                .toggleStyle(.checkbox).font(.system(size: 12))
            Spacer()
            Button("打开后台") { if let url = URL(string: site.origin + "/dashboard") { NSWorkspace.shared.open(url) } }
            Button("退出登录…", role: .destructive) { removing = true }
        }
    }

    private func channelRow(_ channel: Channel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(channel.enabled ? healthy : mutedInk.opacity(0.5)).frame(width: 7, height: 7).padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(channel.name).font(.system(size: 13, weight: .medium))
                    VerificationBadge(channelID: channel.id)
                    if channel.verifyHours > 0 { Pill(text: channel.verifyHours == 168 ? "每周核验" : "每 \(channel.verifyHours) 小时核验", active: false) }
                }
                Text("\(channel.wire.title) · \(channel.models.count) 个模型 · 前缀 \(channel.prefix)" + (channel.enabled ? "" : " · 已停用")).captionText()
                Text(channel.models.compactMap { $0["name"] }.prefix(8).joined(separator: "、")).captionText(10).lineLimit(1)
            }
            Spacer()
            Button("模型核验") { verifying = channel }
        }.padding(.vertical, 4)
    }
}
