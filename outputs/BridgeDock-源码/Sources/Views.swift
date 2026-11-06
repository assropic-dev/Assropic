import SwiftUI
import AppKit

enum Destination: String, CaseIterable, Identifiable {
    case overview = "总览", accounts = "账号与渠道", models = "模型与测试", clients = "工具接入", balances = "余额与额度", settings = "设置与诊断"
    var id: String { rawValue }
    static let sections: [(title: String, items: [Destination])] = [
        ("", [.overview]),
        ("接入来源", [.accounts]),
        ("使用", [.models, .clients, .balances]),
        ("系统", [.settings])
    ]
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .accounts: return "person.crop.rectangle.stack"
        case .balances: return "chart.bar.doc.horizontal"
        case .models: return "cube.transparent"
        case .clients: return "arrow.triangle.branch"
        case .settings: return "slider.horizontal.3"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "在这台 Mac 上，统一管理模型与编程工具的连接。"
        case .accounts: return "按服务商登录订阅账号或填写 API Key，凭据保存在本机。"
        case .balances: return "逐账号查看余额、周期额度、用量和重置时间。"
        case .models: return "检查模型联通程度、路由标识与实际回答表现。"
        case .clients: return "选择模型，再将本地接口接入你的编程工具。"
        case .settings: return "管理本地端口、出站代理与配置备份。"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: BridgeStore
    @State private var selected: Destination = .overview
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Rectangle().fill(hairline.opacity(0.65)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    if selected != .overview {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(selected.rawValue).font(.system(size: 24, weight: .regular, design: .serif))
                            Text(selected.subtitle).font(.system(size: 12)).foregroundStyle(mutedInk)
                        }
                    }
                    Spacer()
                    if !store.running {
                        Label(store.status, systemImage: "pause.circle").font(.system(size: 11)).foregroundStyle(warning)
                    }
                    ModelPublicationButton(prominent: true)
                }.padding(.horizontal, 44).padding(.top, 30).padding(.bottom, 22)
                ScrollView {
                    Group {
                        switch selected {
                        case .overview: OverviewView(selected: $selected)
                        case .accounts: AccountsView()
                        case .balances: BalancesView()
                        case .models: ModelsView()
                        case .clients: ClientsView()
                        case .settings: SettingsView()
                        }
                    }.frame(maxWidth: 1080).frame(maxWidth: .infinity).padding(.horizontal, 44).padding(.bottom, 44)
                }
            }
        }.background(canvas).foregroundStyle(ink).preferredColorScheme(.light).tint(accent)
            .buttonStyle(WorkspaceButtonStyle())
            .frame(minWidth: 1040, minHeight: 700)
            .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("知道了") { store.error = nil }
            } message: { Text(store.error ?? "") }
            .sheet(item: $store.pendingImport) { item in
                ChannelEditor(channel: item.channel, importing: item).environmentObject(store)
            }
            .onChange(of: store.pendingImport?.id) { _, id in if id != nil { selected = .accounts } }
            .onChange(of: store.importNotice) { _, notice in if !notice.isEmpty { selected = .accounts } }
            .onAppear { store.openMainWindow = { [openWindow] in openWindow(id: "main") } }
    }
    @Environment(\.openWindow) private var openWindow

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted").font(.system(size: 26, weight: .medium)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("BridgeDock").font(.system(size: 21, weight: .medium, design: .serif))
                    Text("桥 接 台").font(.system(size: 10, weight: .medium)).foregroundStyle(mutedInk)
                }
            }.padding(.top, 34).padding(.bottom, 26).padding(.horizontal, 24)
            ForEach(Destination.sections, id: \.title) { section in
                if !section.title.isEmpty {
                    Text(section.title).font(.system(size: 10, weight: .medium)).foregroundStyle(mutedInk)
                        .padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 6)
                }
                ForEach(section.items) { item in
                    Button {
                        selected = item
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.symbol).frame(width: 18)
                            Text(item.rawValue).font(.system(size: 13, weight: selected == item ? .semibold : .regular))
                            Spacer()
                            if let count = badge(item) {
                                Text(String(count)).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(mutedInk)
                            }
                        }.foregroundStyle(selected == item ? ink : mutedInk)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(selected == item ? panel : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected == item ? hairline.opacity(0.6) : .clear))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 2)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(store.running ? healthy : warning).frame(width: 7, height: 7)
                    Text(store.running ? "服务运行中" : store.status).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                Text("127.0.0.1:" + String(store.settings.port) + " · 仅本机").font(.system(size: 11, design: .monospaced)).foregroundStyle(mutedInk)
                Button(store.running ? "停止服务" : "启动服务") {
                    if store.running { store.stop() } else { Task { await store.start() } }
                }.disabled(store.busy).controlSize(.small)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(panel.opacity(0.8), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hairline.opacity(0.6))).padding(16)
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.3") · macOS · ARM64").font(.system(size: 10)).foregroundStyle(mutedInk.opacity(0.8)).padding(.horizontal, 26).padding(.bottom, 20)
        }.background(sidebarSurface)
    }

    private func badge(_ item: Destination) -> Int? {
        let count: Int
        switch item {
        case .accounts: count = store.accounts.count + store.settings.channels.count
        case .models: count = store.models.count
        default: return nil
        }
        return count > 0 ? count : nil
    }
}

struct OverviewView: View {
    @EnvironmentObject var store: BridgeStore
    @Binding var selected: Destination
    @State private var agent: EditingAgent = .cursor
    @State private var project = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: 34, weight: .light)).foregroundStyle(accent)
                Text("让好模型，顺手可用。")
                    .font(.system(size: 36, weight: .regular, design: .serif))
            }.padding(.top, 56).padding(.bottom, 48)

            VStack(alignment: .leading, spacing: 24) {
                Text("用哪个 Agent 开始编辑？")
                    .font(.system(size: 21, weight: .regular)).foregroundStyle(mutedInk)
                HStack(spacing: 10) {
                    ForEach(EditingAgent.allCases) { item in
                        Button { agent = item } label: {
                            VStack(spacing: 8) {
                                Image(nsImage: item.icon).renderingMode(.original).resizable().scaledToFit().frame(width: 34, height: 34)
                                Text(item.rawValue).font(.system(size: 10, weight: agent == item ? .semibold : .regular))
                            }.frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(agent == item ? accent.opacity(0.08) : insetSurface.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(agent == item ? accent : Color.clear, lineWidth: 1.5))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(item.rawValue).accessibilityLabel(item.rawValue).disabled(store.launchingAgent)
                    }
                }
                HStack {
                    Text(agent == .claudeDesktop ? "Claude · 桌面应用" : "\(agent.rawValue) · 打开项目开始编辑").font(.system(size: 12)).foregroundStyle(mutedInk)
                    Spacer()
                    Button {
                        if agent == .claudeDesktop { Task { await store.openClaudeDesktop() } }
                        else {
                            if project.isEmpty { chooseProject() }
                            if !project.isEmpty { Task { await store.startEditing(agent: agent, project: project) } }
                        }
                    } label: { Label(store.launchingAgent ? "正在打开…" : (agent == .claudeDesktop ? "打开 Claude" : "开始编辑"), systemImage: "arrow.up.right") }
                        .buttonStyle(WorkspaceButtonStyle(prominent: true)).disabled(store.launchingAgent || store.busy || store.cursorBusy)
                }
                if agent != .claudeDesktop {
                HStack {
                    Image(systemName: "folder").foregroundStyle(mutedInk)
                    Text(project.isEmpty ? "选择要编辑的项目文件夹" : project).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).help(project)
                    Spacer()
                    Button("选择项目") { chooseProject() }.disabled(store.launchingAgent)
                }
                } else {
                    Text("在 Claude 桌面端选择 Chat 或 Cowork；本地模型连接请先在工具接入页完成网关配置。").font(.system(size: 11)).foregroundStyle(mutedInk)
                }
                HStack {
                    if !store.settings.lastOpenedProject.isEmpty {
                        Text("上次打开 · \(store.settings.lastOpenedAgent.rawValue)").font(.system(size: 11)).foregroundStyle(mutedInk)
                    }
                    Spacer()
                    Button("配置模型接入") { selected = .clients }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent)
                }
                if agent == .kiro || agent == .zcode {
                    Text("此 Agent 按客户端当前的模型配置打开项目。").font(.system(size: 11)).foregroundStyle(mutedInk)
                }
            }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
                .background(panel, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(hairline, lineWidth: 1))
                .shadow(color: ink.opacity(0.035), radius: 18, x: 0, y: 5)

            HStack(spacing: 10) {
                Text(store.apiURL).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button { store.copy(store.apiURL) } label: { Label("复制地址", systemImage: "doc.on.doc") }
                    .buttonStyle(.plain).font(.system(size: 11)).help("复制本地 API 地址")
            }.foregroundStyle(mutedInk).padding(.horizontal, 16).padding(.top, 20)

            VStack(alignment: .leading, spacing: 28) {
                Text("你的连接").font(.system(size: 13, weight: .medium)).foregroundStyle(mutedInk)
                HStack(spacing: 20) {
                    statistic("API 渠道", String(store.settings.channels.filter { $0.enabled && !$0.isKimiWork }.count), "network", .accounts)
                    statistic("订阅账号", String(store.accounts.count + store.settings.channels.filter(\.isKimiWork).count), "person.crop.circle", .accounts)
                    statistic("可用模型", String(store.models.count), "cube", .models)
                }
            }.padding(.top, 64)
            Button("查看所有账号的余额与额度") { selected = .balances }.padding(.top, 24)
        }.frame(maxWidth: 800).padding(.bottom, 40)
            .onAppear { agent = store.settings.lastOpenedAgent; project = store.settings.lastOpenedProject }
    }

    private func chooseProject() {
        let dialog = NSOpenPanel()
        dialog.canChooseFiles = false
        dialog.canChooseDirectories = true
        dialog.allowsMultipleSelection = false
        dialog.prompt = "选择项目"
        if !project.isEmpty { dialog.directoryURL = URL(fileURLWithPath: project) }
        if dialog.runModal() == .OK, let url = dialog.url { project = url.path }
    }

    private func statistic(_ title: String, _ value: String, _ icon: String, _ destination: Destination) -> some View {
        Button { selected = destination } label: {
            Card {
                HStack {
                    Text(value).font(.system(size: 30, weight: .regular, design: .serif))
                    Spacer()
                    Image(systemName: icon).font(.system(size: 18, weight: .light)).foregroundStyle(mutedInk)
                }.padding(.bottom, 24)
                Text(title).font(.system(size: 13)).foregroundStyle(mutedInk)
            }
        }.buttonStyle(.plain)
    }
}

struct ChannelEditor: View {
    @EnvironmentObject var store: BridgeStore
    @Environment(\.dismiss) private var dismiss
    @State var channel: Channel
    var importing: ChannelImport? = nil
    @State private var fetching = false
    @State private var saving = false
    @State private var localError = ""
    @State private var visibleKey = false
    @State private var lookupTask: Task<Void, Never>?
    @State private var lookupID = UUID()
    @State private var isVisible = false
    @State private var initialized = false
    @State private var userEditedModels = false
    @State private var modelRevision = 0
    @State private var lastSettledInput: [String] = []
    @State private var candidate: ModelDiscovery?
    @State private var candidateInput: [String] = []
    @State private var discoveryNotice = ""

    private var preset: Preset? { channel.isKimiWork ? nil : Preset.matching(channel) }
    private var usesLiveDiscovery: Bool { channel.isKimiWork || (preset?.supportsModelDiscovery ?? true) }
    private var hasDiscoveryCredential: Bool { channel.isKimiWork || !channel.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    // This value is kept only in memory. Do not log it: it includes the draft key.
    private var discoveryInput: [String] {
        [channel.id, channel.baseURL, channel.wire.rawValue, channel.apiKey, channel.proxyURL, store.settings.proxyURL, String(channel.isKimiWork)]
    }
    private var canAutomaticallyDiscover: Bool {
        if channel.isKimiWork { return true }
        if let importing, channel.apiKey == importing.channel.apiKey, channel.baseURL == importing.channel.baseURL { return true }
        // Custom relays are allowed to advertise a standard or provider-shaped
        // model endpoint too.  Once a valid URL and key exist, query it
        // automatically; the parser keeps the user's list when the endpoint
        // is unavailable or returns an unfamiliar schema.
        guard let actual = URL(string: channel.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(actual.scheme?.lowercased() ?? ""), actual.host != nil,
              actual.user == nil, actual.password == nil, actual.query == nil, actual.fragment == nil else { return false }
        return true
    }
    private var modelText: Binding<String> {
        Binding(get: { channel.modelLines }, set: {
            channel.modelLines = $0
            userEditedModels = true
            modelRevision += 1
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                Text(importing == nil ? "配置 API 渠道" : "从中转站导入").font(.system(size: 24, weight: .regular, design: .serif))
                Spacer()
                Button("取消") { cancelLookup(); dismiss() }.disabled(saving)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let importing {
                        VStack(alignment: .leading, spacing: 8) {
                            Text((importing.existingName == nil ? "新渠道 · " : "更新已有渠道“\(importing.existingName!)” · ") + importing.site)
                                .font(.system(size: 13, weight: .semibold))
                            Text("自动导入没有完成，通常是中转站没有返回模型列表，或本地服务尚未启动。补全模型后保存即可；充值、换 Key、用量明细和删除令牌仍在中转站后台操作。")
                                .font(.system(size: 11)).foregroundStyle(mutedInk).lineSpacing(3)
                            if let page = URL(string: channel.manageURL), !channel.manageURL.isEmpty {
                                Link("打开中转站后台", destination: page).font(.system(size: 11))
                            }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(insetSurface, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if channel.isKimiWork {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Kimi Work · 独立登录").font(.system(size: 13, weight: .semibold))
                            Text("登录凭据由 BridgeDock 独立保存，无需安装或运行 Kimi 客户端。此渠道使用 Work 网关和会员共享额度；Fast 与超长上下文可能消耗更多额度。")
                                .font(.system(size: 11)).foregroundStyle(mutedInk).lineSpacing(3)
                            Link("GitHub · Kimi Work 适配", destination: URL(string: "https://github.com/keenlin/magpie-plugins/tree/main/packages/kimi-work")!).font(.system(size: 11))
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(insetSurface, in: RoundedRectangle(cornerRadius: 10))
                    } else if let preset, preset.id != "relay" {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(preset.detail).font(.system(size: 12)).foregroundStyle(mutedInk)
                            Text(preset.supportsModelDiscovery ? "官方预设已填写连接设置。输入 Key 后自动查询模型；所有字段仍可修改。预填模型不代表当前账号拥有调用权限。" : "官方预设已填写连接设置与默认模型。该服务不提供可用的模型列表接口；默认模型尚未验证当前账号权限，所有字段仍可修改。")
                                .font(.system(size: 11)).foregroundStyle(mutedInk).lineSpacing(3)
                            if let source = URL(string: preset.sourceURL), !preset.sourceURL.isEmpty {
                                Link("查看服务商文档", destination: source).font(.system(size: 11))
                            }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(insetSurface, in: RoundedRectangle(cornerRadius: 10))
                    }
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            Text("渠道名称").gridColumnAlignment(.trailing)
                            TextField("渠道名称", text: $channel.name).frame(height: 32)
                        }
                        GridRow {
                            Text("上游协议")
                            Picker("上游协议", selection: $channel.wire) {
                                ForEach(WireProtocol.allCases) { Text($0.title).tag($0) }
                            }.frame(height: 32).disabled(channel.isKimiWork)
                        }
                        GridRow {
                            Text("Base URL")
                            TextField("Base URL", text: $channel.baseURL, prompt: Text("https://your-provider.example/v1")).frame(height: 32).disabled(channel.isKimiWork)
                        }
                        if channel.isKimiWork {
                            GridRow {
                                Text("登录凭据")
                                Text("由 BridgeDock 独立保存").font(.system(size: 12)).foregroundStyle(mutedInk).frame(height: 32)
                            }
                        } else {
                            GridRow {
                                Text("API Key")
                                HStack(spacing: 10) {
                                    if visibleKey { TextField("API Key", text: $channel.apiKey) }
                                    else { SecureField("API Key", text: $channel.apiKey) }
                                    Button { visibleKey.toggle() } label: {
                                        Image(systemName: visibleKey ? "eye.slash" : "eye")
                                            .frame(width: 32, height: 32).contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityLabel(visibleKey ? "隐藏 API Key" : "显示 API Key")
                                }.frame(height: 32)
                            }
                        }
                        GridRow {
                            Text("渠道前缀")
                            TextField("渠道前缀", text: $channel.prefix).frame(height: 32)
                        }
                        if !channel.isKimiWork && (Preset.matching(channel) == nil || !channel.manageURL.isEmpty) {
                            GridRow {
                                Text("中转站后台（可选）")
                                TextField("中转站后台（可选）", text: $channel.manageURL, prompt: Text("https://relay.example/keys，渠道菜单可直接打开")).frame(height: 32)
                            }
                        }
                        GridRow {
                            Text("独立网络代理（可选）")
                            TextField("独立网络代理（可选）", text: $channel.proxyURL, prompt: Text("留空使用全局代理")).frame(height: 32)
                        }
                        GridRow {
                            Text("余额查询")
                            if channel.isKimiWork {
                                Text(BalanceMode.kimiWork.title).font(.system(size: 12)).foregroundStyle(mutedInk).frame(height: 32)
                            } else {
                                Picker("余额查询", selection: $channel.balanceMode) {
                                    ForEach(BalanceMode.allCases.filter { $0 != .kimiWork }) { mode in Text(mode.title).tag(mode) }
                                }.frame(height: 32)
                            }
                        }
                        if !channel.isKimiWork && channel.balanceMode == .custom {
                            GridRow {
                                Text("余额接口路径")
                                TextField("余额接口路径", text: $channel.balancePath, prompt: Text("/api/balance，与 Base URL 使用同一域名")).frame(height: 32)
                            }
                        }
                    }.labelsHidden().controlSize(.large).textFieldStyle(.roundedBorder)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("模型 ID 与别名").font(.system(size: 13, weight: .semibold))
                            Text("每行一个模型，也可写 上游模型ID = 自定义别名。对外调用名为“渠道名称前四字/别名”，保存后可在模型页复制。").font(.system(size: 11)).foregroundStyle(mutedInk)
                        }
                        Spacer()
                        Button(fetching ? "获取中…" : (usesLiveDiscovery ? "获取模型" : "填入官方模型")) {
                            if usesLiveDiscovery { scheduleLookup(manual: true) }
                            else { adoptPresetModels() }
                        }.disabled(fetching || saving || (usesLiveDiscovery && (!store.running || !hasDiscoveryCredential)))
                    }
                    TextEditor(text: modelText).scrollContentBackground(.hidden).font(.system(size: 12, design: .monospaced)).frame(height: 145).padding(7).background(insetSurface, in: RoundedRectangle(cornerRadius: 10))
                    if let candidate, candidateInput == discoveryInput {
                        HStack {
                            Text("已准备 \(candidate.modelLines.components(separatedBy: .newlines).filter { !$0.isEmpty }.count) 个模型，保留了你编辑的列表。")
                                .font(.system(size: 11)).foregroundStyle(mutedInk)
                            Spacer()
                            Button(usesLiveDiscovery ? "采用查询列表" : "采用官方列表") { adoptCandidate() }.disabled(fetching || saving)
                        }
                    }
                    if !discoveryNotice.isEmpty {
                        Text(discoveryNotice).font(.system(size: 11)).foregroundStyle(healthy).textSelection(.enabled)
                    }
                    Text(channel.isKimiWork ? "从 Work 最新目录获取模型与 Fast 选项，实际可用性以上游返回为准。查询失败会保留当前模型，你编辑的模型和别名不会被自动覆盖。" : "查询失败会保留当前模型。官方预设仅作默认配置，实际权限以服务商返回及模型测试结果为准；你编辑的模型和别名不会被自动覆盖。")
                        .font(.system(size: 11)).foregroundStyle(mutedInk).lineSpacing(3)
                    if !localError.isEmpty { Text(localError).font(.system(size: 12)).foregroundStyle(warning).textSelection(.enabled) }
                }.padding(4)
            }.disabled(saving)
            HStack {
                Toggle("启用渠道", isOn: $channel.enabled).disabled(saving)
                Spacer()
                Button(saving || store.busy ? "保存中…" : "保存渠道") { save() }
                    .buttonStyle(WorkspaceButtonStyle(prominent: true)).disabled(store.busy || saving || fetching)
            }
        }.padding(30)
            .frame(width: 720, height: min(820, (NSScreen.main?.visibleFrame.height ?? 900) - 80))
            .background(canvas).foregroundStyle(ink).preferredColorScheme(.light).tint(accent).buttonStyle(WorkspaceButtonStyle())
            .onAppear {
                isVisible = true
                if channel.isKimiWork { channel.balanceMode = .kimiWork }
                if !initialized {
                    userEditedModels = store.settings.channels.contains { $0.id == channel.id } && !channel.modelLines.isEmpty
                    initialized = true
                }
                scheduleLookup(manual: false)
            }
            .onDisappear { isVisible = false; cancelLookup() }
            .onChange(of: discoveryInput) { _, input in
                if input != lastSettledInput { scheduleLookup(manual: false) }
                else { cancelLookup() }
            }
            .onChange(of: store.running) { _, running in
                if running { scheduleLookup(manual: false) }
                else { cancelLookup() }
            }
    }

    private func cancelLookup() {
        lookupTask?.cancel()
        lookupTask = nil
        lookupID = UUID()
        fetching = false
    }

    private func scheduleLookup(manual: Bool) {
        cancelLookup()
        candidate = nil
        candidateInput = []
        discoveryNotice = ""
        localError = ""
        guard isVisible, !saving, store.running,
              manual || canAutomaticallyDiscover,
              hasDiscoveryCredential else { return }
        let id = UUID()
        lookupID = id
        let input = discoveryInput
        let snapshot = channel
        let revision = modelRevision
        lookupTask = Task { @MainActor in
            do {
                if !manual { try await Task.sleep(nanoseconds: 750_000_000) }
                try Task.checkCancellation()
                guard isVisible, lookupID == id, discoveryInput == input else { return }
                fetching = true
                defer { if lookupID == id { fetching = false; lookupTask = nil } }
                let result = try await store.discoverModels(for: snapshot)
                try Task.checkCancellation()
                guard isVisible, lookupID == id, discoveryInput == input else { return }
                // Product recognition may adjust the endpoint and protocol. Keep
                // fields the user changed while the request was in flight.
                channel.kind = result.channel.kind
                channel.baseURL = result.channel.baseURL
                channel.wire = result.channel.wire
                if channel.name == snapshot.name { channel.name = result.channel.name }
                if channel.balanceMode == snapshot.balanceMode { channel.balanceMode = result.channel.balanceMode }
                if channel.balancePath == snapshot.balancePath { channel.balancePath = result.channel.balancePath }
                if !result.capabilities.isEmpty { channel.capabilities = result.capabilities }
                if channel.isKimiWork { channel.workModels = result.channel.workModels }
                let safeToReplace = modelRevision == revision && channel.modelLines == snapshot.modelLines && (manual || !userEditedModels)
                if safeToReplace {
                    channel.modelLines = result.modelLines
                    candidate = nil
                } else {
                    candidate = result
                    candidateInput = discoveryInput
                }
                lastSettledInput = discoveryInput
                discoveryNotice = result.notice
                if discoveryNotice.isEmpty {
                    discoveryNotice = safeToReplace ? "模型列表已更新。" : "查询已完成，可选择采用查询列表。"
                }
            } catch is CancellationError {
                // A changed key, endpoint or closing sheet invalidates this result.
            } catch {
                guard isVisible, lookupID == id, discoveryInput == input else { return }
                var message = store.redacted(error.localizedDescription)
                for secret in [snapshot.apiKey, snapshot.proxyURL] where !secret.isEmpty {
                    message = message.replacingOccurrences(of: secret, with: "••••••")
                }
                localError = message
            }
        }
    }

    private func adoptPresetModels() {
        guard let preset else { return }
        cancelLookup()
        channel.modelLines = preset.defaultModelLines
        userEditedModels = true
        modelRevision += 1
        candidate = nil
        candidateInput = []
        discoveryNotice = "已填入官方默认模型，尚未验证当前账号权限。"
    }

    private func adoptCandidate() {
        guard let candidate, candidateInput == discoveryInput else { return }
        channel.modelLines = candidate.modelLines
        userEditedModels = true
        modelRevision += 1
        self.candidate = nil
        candidateInput = []
        discoveryNotice = usesLiveDiscovery ? "已采用查询到的模型列表，仍可继续编辑。" : "已采用官方默认模型，尚未验证当前账号权限。"
    }

    private func save() {
        cancelLookup()
        if channel.isKimiWork {
            channel.apiKey = ""
            channel.balanceMode = .kimiWork
        }
        if channel.modelLines.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let preset, preset.id != "relay" {
            channel.modelLines = preset.defaultModelLines
        }
        saving = true
        localError = ""
        Task { @MainActor in
            defer { saving = false }
            do { try await store.saveChannel(channel); dismiss() }
            catch {
                var message = store.redacted(error.localizedDescription)
                if !channel.apiKey.isEmpty { message = message.replacingOccurrences(of: channel.apiKey, with: "••••••") }
                localError = message
            }
        }
    }
}

struct AccountsView: View {
    @EnvironmentObject var store: BridgeStore
    @State private var callback = ""
    @State private var removing: Account?
    @State private var editing: Account?
    @State private var inspecting: Account?
    @State private var search = ""
    @State private var family: SourceFamily?
    @State private var loginProxy = ""
    @State private var kiroMethod = "builder-id"
    @State private var kimiRegion = "kimi"
    @State private var zcodeRegion = "zcode-bigmodel"

    private let providerContentHeight: CGFloat = 252
    private let providerButtonSize = CGSize(width: 112, height: 36)
    @State private var addingCursor = false
    @State private var addingCursorProfile: CursorAccountProfile = .cursor
    @State private var addingKiro = false
    @State private var addingKimiWork = false
    @State private var editingWork: Channel?
    @State private var removingWork: Channel?
    @State private var editingChannel: Channel?
    @State private var deletingChannel: Channel?
    @State private var verifyingChannel: Channel?
    /// 选中某个已登录的中转站按钮时，页面只显示这个站点的管理卡片。
    @State private var relayTab: String?
    @State private var addingRelay = false

    init(initialFamily: SourceFamily? = nil) { _family = State(initialValue: initialFamily) }

    private struct SourceGroup: Identifiable {
        let family: SourceFamily
        let accounts: [Account]
        let work: [Channel]
        let channels: [Channel]
        var id: String { family.rawValue }
        var count: Int { accounts.count + work.count + channels.count }
    }

    private var workChannels: [Channel] { store.settings.channels.filter(\.isKimiWork) }

    private func matches(_ fields: [String]) -> Bool {
        search.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(search) }
    }

    private var visibleAccounts: [Account] {
        store.accounts.filter { account in
            let provider = SubscriptionProvider.find(account.loginProvider)
            return (family == nil || SourceFamily.of(account) == family)
                && matches([account.displayName, account.email, account.provider, provider?.title ?? "", account.providerTitle, account.note, account.name])
        }.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private var visibleChannels: [Channel] {
        store.settings.channels.filter { channel in
            (family == nil || SourceFamily.of(channel) == family)
                && matches([channel.name, channel.prefix, channel.kind, channel.baseURL, channel.relaySite, channel.manageURL] + (channel.isKimiWork ? ["Kimi Work 独立登录 会员月度共享额度"] : []))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var groups: [SourceGroup] {
        let accounts = visibleAccounts, channels = visibleChannels
        return SourceFamily.allCases.compactMap { item in
            let group = SourceGroup(family: item,
                                    accounts: accounts.filter { SourceFamily.of($0) == item },
                                    work: channels.filter { $0.isKimiWork && SourceFamily.of($0) == item },
                                    channels: channels.filter { !$0.isKimiWork && SourceFamily.of($0) == item })
            return group.count > 0 ? group : nil
        }
    }

    private func connectedCount(in item: SourceFamily?) -> Int {
        guard let item else { return store.accounts.count + store.settings.channels.count }
        return store.accounts.filter { SourceFamily.of($0) == item }.count
            + store.settings.channels.filter { SourceFamily.of($0) == item }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !store.importNotice.isEmpty {
                HStack {
                    NoticeBanner(text: store.importNotice, tone: store.importNotice.hasPrefix("正在") ? .info : .success)
                    Button("知道了") { store.importNotice = "" }
                }
            }
            familyBar
            loginSession
            if let site = store.settings.relaySites.first(where: { $0.id == relayTab }) {
                RelaySiteDetailView(siteID: site.id)
            } else {
                connectedSources
                addSection
            }
        }
        .onChange(of: store.relayFocus) { _, id in
            guard let id else { return }
            relayTab = id
            store.relayFocus = nil
        }
        .sheet(isPresented: $addingRelay) { RelayLoginView(existing: nil).environmentObject(store) }
        .sheet(item: $editing) { account in AccountOptionsView(account: account).environmentObject(store) }
        .sheet(item: $inspecting) { account in AccountModelsView(account: account).environmentObject(store) }
        .sheet(isPresented: $addingCursor) { CursorAccountView(proxyURL: loginProxy, initialProfile: addingCursorProfile).environmentObject(store) }
        .sheet(isPresented: $addingKiro) { KiroCredentialImportView().environmentObject(store) }
        .sheet(isPresented: $addingKimiWork) { KimiWorkLoginView().environmentObject(store) }
        .sheet(item: $editingWork) { channel in ChannelEditor(channel: channel).environmentObject(store) }
        .sheet(item: $editingChannel) { channel in ChannelEditor(channel: channel).environmentObject(store) }
        .sheet(item: $verifyingChannel) { channel in ChannelVerificationView(channelID: channel.id).environmentObject(store) }
        .onAppear { kiroMethod = store.settings.kiroUseOrganization ? "organization" : "builder-id" }
        .confirmationDialog("删除这个订阅账号？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { account in
            Button("删除账号", role: .destructive) {
                Task { await store.removeAccount(account) }
                removing = nil
            }
            Button("取消", role: .cancel) { removing = nil }
        } message: { account in
            Text("将从 BridgeDock 删除“\(account.displayName)”，并保留恢复副本。原平台账号和登录不受影响。")
        }
        .confirmationDialog("断开这个 Kimi Work 连接？", isPresented: Binding(get: { removingWork != nil }, set: { if !$0 { removingWork = nil } }), titleVisibility: .visible, presenting: removingWork) { channel in
            Button("断开 Work 连接", role: .destructive) {
                Task { await store.deleteChannel(channel) }
                removingWork = nil
            }
            Button("取消", role: .cancel) { removingWork = nil }
        } message: { _ in
            Text("将移除这个 Work 模型通道。本机 Kimi 桌面登录和 Code 订阅账号保持不变。")
        }
        .confirmationDialog("删除这个 API 渠道？", isPresented: Binding(get: { deletingChannel != nil }, set: { if !$0 { deletingChannel = nil } }), titleVisibility: .visible, presenting: deletingChannel) { channel in
            Button("删除渠道", role: .destructive) {
                Task { await store.deleteChannel(channel) }
                deletingChannel = nil
            }
            Button("取消", role: .cancel) { deletingChannel = nil }
        } message: { channel in
            Text("将删除“\(channel.name)”的地址、Key 和模型设置。")
        }
    }

    private var familyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                familyButton(nil)
                // 已登录的中转站紧跟“全部”，每站一个按钮，窄窗口下也不会被挤到看不见的地方。
                ForEach(store.settings.relaySites) { relaySiteButton($0) }
                if !store.settings.relaySites.isEmpty {
                    Rectangle().fill(hairline).frame(width: 1, height: 44).padding(.horizontal, 4)
                }
                ForEach(SourceFamily.allCases) { familyButton($0) }
                Button { addingRelay = true } label: {
                    VStack(spacing: 7) {
                        Image(systemName: "plus").font(.system(size: 16, weight: .light)).foregroundStyle(accent).frame(width: 30, height: 30)
                        Text("登录中转站").font(.system(size: 10)).lineLimit(1)
                    }.frame(width: 76).padding(.vertical, 12)
                        .background(panel, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hairline.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!store.running).help("登录一个 Sub2API 中转站")
                    .accessibilityIdentifier("relay-site-add")
            }.padding(2)
        }
    }

    private func familyButton(_ item: SourceFamily?) -> some View {
        let isSelected = family == item && relayTab == nil
        let count = connectedCount(in: item)
        let title = item?.title ?? "全部"
        return Button { family = item; relayTab = nil } label: {
            VStack(spacing: 7) {
                Group {
                    if let image = item?.icon {
                        Image(nsImage: image).renderingMode(.original).resizable().scaledToFit()
                    } else {
                        Image(systemName: item == nil ? "square.grid.2x2" : "link")
                            .font(.system(size: 18, weight: .light)).foregroundStyle(mutedInk)
                    }
                }.frame(width: 30, height: 30)
                    .overlay(alignment: .topTrailing) {
                        if count > 0 {
                            Text(String(count)).font(.system(size: 9, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(accent, in: Capsule()).offset(x: 10, y: -6)
                        }
                    }
                Text(title).font(.system(size: 10, weight: isSelected ? .semibold : .regular)).lineLimit(1)
            }.frame(width: 76).padding(.vertical, 12)
                .background(isSelected ? accent.opacity(0.08) : panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? accent : hairline.opacity(0.6), lineWidth: isSelected ? 1.5 : 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(item == nil ? "全部服务商" : title)
            .accessibilityLabel(count > 0 ? "\(title)，已接入 \(count) 个" : title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("source-family-" + (item?.rawValue ?? "all"))
    }

    /// 每个登录过的中转站一个按钮，点开是这个站点自己的管理卡片。
    private func relaySiteButton(_ site: RelaySite) -> some View {
        let isSelected = relayTab == site.id
        let count = store.settings.channels.filter { $0.relaySiteID == site.id }.count
        return Button { relayTab = site.id } label: {
            VStack(spacing: 7) {
                RelaySiteIcon(site: site).frame(width: 30, height: 30)
                    .overlay(alignment: .topTrailing) {
                        if site.needsLogin {
                            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(warning).offset(x: 8, y: -6)
                        } else if count > 0 {
                            Text(String(count)).font(.system(size: 9, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(accent, in: Capsule()).offset(x: 10, y: -6)
                        }
                    }
                Text(site.title).font(.system(size: 10, weight: isSelected ? .semibold : .regular)).lineLimit(1)
            }.frame(width: 76).padding(.vertical, 12)
                .background(isSelected ? accent.opacity(0.08) : panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? accent : hairline.opacity(0.6), lineWidth: isSelected ? 1.5 : 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(site.title + " · " + site.origin)
            .accessibilityLabel("中转站 " + site.title + (site.needsLogin ? "，需要重新登录" : (count > 0 ? "，已接入 \(count) 个渠道" : "")))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("relay-site-" + site.id)
    }

    @ViewBuilder private var addSection: some View {
        if let family {
            let presets = Preset.all.filter { family.presetIDs.contains($0.id) }
            let providers = family.subscriptionIDs.compactMap(SubscriptionProvider.find)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("添加 " + family.title).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    if !providers.isEmpty {
                        Text("同一服务商的多个账号组成账号池：新会话依次分到各账号，同一会话固定在一个账号；优先级高的优先，独立前缀可单独使用某个账号。")
                            .font(.system(size: 11)).foregroundStyle(mutedInk)
                    }
                }
                if !providers.isEmpty {
                    DisclosureGroup("本次登录的出站代理（可选）") {
                        VStack(alignment: .leading, spacing: 8) {
                            SecureField("留空继承全局代理，例如 socks5://127.0.0.1:1080", text: $loginProxy).textFieldStyle(.roundedBorder)
                            Text("仅影响接下来发起的授权及新账号请求。已有账号可在“账号设置”中单独修改。此处不支持 direct；直连请清空全局代理。").font(.system(size: 11)).foregroundStyle(mutedInk)
                        }.padding(.top, 10)
                    }.font(.system(size: 12))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                        ForEach(providers) { provider in
                            Card {
                                providerControls(selectedProvider(for: provider), familyID: provider.id)
                                    .frame(height: providerContentHeight)
                            }
                        }
                        if family.includesKimiWork { Card { kimiWorkControls.frame(height: providerContentHeight) } }
                    }
                }
                if family == .custom { RelaySitesCard() }
                if !presets.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(family == .custom ? "第三方中转站" : "使用 API Key").font(.system(size: 13, weight: .semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                            ForEach(presets) { preset in
                                Button {
                                    editingChannel = preset.makeChannel(existing: store.settings.channels, accounts: store.accounts)
                                } label: {
                                    HStack {
                                        Text(preset.title).font(.system(size: 12)).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "plus").foregroundStyle(accent)
                                    }.padding(.horizontal, 12).padding(.vertical, 11)
                                        .background(panel, in: RoundedRectangle(cornerRadius: 9))
                                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(hairline.opacity(0.7)))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).help(preset.detail)
                            }
                        }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("点击上方服务商图标，登录订阅账号或填写 API Key。")
                    .font(.system(size: 12)).foregroundStyle(mutedInk)
                Text("首次接入后，凭据会复制到 BridgeDock 的私有数据目录。删除源 Harness 或 Agent 后，BD 仍可独立刷新并运行账号。")
                    .font(.system(size: 11)).foregroundStyle(mutedInk)
            }.padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var loginSession: some View {
            if let login = store.login {
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("正在授权 · " + login.displayName).font(.headline)
                            Spacer()
                            Button("取消登录") { Task { await store.cancelLogin() } }
                        }
                        Text(store.loginStatus).font(.system(size: 12)).foregroundStyle(accent).textSelection(.enabled)
                        Text("等待截止：\(login.expiresAt.formatted(date: .omitted, time: .standard))")
                        if !login.userCode.isEmpty {
                            HStack {
                                Text("设备码")
                                Text(login.userCode).font(.system(size: 20, weight: .bold, design: .monospaced)).textSelection(.enabled)
                                Button("复制") { store.copy(login.userCode) }
                            }
                        }
                        HStack {
                            Button("重新打开授权网页") { if let url = URL(string: login.url) { NSWorkspace.shared.open(url) } }
                            Button("复制授权链接") { store.copy(login.url) }
                        }
                        Text("添加另一个账号时，请在授权网页选择切换账号，确认当前身份后再授权。").font(.system(size: 11)).foregroundStyle(mutedInk)
                        if login.supportsCallback {
                            if login.provider == "claude" {
                                Text("先在网页完成授权。若未自动返回，复制完成页面的整段 code#state，或以 localhost 开头的完整回调地址。claude.ai/oauth/authorize 登录页地址不能用于提交。").font(.system(size: 12)).foregroundStyle(mutedInk)
                            }
                            SecureField(login.provider == "claude" ? "粘贴授权结果：code#state 或 localhost 回调地址" : "若浏览器无法自动返回，可粘贴完整回调 URL", text: $callback).textFieldStyle(.roundedBorder)
                                .disabled(store.callbackSubmission == login.id)
                            Button("提交回调") {
                                let text = callback
                                Task {
                                    if await store.submitCallback(text), store.login?.id == login.id { callback = "" }
                                }
                            }.disabled(callback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.callbackSubmission == login.id)
                        }
                    }
                }.onChange(of: login.id) { _, _ in callback = "" }
            } else if !store.loginStatus.isEmpty {
                Text(store.loginStatus).font(.system(size: 12)).foregroundStyle(accent).textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
    }

    private var actionsDisabled: Bool { !store.running || store.busy || store.login != nil || store.accountOperation != nil }

    private var kimiWorkControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            providerHeader(title: "Kimi Work", symbol: "globe",
                           detail: "独立网页登录 · 会员共享额度，无需 Kimi 客户端。")
            Color.clear.frame(height: 24)
            providerCount(workChannels.count)
            providerStatus(store.kimiWorkStatus)
            HStack(spacing: 8) {
                Button(workChannels.isEmpty ? "网页登录" : "重新网页登录") {
                    addingKimiWork = true
                }.buttonStyle(WorkspaceButtonStyle(prominent: workChannels.isEmpty, fixedSize: providerButtonSize))
                    .disabled(!store.running || store.busy)
                Spacer(minLength: 0)
            }.frame(height: providerButtonSize.height)
            Color.clear.frame(height: providerButtonSize.height)
        }
    }

    private func providerHeader(title: String, symbol: String, detail: String, sourceURL: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: symbol).foregroundStyle(accent.opacity(0.7))
                if let sourceURL, let source = URL(string: sourceURL) {
                    Link(destination: source) { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain).foregroundStyle(mutedInk)
                        .help("查看适配来源").accessibilityLabel(title + " 适配来源")
                }
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(mutedInk).lineSpacing(2)
                .lineLimit(2).help(detail)
        }.frame(maxWidth: .infinity, alignment: .topLeading).frame(height: 64, alignment: .top)
    }

    private func selectedProvider(for provider: SubscriptionProvider) -> SubscriptionProvider {
        let selectedID: String
        switch provider.id {
        case "kimi": selectedID = kimiRegion
        case "zcode-bigmodel": selectedID = zcodeRegion
        default: return provider
        }
        return SubscriptionProvider.find(selectedID) ?? provider
    }

    private func providerCount(_ count: Int) -> some View {
        HStack {
            if count > 0 { Pill(text: "已接入 \(count) 个") }
            Spacer(minLength: 0)
        }.frame(height: 24)
    }

    private func providerStatus(_ message: String, unavailable: Bool = false) -> some View {
        Text(message).font(.system(size: 11)).foregroundStyle(unavailable ? warning : mutedInk)
            .lineLimit(2).textSelection(.enabled).help(message)
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 28, alignment: .top)
    }

    @ViewBuilder private func providerTabs(familyID: String) -> some View {
        Group {
            if familyID == "kimi" {
                Picker("Kimi 地区", selection: $kimiRegion) {
                    Text("国内").tag("kimi")
                    Text("国际").tag("kimi-ai")
                }.accessibilityIdentifier("kimi-region")
            } else if familyID == "zcode-bigmodel" {
                Picker("ZCode 地区", selection: $zcodeRegion) {
                    Text("国内").tag("zcode-bigmodel")
                    Text("国际").tag("zcode-zai")
                }.accessibilityIdentifier("zcode-region")
            } else if familyID == "kiro" {
                Picker("浏览器授权方式", selection: $kiroMethod) {
                    Text("AWS Builder ID").tag("builder-id")
                    Text("组织 SSO").tag("organization")
                }
            } else {
                Color.clear
            }
        }.pickerStyle(.segmented).labelsHidden().font(.system(size: 11)).frame(height: 24)
    }

    private func connectedCount(_ provider: SubscriptionProvider, familyID: String) -> Int {
        store.accounts.filter {
            (SubscriptionProvider.find($0.loginProvider)?.id ?? $0.provider) == provider.id
                && (provider.id != CursorAccountProfile.providerID || SourceFamily.of($0).id == familyID)
        }.count
    }

    private func providerControls(_ provider: SubscriptionProvider, familyID: String) -> some View {
        let isCursor = provider.id == CursorAccountProfile.providerID
        let isGrokBot = isCursor && familyID == "grok"
        let title = isGrokBot ? "Grok Bot" : (familyID == "kimi" ? "Kimi Code" : (familyID == "zcode-bigmodel" ? "ZCode" : provider.title))
        let message = provider.available ? (store.localSubscriptionStatus[provider.id] ?? "") : provider.unavailableReason
        return VStack(alignment: .leading, spacing: 8) {
            providerHeader(title: title, symbol: provider.supportsLocalLogin ? "laptopcomputer.and.arrow.down" : "person.badge.key",
                           detail: isGrokBot ? "Grok Bot 使用 Cursor 网页授权 · 完成后自动保存账号" : provider.detail, sourceURL: provider.sourceURL)
            providerTabs(familyID: familyID)
            providerCount(connectedCount(provider, familyID: familyID))
            providerStatus(message, unavailable: !provider.available)
            HStack(spacing: 8) {
                if isCursor {
                    if isGrokBot {
                        Button("Grok Bot 登录") { Task { await store.beginLogin(provider.id, proxyURL: loginProxy) } }
                            .buttonStyle(WorkspaceButtonStyle(prominent: true, fixedSize: providerButtonSize)).disabled(actionsDisabled)
                        Button("使用账号凭据") { addingCursorProfile = .grokBot; addingCursor = true }.disabled(actionsDisabled)
                    } else {
                        Button("添加 Cursor 账号") { addingCursorProfile = .cursor; addingCursor = true }
                            .buttonStyle(WorkspaceButtonStyle(prominent: true, fixedSize: providerButtonSize)).disabled(actionsDisabled)
                    }
                    Button("读取本机 Cursor 登录") { Task { await store.connectLocalSubscription(provider.id) } }
                        .disabled(actionsDisabled)
                } else if provider.supportsLocalLogin {
                    Button("读取本机订阅") { Task { await store.connectLocalSubscription(provider.id) } }
                        .buttonStyle(WorkspaceButtonStyle(prominent: true, fixedSize: providerButtonSize)).disabled(actionsDisabled)
                    Button("浏览器授权") {
                        Task { await store.beginLogin(provider.id, proxyURL: loginProxy, method: provider.id == "kiro" ? kiroMethod : "") }
                    }.disabled(!provider.available || actionsDisabled)
                } else {
                    Button("添加账号") { Task { await store.beginLogin(provider.id, proxyURL: loginProxy) } }
                        .buttonStyle(WorkspaceButtonStyle(prominent: true, fixedSize: providerButtonSize))
                        .disabled(!provider.available || provider.importOnly || actionsDisabled)
                }
                Spacer(minLength: 0)
            }.buttonStyle(WorkspaceButtonStyle(fixedSize: providerButtonSize)).frame(height: providerButtonSize.height)
            HStack {
                if provider.id == "kiro" {
                    Button("粘贴登录凭据") { addingKiro = true }
                        .buttonStyle(WorkspaceButtonStyle(fixedSize: providerButtonSize))
                        .help("粘贴 Google / GitHub 凭据登录").disabled(actionsDisabled)
                }
                Spacer(minLength: 0)
            }.frame(height: providerButtonSize.height)
        }
    }

    private var connectedSources: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text((family.map { $0.title + " · " } ?? "已接入 · ") + String(connectedCount(in: family))).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button(store.busy ? "扫描中…" : "自动读取本机登录") {
                        Task { await store.scanLocalSubscriptions() }
                    }.disabled(!store.running || store.busy || store.login != nil || store.accountOperation != nil)
                    Button("导入凭据 JSON") { Task { await store.importAccount() } }.disabled(!store.running || store.busy)
                    Button("刷新列表") { Task { await store.refresh() } }.disabled(!store.running)
                }
                if let scanStatus = store.localSubscriptionStatus["__all__"], !scanStatus.isEmpty {
                    Label(scanStatus, systemImage: "checkmark.shield")
                        .font(.system(size: 11)).foregroundStyle(mutedInk).textSelection(.enabled)
                }
                TextField("搜索账号、渠道、备注或地址", text: $search).textFieldStyle(.roundedBorder)
                if groups.isEmpty {
                    Text(connectedCount(in: family) == 0 ? "尚未接入。在下方登录账号、填写 API Key，或导入账号凭据 JSON。" : "没有符合搜索条件的账号或渠道。")
                        .font(.system(size: 12)).foregroundStyle(mutedInk).padding(.vertical, 18)
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        if family == nil {
                            HStack(spacing: 6) {
                                if let image = group.family.icon {
                                    Image(nsImage: image).renderingMode(.original).resizable().scaledToFit().frame(width: 14, height: 14)
                                }
                                Text(group.family.title + " · \(group.count)")
                            }.font(.system(size: 11, weight: .semibold)).foregroundStyle(mutedInk).padding(.top, 8)
                        }
                        ForEach(group.accounts) { account in
                            Divider().opacity(0.3)
                            accountRow(account)
                        }
                        ForEach(group.work) { channel in
                            Divider().opacity(0.3)
                            workAccountRow(channel)
                        }
                        ForEach(group.channels) { channel in
                            Divider().opacity(0.3)
                            channelRow(channel)
                        }
                    }
                }
            }
        }
    }

    private func channelRow(_ channel: Channel) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Circle().fill(channel.enabled ? healthy : mutedInk.opacity(0.5)).frame(width: 7, height: 7).padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(channel.name).font(.system(size: 13, weight: .medium))
                    Pill(text: channel.relaySite.isEmpty ? "API Key" : "中转站 · " + channel.relaySite, active: false)
                    VerificationBadge(channelID: channel.id)
                    if let name = store.publicPrefix(source: "channel:" + channel.id) {
                        Text(name + "/…").font(.system(size: 11, design: .monospaced)).foregroundStyle(accent)
                            .help("对外调用名前缀；内部路由前缀为 " + channel.prefix)
                    }
                }
                Text("\(channel.wire.title) · \(channel.models.count) 个模型" + (channel.enabled ? "" : " · 已停用"))
                    .font(.system(size: 11)).foregroundStyle(mutedInk)
                Text(channel.baseURL).font(.system(size: 10, design: .monospaced)).foregroundStyle(mutedInk)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                QuotaSummaryView(target: QuotaTarget(channel: channel))
            }
            Spacer(minLength: 10)
            if !channel.manageURL.isEmpty {
                Button("中转站后台") { store.openManagePage(channel) }
                    .help("在浏览器打开 " + channel.manageURL + "，充值、换 Key 和查看用量明细")
            }
            Menu {
                Button("渠道设置与模型…") { editingChannel = channel }
                if !channel.isKimiWork { Button("模型核验…") { verifyingChannel = channel } }
                if !channel.manageURL.isEmpty {
                    Button("打开中转站后台") { store.openManagePage(channel) }
                }
                Divider()
                Button(channel.enabled ? "停用渠道" : "启用渠道") {
                    var value = channel; value.enabled.toggle()
                    Task { do { try await store.saveChannel(value) } catch { store.report(error) } }
                }
                Button("删除渠道…", role: .destructive) { deletingChannel = channel }
            } label: { Text("管理") }
                .fixedSize().disabled(store.busy)
                .accessibilityLabel("管理渠道：" + channel.name)
        }.padding(.vertical, 6)
    }

    private func accountHealth(_ account: Account) -> Color {
        if account.disabled { return mutedInk.opacity(0.5) }
        if store.accountRests[account.id]?.text() != nil { return warning }
        return account.requiresSignIn || account.status == "error" ? warning : healthy
    }

    private func accountRow(_ account: Account) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Circle().fill(accountHealth(account)).frame(width: 7, height: 7).padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(account.displayName).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                    if account.displayName != account.email {
                        Text(account.email).font(.system(size: 11)).foregroundStyle(mutedInk).textSelection(.enabled)
                    }
                    if account.managedByBridgeDock {
                        Pill(text: "BD 已保存", active: false)
                    }
                }
                Text([account.providerTitle, account.statusText, store.publicPrefix(source: "account:" + account.id).map { "调用名 " + $0 + "/…" } ?? store.poolLabel(account)].joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(account.requiresSignIn ? warning : mutedInk)
                    .help(account.name)
                if !account.statusMessage.isEmpty && (account.requiresSignIn || account.status == "error") {
                    Text(store.redacted(account.statusMessage)).font(.system(size: 11)).foregroundStyle(warning).lineLimit(3)
                }
                if !account.disabled, let rest = store.accountRests[account.id] {
                    // Counts down every second; the line disappears when the rest is over.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let text = rest.text(now: context.date) {
                            Text(text).font(.system(size: 11)).foregroundStyle(warning)
                                .help(rest.source == "kiro" ? "BridgeDock 的 Kiro 路由暂不向此账号分配新请求；进行中的会话由其他账号临时接手，冷却结束后回到原账号。"
                                      : "反代内核暂不向此账号分配新请求，到时自动恢复。")
                        }
                    }
                }
                QuotaSummaryView(target: QuotaTarget(account: account))
            }
            Spacer(minLength: 10)
            if store.accountOperation == account.id { ProgressView().controlSize(.small) }
            Menu {
                Button("账号设置…") { editing = account }
                Button("查看账号模型…") { inspecting = account }
                Button("刷新凭据") { Task { await store.refreshAccount(account) } }
                if store.accountRests[account.id]?.text() != nil {
                    Button("立即解除冷却") { Task { await store.endRest(account) } }
                }
                if let provider = SubscriptionProvider.find(account.loginProvider), !provider.importOnly {
                    if provider.supportsRecovery {
                        Button("重新授权此账号") { Task { await store.beginLogin(provider.id, account: account) } }
                            .disabled(store.login != nil || !provider.available)
                    } else if provider.id == CursorAccountProfile.providerID {
                        Button("更新账号凭据…") {
                            addingCursorProfile = CursorAccountProfile(rawValue: account.runtimeProfile) ?? .cursor
                            addingCursor = true
                        }.disabled(actionsDisabled)
                    } else {
                        Button("再次登录（添加凭据）") { Task { await store.beginLogin(provider.id) } }
                            .disabled(store.login != nil || !provider.available)
                    }
                }
                Divider()
                Button(account.disabled ? "启用账号" : "停用账号") { Task { await store.toggleAccount(account) } }
                Button("删除账号…", role: .destructive) { removing = account }
            } label: { Text("管理") }
                .fixedSize().disabled(!store.running || store.busy || store.accountOperation != nil)
                .accessibilityLabel("管理账号：" + account.displayName)
        }.padding(.vertical, 6)
    }
    private func workAccountRow(_ channel: Channel) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Circle().fill(channel.enabled ? healthy : mutedInk.opacity(0.5)).frame(width: 7, height: 7).padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                Text(channel.name).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                Text("Kimi Work · \(channel.enabled ? "可用" : "已停用") · \(store.publicPrefix(source: "channel:" + channel.id).map { "调用名 " + $0 + "/…" } ?? "前缀 " + channel.prefix) · \(channel.models.count) 个模型")
                    .font(.system(size: 11)).foregroundStyle(mutedInk)
                QuotaSummaryView(target: QuotaTarget(channel: channel))
            }
            Spacer(minLength: 10)
            Menu {
                Button("Work 设置与模型…") { editingWork = channel }
                Button("刷新模型") { Task { await store.refreshKimiWorkModels(channel) } }
                Button("重新网页登录") { addingKimiWork = true }
                    .disabled(!store.running)
                Divider()
                Button(channel.enabled ? "停用 Work" : "启用 Work") {
                    var value = channel
                    value.enabled.toggle()
                    Task { do { try await store.saveChannel(value) } catch { store.report(error) } }
                }
                Button("断开 Work 连接…", role: .destructive) { removingWork = channel }
            } label: { Text("管理") }
                .fixedSize().disabled(store.busy)
                .accessibilityLabel("管理 Work 连接：" + channel.name)
        }.padding(.vertical, 6)
    }

}

private struct CursorAccountView: View {
    let proxyURL: String
    @EnvironmentObject var store: BridgeStore
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var key = ""
    @State private var profile: CursorAccountProfile = .cursor
    @State private var saving = false
    @State private var message = ""

    init(proxyURL: String, initialProfile: CursorAccountProfile = .cursor) {
        self.proxyURL = proxyURL
        _profile = State(initialValue: initialProfile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("添加 \(profile.title) 账号").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }.disabled(saving)
            }
            Text("粘贴 Cursor 账号 Key 或会话凭据。支持“邮箱----user_…::令牌”、user_…::令牌及完整会话令牌。会话验证通过后保存，模型权限以账号实际返回为准。")
                .font(.system(size: 12)).foregroundStyle(mutedInk).lineSpacing(4)
            HStack {
                Button("Grok Bot 网页登录") {
                    Task {
                        await store.beginLogin(CursorAccountProfile.providerID, proxyURL: proxyURL)
                        if store.login != nil { dismiss() }
                    }
                }.disabled(saving || !store.running || store.busy || store.login != nil)
                Link("获取账号 Key", destination: CursorAccountProfile.dashboardURL)
            }.font(.system(size: 12))
            Picker("接入通道", selection: $profile) {
                ForEach(CursorAccountProfile.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 8) {
                Text("账号备注").font(.system(size: 12, weight: .medium))
                TextField("例如：工作账号（可选）", text: $label).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Cursor 账号凭据").font(.system(size: 12, weight: .medium))
                SecureField("粘贴账号 Key 或完整会话凭据", text: $key).textFieldStyle(.roundedBorder)
                Text("会话凭据到期后需要重新导入；账号 Key 可自动换取新令牌。")
                    .font(.system(size: 11)).foregroundStyle(mutedInk)
            }
            if !message.isEmpty { Text(message).font(.system(size: 12)).foregroundStyle(warning).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(saving ? "验证并保存中…" : "添加账号") { Task { await save() } }
                    .buttonStyle(WorkspaceButtonStyle(prominent: true))
                    .disabled(saving || !store.running || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(30).frame(width: 600).background(canvas).foregroundStyle(ink)
            .preferredColorScheme(.light).tint(accent).buttonStyle(WorkspaceButtonStyle())
    }

    private func save() async {
        saving = true
        message = ""
        defer { saving = false }
        do {
            try await store.addCursorAccount(label: label, key: key, profile: profile, proxyURL: proxyURL)
            key = ""
            dismiss()
        } catch {
            message = store.redacted(error.localizedDescription)
            if !key.isEmpty { message = message.replacingOccurrences(of: key, with: "••••••") }
        }
    }
}

private struct AccountOptionsView: View {
    @EnvironmentObject var store: BridgeStore
    @Environment(\.dismiss) private var dismiss
    let account: Account
    @State private var options: AccountOptions?
    @State private var loading = true
    @State private var saving = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("账号设置").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }.disabled(saving)
            }
            Text(account.email).font(.system(size: 12)).foregroundStyle(mutedInk).textSelection(.enabled)
            if loading { ProgressView("正在读取账号设置…").frame(maxWidth: .infinity, minHeight: 180) }
            if options != nil {
                settingsForm
            }
            if !message.isEmpty { Text(message).font(.system(size: 12)).foregroundStyle(warning).textSelection(.enabled) }
            HStack {
                if options == nil && !loading { Button("重新加载") { Task { await load() } } }
                Spacer()
                Button(saving ? "保存中…" : "保存设置") { Task { await save() } }
                    .buttonStyle(WorkspaceButtonStyle(prominent: true)).disabled(options == nil || loading || saving)
            }
        }.padding(30).frame(width: 600).background(canvas).foregroundStyle(ink)
            .preferredColorScheme(.light).tint(accent).buttonStyle(WorkspaceButtonStyle())
            .task { await load() }
    }

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("备注", text: option(\.note)).textFieldStyle(.roundedBorder)
            TextField("模型前缀（留空加入账号池）", text: option(\.prefix)).textFieldStyle(.roundedBorder)
            Text("留空或填写账号池的前缀时，这个账号留在同服务商的账号池里：新会话依次分到池里的各个账号，同一会话固定在一个账号，某个账号额度用完时它的会话自动换到其他账号。填写其他前缀后单独成组，只在调用“前缀/模型名”时使用。").font(.system(size: 11)).foregroundStyle(mutedInk).lineSpacing(3)
            HStack {
                Text("优先级")
                TextField("0", value: priority, format: .number).textFieldStyle(.roundedBorder).frame(width: 100)
                Text("数值越大越优先，同级账号轮流使用").font(.system(size: 11)).foregroundStyle(mutedInk)
            }
            SecureField("账号出站代理，留空继承全局代理", text: option(\.proxyURL)).textFieldStyle(.roundedBorder)
            Text("支持 HTTP(S)、SOCKS5 代理；填写 direct 可让这个账号直连。代理密码保存在本机私有数据目录。").font(.system(size: 11)).foregroundStyle(mutedInk).lineSpacing(3)
        }.font(.system(size: 12))
    }

    private func option(_ path: WritableKeyPath<AccountOptions, String>) -> Binding<String> {
        Binding(get: { options?[keyPath: path] ?? "" }, set: { options?[keyPath: path] = $0 })
    }
    private var priority: Binding<Int> {
        Binding(get: { options?.priority ?? 0 }, set: { options?.priority = $0 })
    }
    private func load() async {
        loading = true
        message = ""
        defer { loading = false }
        do { options = try await store.loadAccountOptions(account) }
        catch { message = store.redacted(error.localizedDescription) }
    }
    private func save() async {
        guard let options else { return }
        saving = true
        message = ""
        defer { saving = false }
        do { try await store.saveAccountOptions(account, options: options); dismiss() }
        catch { message = store.redacted(error.localizedDescription) }
    }
}

private struct AccountModelsView: View {
    @EnvironmentObject var store: BridgeStore
    @Environment(\.dismiss) private var dismiss
    let account: Account
    @State private var models: [String] = []
    @State private var loading = true
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("账号模型").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }
            }
            Text(account.displayName).font(.system(size: 12)).foregroundStyle(mutedInk)
            if loading { ProgressView("正在获取模型…").frame(maxWidth: .infinity, minHeight: 200) }
            else if !message.isEmpty { Text(message).font(.system(size: 12)).foregroundStyle(warning).textSelection(.enabled) }
            else if models.isEmpty { Text("该账号暂未注册可用模型，请检查授权状态后刷新。").font(.system(size: 12)).foregroundStyle(mutedInk) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(models, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }.frame(height: 290).background(insetSurface, in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Button("刷新") { Task { await load() } }.disabled(loading)
                Spacer()
                Button("复制模型列表") { store.copy(models.joined(separator: "\n")) }.disabled(models.isEmpty)
            }
        }.padding(30).frame(width: 600).background(canvas).foregroundStyle(ink)
            .preferredColorScheme(.light).tint(accent).buttonStyle(WorkspaceButtonStyle())
            .task { await load() }
    }
    private func load() async {
        loading = true
        message = ""
        defer { loading = false }
        do { models = try await store.loadAccountModels(account) }
        catch { message = store.redacted(error.localizedDescription) }
    }
}

struct QuotaSummaryView: View {
    @EnvironmentObject var store: BridgeStore
    let target: QuotaTarget
    private var state: QuotaState? {
        let value = store.quotaStates[target.id]
        return value?.fingerprint == target.fingerprint ? value : nil
    }
    var body: some View {
        Group {
            if !target.queryAvailable {
                Text(target.queryHint)
            } else if let metric = state?.snapshot.flatMap({ QuotaParser.displayMetrics($0).first }) {
                if metric.unlimited { Text("\(metric.title) · 无上限") }
                else if let remaining = metric.remainingAmount { Text("\(metric.title) · 剩余 \(QuotaParser.amount(remaining)) \(metric.unit)") }
                else if let percentage = metric.usedPercentage { Text("\(metric.title) · 已用 \(percentage.formatted(.number.precision(.fractionLength(0...1))))%") }
                else { Text("额度详情见「余额与额度」") }
            } else if state?.loading == true { Text("正在查询额度…") }
            else if state?.error != nil { Text("额度待确认 · 详情见「余额与额度」") }
            else { Text("尚未查询额度") }
        }.font(.system(size: 11)).foregroundStyle(state?.error != nil ? warning : (state?.snapshot == nil ? mutedInk : healthy))
    }
}

struct BalancesView: View {
    @EnvironmentObject var store: BridgeStore
    @State private var search = ""
    @State private var refreshingAll = false
    private func state(_ target: QuotaTarget) -> QuotaState? {
        let value = store.quotaStates[target.id]
        return value?.fingerprint == target.fingerprint ? value : nil
    }
    private func peak(_ target: QuotaTarget) -> Double {
        state(target)?.snapshot?.metrics.compactMap(\.usedPercentage).max() ?? -1
    }
    private var targets: [QuotaTarget] {
        store.quotaTargets
            .filter { search.isEmpty || ($0.title + $0.subtitle + $0.group).localizedCaseInsensitiveContains(search) }
            .enumerated().sorted { lhs, rhs in
                let a = peak(lhs.element) >= 90, b = peak(rhs.element) >= 90
                if a != b { return a }
                if a { return peak(lhs.element) > peak(rhs.element) }
                return lhs.offset < rhs.offset
            }.map(\.element)
    }
    private var groups: [(name: String, targets: [QuotaTarget])] {
        var order: [String] = []
        var members: [String: [QuotaTarget]] = [:]
        for target in targets {
            if members[target.group] == nil { order.append(target.group) }
            members[target.group, default: []].append(target)
        }
        let channels = "API 渠道"
        return (order.filter { $0 != channels } + order.filter { $0 == channels }).map { ($0, members[$0]!) }
    }
    private var nearlyExhausted: Int { store.quotaTargets.filter { peak($0) >= 90 }.count }
    private var failed: Int { store.quotaTargets.filter { state($0)?.error != nil }.count }
    private var unconfigured: Int { store.quotaTargets.filter { !$0.queryAvailable }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                summary("账号与渠道", "\(store.quotaTargets.count)", ink)
                summary("即将用完 · ≥90%", "\(nearlyExhausted)", nearlyExhausted > 0 ? warning : mutedInk)
                summary("查询出错", "\(failed)", failed > 0 ? failureTint : mutedInk)
                summary("未配置查询", "\(unconfigured)", unconfigured > 0 ? mutedInk : mutedInk.opacity(0.7))
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button(refreshingAll || store.quotaRefreshing ? "刷新中…" : "刷新全部") {
                        Task { refreshingAll = true; await store.refreshQuotas(force: true); refreshingAll = false }
                    }.disabled(!store.running || store.quotaRefreshing)
                    Text(store.running ? "运行时每 5 分钟自动更新" : "服务未运行，无法查询").captionText(10)
                }
            }
            SearchField(prompt: "搜索账号、渠道或服务商", text: $search)
            if store.quotaTargets.isEmpty {
                Card { Text("添加订阅账号或 API 渠道后，这里会逐项显示余额和额度。").captionText(14).padding(.vertical, 35) }
            } else if targets.isEmpty {
                Card {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 24)).foregroundStyle(mutedInk)
                        Text("没有匹配「\(search)」的账号或渠道").font(.system(size: 13, weight: .medium))
                        Text("试试服务商名称或更短的关键词。").captionText()
                    }.frame(maxWidth: .infinity).padding(.vertical, 30)
                }
            } else {
                ForEach(groups, id: \.name) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(group.name).sectionTitle()
                            Pill(text: "\(group.targets.count)", active: false)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)], spacing: 16) {
                            ForEach(group.targets) { target in QuotaCardView(target: target) }
                        }
                    }
                }
            }
        }.task { await store.refreshQuotas() }
    }

    private func summary(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).captionText(10)
            Text(value).font(.system(size: 20, weight: .medium)).monospacedDigit().foregroundStyle(color)
        }.padding(.horizontal, 16).padding(.vertical, 10).frame(minWidth: 120, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hairline.opacity(0.7)))
    }
}

struct QuotaCardView: View {
    @EnvironmentObject var store: BridgeStore
    let target: QuotaTarget
    @State private var requested = false
    private var state: QuotaState? {
        let value = store.quotaStates[target.id]
        return value?.fingerprint == target.fingerprint ? value : nil
    }
    private var loading: Bool { requested || state?.loading == true }
    var body: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(target.title).font(.system(size: 15, weight: .semibold)).lineLimit(1).textSelection(.enabled)
                        Text(target.subtitle).captionText()
                    }
                    Spacer()
                    if state?.error != nil && state?.snapshot != nil { Pill(text: "过期", tint: warning) }
                    if loading { ProgressView().controlSize(.small) }
                    Button("刷新") {
                        Task { requested = true; await store.refreshQuotas(force: true, only: target.id); requested = false }
                    }.disabled(!store.running || loading || !target.queryAvailable)
                        .help(store.running ? (store.quotaRefreshing && !loading ? "其他项目正在刷新，完成后再试" : "刷新此项") : "服务未运行")
                }
                if let error = state?.error {
                    Text((state?.snapshot == nil ? "" : "刷新失败，以下为上次成功数据。\n") + error)
                        .font(.system(size: 11)).foregroundStyle(failureTint).textSelection(.enabled)
                }
                if let snapshot = state?.snapshot {
                    if let plan = snapshot.plan { Pill(text: "套餐 · " + plan) }
                    ForEach(QuotaParser.displayMetrics(snapshot)) { metric in QuotaMetricView(metric: metric) }
                    ForEach(snapshot.details) { detail in
                        HStack(alignment: .top) {
                            Text(detail.label).foregroundStyle(mutedInk)
                            Spacer()
                            Text(detail.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }.font(.system(size: 11))
                    }
                    ForEach(snapshot.notes, id: \.self) { Text($0).captionText().textSelection(.enabled) }
                    HStack {
                        Text(snapshot.source)
                        Spacer()
                        Text("更新于 " + snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                    }.captionText(10).opacity(state?.error != nil ? 0.6 : 1)
                } else if !target.queryAvailable {
                    Text(target.queryHint).captionText(12)
                } else if state?.error == nil {
                    Text(loading ? "正在向服务商读取余额与额度…" : store.running ? "尚未查询" : "启动服务后查询").captionText(12)
                }
            }
        }
    }
}

struct QuotaMetricView: View {
    let metric: QuotaMetric
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(metric.title).font(.system(size: 12, weight: .medium))
                Spacer()
                if let percentage = metric.usedPercentage {
                    Text("已用 \(percentage.formatted(.number.precision(.fractionLength(0...1))))%")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(percentage >= 90 ? warning : healthy)
                }
            }
            if let percentage = metric.usedPercentage {
                ProgressView(value: min(100, max(0, percentage)), total: 100).tint(percentage >= 90 ? warning : healthy)
            }
            if metric.used != nil || metric.limit != nil {
                HStack(spacing: 16) {
                    amount("剩余", metric.remainingAmount, override: metric.unlimited ? "无上限" : nil)
                    amount("已使用", metric.used)
                    amount("总额度", metric.limit, override: metric.unlimited ? "无上限" : nil)
                }
            } else if metric.remaining != nil || metric.unlimited {
                Text(metric.unlimited ? "无上限" : QuotaParser.amount(metric.remaining!) + " " + metric.unit)
                    .font(.system(size: 18, weight: .medium)).textSelection(.enabled)
            } else if metric.usedPercentage == nil {
                Text("服务商未提供此项数值").captionText()
            }
            if let date = metric.reset { Text(metric.resetLabel + " · " + date.formatted(date: .abbreviated, time: .shortened)).captionText() }
            if !metric.note.isEmpty { Text(metric.note).font(.system(size: 11)).foregroundStyle(warning) }
        }.padding(12).background(insetSurface, in: RoundedRectangle(cornerRadius: 10))
    }
    private func amount(_ label: String, _ value: Decimal?, override: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).captionText(10)
            Text(override ?? value.map { QuotaParser.amount($0) + " " + metric.unit } ?? "未提供").font(.system(size: 12, weight: .medium)).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ModelsView: View {
    @EnvironmentObject var store: BridgeStore
    @State private var search = ""
    @State private var selectedModel = ""
    @State private var wire = "chat"
    @State private var testMode = ModelTestMode.quick
    @State private var effort = ModelReasoningEffort.medium
    @State private var providerKey = ""
    private var providers: [ModelPublishing.Provider] { store.providers(for: trimmedModel) }
    /// 所选供应商；未选或已失效时取第一个（默认供应商）。
    private var provider: ModelPublishing.Provider? { providers.first { $0.key == providerKey } ?? providers.first }
    private var filtered: [ModelItem] {
        store.models.filter { search.isEmpty || ($0.id + " " + $0.owner).localizedCaseInsensitiveContains(search) }
    }
    private var trimmedModel: String { selectedModel.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 只列出所选供应商声明支持的推理强度；能力未知时保留全部选项。
    private var efforts: [ModelReasoningEffort] {
        guard let declared = provider?.capability?.reasoningEfforts else { return ModelReasoningEffort.allCases }
        return [.unset] + declared.filter { $0 != "none" }.map(ModelReasoningEffort.init(rawValue:))
    }
    private func effortTitle(_ value: ModelReasoningEffort) -> String {
        value == .unset ? value.title : provider?.capability?.label(ofEffort: value.rawValue) ?? value.rawValue
    }
    private var startBlocker: String? {
        if !store.running { return "服务未运行" }
        if trimmedModel.isEmpty { return "请先在左侧选择模型" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !store.running { serviceBanner }
            HStack(alignment: .top, spacing: 18) {
                modelList.frame(width: 300)
                testPanel.frame(maxWidth: .infinity)
            }
        }
        .onAppear { if trimmedModel.isEmpty, let first = store.models.first { selectedModel = first.id } }
        .onChange(of: selectedModel) { _, _ in providerKey = providers.first?.key ?? ""; clampEffort() }
        .onChange(of: providerKey) { _, _ in clampEffort() }
    }

    private func clampEffort() {
        if !efforts.contains(effort) { effort = efforts.last ?? .unset }
    }

    private var serviceBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill").font(.system(size: 16)).foregroundStyle(warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("服务未运行").font(.system(size: 13, weight: .semibold))
                Text("检测请求需经过本机反代 127.0.0.1:\(String(store.settings.port))，启动后即可测试。").captionText()
            }
            Spacer()
            Button("启动服务") { Task { await store.start() } }.buttonStyle(WorkspaceButtonStyle(prominent: true)).disabled(store.busy)
        }.padding(14).background(warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(warning.opacity(0.25)))
    }

    private var modelList: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("已发布模型").sectionTitle()
                    Spacer()
                    Text(search.isEmpty ? "\(store.models.count) 个" : "\(filtered.count) / \(store.models.count)").captionText().monospacedDigit()
                }
                SearchField(prompt: "搜索模型或渠道", text: $search)
                if filtered.isEmpty { emptyList }
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { model in row(model) }
                }
            }
        }
    }

    private var emptyList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.availableModels.isEmpty ? "暂无模型。先在「账号与渠道」添加 API 渠道或登录账号。"
                 : (search.isEmpty ? "尚未发布模型，勾选要使用的模型后即可在这里测试。" : "没有匹配「\(search)」的已发布模型。"))
                .captionText(12).fixedSize(horizontal: false, vertical: true)
            if search.isEmpty && !store.availableModels.isEmpty { ModelPublicationButton(title: "选择反代模型") }
        }.padding(.vertical, 16)
    }

    private func row(_ model: ModelItem) -> some View {
        let active = model.id == trimmedModel
        return Button { selectedModel = model.id } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(active ? accent : Color.clear).frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.id).monoSmall(12).fontWeight(active ? .semibold : .regular).lineLimit(1).truncationMode(.middle)
                    providerTags(model)
                }
                Spacer(minLength: 0)
            }.padding(.trailing, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                .background(active ? accent.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(store.testing)
            .help(model.id + "\n" + ModelPublishing.capabilitySummary(store.providers(for: model.id).first?.capability))
            .contextMenu { Button("复制模型 ID") { store.copy(model.id) } }
    }

    private func providerTags(_ model: ModelItem) -> some View {
        let names = model.owner.components(separatedBy: " / ").filter { !$0.isEmpty }
        return HStack(spacing: 4) {
            ForEach(Array(names.prefix(2).enumerated()), id: \.offset) { _, name in
                Text(name).font(.system(size: 10, weight: .medium)).foregroundStyle(mutedInk).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color.gray.opacity(0.1), in: Capsule())
            }
            if names.count > 2 { Text("+\(names.count - 2)").captionText(10) }
        }.help(model.owner)
    }

    private var testPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(padding: 22) {
                VStack(alignment: .leading, spacing: 22) {
                    step(1, "测试哪个模型") { modelSection }
                    Divider().opacity(0.5)
                    step(2, "怎么测") { modeCards }
                    Divider().opacity(0.5)
                    step(3, "请求设置") { requestSettings }
                    Divider().opacity(0.5)
                    actionBar
                }
            }
            if let report = store.testReport { ModelDiagnosticResultView(report: report) }
            if store.parameterProbing || !store.parameterProbe.isEmpty || !store.gatewayAdjustments.isEmpty {
                ParameterProbeView(model: trimmedModel).environmentObject(store)
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("从左侧选择，或直接填写模型 ID", text: $selectedModel).textFieldStyle(.roundedBorder).monoSmall(12)
                .disabled(store.testing).accessibilityIdentifier("model-test-id")
            if !providers.isEmpty {
                HStack(spacing: 10) {
                    Text("供应商").captionText(12)
                    if providers.count < 2, let provider {
                        Text(provider.name).font(.system(size: 12, weight: .medium))
                    } else {
                        Picker("供应商", selection: Binding(get: { provider?.key ?? "" }, set: { providerKey = $0 })) {
                            ForEach(Array(providers.enumerated()), id: \.element.key) { index, item in
                                Text(item.name + (index == 0 ? "（默认）" : "")).tag(item.key)
                            }
                        }.labelsHidden().disabled(store.testing).frame(maxWidth: 260, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }.accessibilityIdentifier("model-test-provider")
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 10))
                    Text(capabilityLine).lineLimit(2)
                }.captionText(11)
            }
        }
    }

    private var capabilityLine: String {
        var parts = [ModelPublishing.capabilitySummary(provider?.capability)]
        if let provider, provider.model.cursorRoute == nil, provider.model.workModel == nil {
            parts.append(provider.contextOptions.isEmpty ? "尚未实测长上下文"
                         : "实测上下文 " + provider.contextOptions.map(ModelPublishing.tokenLabel).joined(separator: " / "))
        }
        return parts.joined(separator: " · ")
    }

    private var modeCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(ModelTestMode.allCases) { mode in modeCard(mode) }
            }.accessibilityIdentifier("model-test-mode")
            Text(testMode.detail).captionText().fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modeCard(_ mode: ModelTestMode) -> some View {
        let active = mode == testMode
        return Button { testMode = mode } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: mode.symbol).font(.system(size: 15)).frame(width: 22, height: 22)
                    .foregroundStyle(active ? accent : mutedInk)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                    Text(mode.summary).captionText(11)
                    Text(mode.cost).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(mode == .longContext ? warning : mutedInk.opacity(0.85))
                }
                Spacer(minLength: 0)
                Image(systemName: active ? "checkmark.circle.fill" : "circle").foregroundStyle(active ? accent : hairline)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(active ? accent.opacity(0.06) : insetSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(active ? accent.opacity(0.45) : hairline.opacity(0.7)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(store.testing)
    }

    private var requestSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("协议") {
                Picker("协议", selection: $wire) {
                    Text("Chat Completions").tag("chat"); Text("Responses").tag("responses"); Text("Anthropic Messages").tag("anthropic")
                }.pickerStyle(.segmented).labelsHidden().disabled(store.testing).frame(maxWidth: 460)
                Text(wireHint).captionText(10)
            }
            if testMode == .reasoning {
                field("推理强度") {
                    Picker("推理强度", selection: $effort) {
                        ForEach(efforts) { value in Text(effortTitle(value)).tag(value) }
                    }.pickerStyle(.segmented).labelsHidden().disabled(store.testing).frame(maxWidth: 460)
                        .accessibilityIdentifier("model-test-effort")
                    Text(efforts == [.unset] ? "该模型未声明可调推理强度。" : "与官方渠道用同一强度对比，才能看出是否降智。").captionText(10)
                }
            }
        }
    }

    private var wireHint: String {
        switch wire {
        case "responses": return "Codex 等使用 OpenAI Responses 接口的工具选这个。"
        case "anthropic": return "Claude Code、Claude Desktop 选这个；降智检测时还会核对 thinking 签名。"
        default: return "大多数 OpenAI 兼容工具选这个。"
        }
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if let blocker = startBlocker, !store.testing {
                        Label(blocker, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(warning)
                    } else {
                        Text(trimmedModel.isEmpty ? "—" : trimmedModel).monoSmall(12).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        Text(testMode.title + " · " + testMode.cost + " · 真实请求会消耗额度").captionText(10)
                    }
                }
                Spacer()
                if store.parameterProbing {
                    Button { store.cancelParameterProbe() } label: { Label("停止实测", systemImage: "stop.fill") }
                } else if !store.testing {
                    Button { store.startParameterProbe(trimmedModel) } label: { Label("参数实测", systemImage: "slider.horizontal.3") }
                        .buttonStyle(WorkspaceButtonStyle())
                        .disabled(!store.running || providers.isEmpty)
                        .help("对该模型每个供应商的每个思考档位各发一条小请求，核对实际落到的供应商和生效档位；会消耗少量额度")
                        .accessibilityIdentifier("model-parameter-probe")
                }
                if store.testing {
                    Button { store.cancelModelTest() } label: { Label("取消测试", systemImage: "stop.fill") }
                } else {
                    Button { store.startModelTest(trimmedModel, wire: wire, mode: testMode, effort: effort, provider: provider?.key) } label: {
                        Label(store.testReport == nil ? "开始测试" : "重新测试", systemImage: "play.fill").padding(.horizontal, 6)
                    }
                    .buttonStyle(WorkspaceButtonStyle(prominent: true)).disabled(startBlocker != nil)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("⌘↩ 开始测试")
                    .accessibilityIdentifier("model-test-start")
                }
            }
            if store.testing, let report = store.testReport {
                ProgressView(value: Double(report.samples.count), total: Double(max(report.plannedCount, 1))).tint(accent)
            }
            if !store.testResult.isEmpty { resultStatus }
        }
    }

    private var resultStatus: some View {
        let report = store.testReport
        let tone: NoticeTone
        if store.testing || report == nil || report?.cancelled == true { tone = .info }
        else if let report, report.successful == report.samples.count, !report.samples.isEmpty { tone = .success }
        else { tone = .failure }
        return HStack(spacing: 8) {
            if store.testing { ProgressView().controlSize(.small) }
            NoticeBanner(text: store.testResult, tone: tone)
        }
    }

    private func step<Content: View>(_ index: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(String(index)).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(accent)
                .frame(width: 22, height: 22).background(accent.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 10) {
                Text(title).sectionTitle()
                content()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(mutedInk)
            content()
        }
    }
}

struct ClientsView: View {
    @EnvironmentObject var store: BridgeStore
    @State private var tool: ClientTool = .claudeDesktop
    @State private var model = ""
    @State private var context = "32768"
    @State private var visible = false
    @State private var message = ""
    @State private var messageTone = NoticeTone.success
    @State private var filePath = ""
    @State private var confirmingApply = false
    @State private var confirmingRestore = false
    var profile: ConnectionProfile { ConnectionProfile(tool: tool, baseURL: store.baseURL, key: store.settings.clientKey, model: model, contextSize: max(1, Int(context) ?? 32768)) }
    private var applyBlocker: String? {
        if !store.running { return "服务未运行，先启动服务" }
        if model.isEmpty { return "请先选择模型" }
        if filePath.isEmpty { return "请填写配置文件路径" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            toolGrid
            if tool == .cursor {
                CursorChineseCard()
                CursorLocalView()
            } else {
                statusCard
                if tool != .kiro { modelCard }
                connectionCard
            }
        }.onAppear { resetPath(); model = store.settings.selectedModels[tool.rawValue] ?? "" }
            .confirmationDialog("将应用连接配置，并备份目标文件。", isPresented: $confirmingApply) {
                Button("备份并应用") { apply() }
            } message: { Text(filePath + "\n模型 · " + model) }
            .confirmationDialog("恢复本工具上一次应用之前的配置？", isPresented: $confirmingRestore) {
                Button("恢复配置") {
                    do { try ConfigurationInstaller(directory: store.dataDirectory).restore(URL(fileURLWithPath: filePath)); notify("已恢复上一次配置。"); store.record("已恢复 \(tool.rawValue) 配置") }
                    catch { notify(store.redacted(error.localizedDescription), .failure); store.report(error) }
                }
            }
    }

    private var toolGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
            ForEach(ClientTool.allCases) { item in
                Button { select(item) } label: {
                    HStack(spacing: 12) {
                        if let logo = item.brandIcon {
                            Image(nsImage: logo).renderingMode(.original).resizable().scaledToFit()
                                .frame(width: 36, height: 36).accessibilityHidden(true)
                        } else {
                            Image(systemName: item.symbol).font(.system(size: 22)).frame(width: 36, height: 36).accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.rawValue).font(.system(size: 13, weight: .semibold))
                            if let hint = hint(item) { Text(hint).font(.system(size: 10)) }
                        }
                        Spacer(minLength: 0)
                        if store.settings.selectedModels[item.rawValue] != nil { Circle().fill(healthy).frame(width: 6, height: 6).help("已应用过模型") }
                    }
                    .padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 76).foregroundStyle(tool == item ? accent : mutedInk)
                    .background(tool == item ? accent.opacity(0.08) : panel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tool == item ? accent.opacity(0.35) : hairline.opacity(0.75)))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(item.rawValue)
            }
        }
    }

    private func hint(_ item: ClientTool) -> String? {
        switch item {
        case .cursor: return "反代 / 官方账号"
        case .claudeDesktop: return "桌面端 · Chat / Cowork"
        case .claude, .codex, .kimi: return "可直接写入配置"
        case .kiro: return "查看接入说明"
        default: return "手动粘贴配置"
        }
    }

    private var statusCard: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("状态").sectionTitle(); Spacer() }
                HStack(spacing: 8) {
                    Circle().fill(store.running ? healthy : warning).frame(width: 7, height: 7)
                    Text(store.running ? "本机服务运行中 · " + store.baseURL : "服务未运行，工具暂时无法连接").font(.system(size: 12))
                    Spacer()
                    if !store.running { Button("启动服务") { Task { await store.start() } }.disabled(store.busy) }
                }
                if let saved = store.settings.selectedModels[tool.rawValue] {
                    Text("上次应用的模型 · " + saved).monoSmall().foregroundStyle(mutedInk).textSelection(.enabled)
                } else if tool.file != nil {
                    Text("尚未通过 BridgeDock 应用配置。").captionText()
                }
            }
        }
    }

    private var modelCard: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("模型").sectionTitle(); Spacer(); Pill(text: "每个工具独立配置", active: false) }
                HStack {
                    TextField("填写已开放的模型名", text: $model).textFieldStyle(.roundedBorder).monoSmall(12)
                    Menu("从目录选择") { ForEach(store.models) { item in Button(item.id) { model = item.id } } }
                        .disabled(store.models.isEmpty).frame(width: 130)
                }
                if store.models.isEmpty { Text("尚未发布模型，点击顶栏「模型」勾选后可从目录选择。").captionText() }
                if tool == .kimi { TextField("模型上下文长度（按服务商填写）", text: $context).textFieldStyle(.roundedBorder) }
            }
        }
    }

    private var steps: [String] {
        if tool.file != nil {
            return ["在上方选择模型，确认下方配置文件路径。",
                    "点击「应用到工具」，BridgeDock 会先备份现有文件，再合并模型连接字段。",
                    "重新启动 \(tool.rawValue) 的会话。项目级配置或终端环境变量可能优先于此配置。"]
        }
        if tool == .claudeDesktop {
            return ["在 Claude 中打开 Help → Troubleshooting → Enable Developer Mode，然后重启。",
                    "选择 Developer → Configure Third-Party Inference，选择 Gateway 与 Static API key。",
                    "填入下方网关地址、本地密钥和模型 ID，测试连接并应用，再重启 Claude。",
                    "建议先在「模型与测试」中用 Anthropic Messages 协议验证模型。"]
        }
        if tool == .kiro { return [] }
        return ["在目标工具的模型服务商设置中新增 OpenAI 兼容服务商。", "粘贴下方地址、密钥和模型名，保存后刷新模型列表。"]
    }

    private var connectionCard: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(tool == .kiro ? "Kiro 接入说明" : "连接配置").sectionTitle()
                    Spacer()
                    if tool != .kiro { Toggle("显示本地密钥", isOn: $visible).toggleStyle(.checkbox).font(.system(size: 11)) }
                }
                if !steps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
                                    .frame(width: 18, height: 18).background(accent.opacity(0.1), in: Circle())
                                Text(step).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if tool.file != nil {
                    HStack { TextField("配置文件", text: $filePath).textFieldStyle(.roundedBorder).monoSmall(); Button("选择文件") { chooseFile() } }
                }
                if tool == .claudeDesktop {
                    HStack {
                        Button("打开 Claude") { Task { await store.openClaudeDesktop() } }.disabled(store.launchingAgent || store.busy)
                        Link("官方配置说明", destination: URL(string: "https://claude.com/docs/third-party/claude-desktop/gateway")!).font(.system(size: 12))
                    }
                }
                Text(visible ? profile.snippet : profile.snippet.replacingOccurrences(of: store.settings.clientKey, with: "••••••••（复制时包含完整密钥）"))
                    .monoSmall(12).textSelection(.enabled).lineSpacing(5)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(insetSurface, in: RoundedRectangle(cornerRadius: 10))
                if tool != .kiro { actions }
                if !message.isEmpty { NoticeBanner(text: message, tone: messageTone) }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Menu("更多") {
                Button("复制配置") { store.copy(profile.snippet); notify("配置已复制，包含本地连接密钥。") }
                if tool == .claudeDesktop {
                    Button("复制地址") { store.copy(store.baseURL); notify("网关地址已复制。") }
                    Button("复制密钥") { store.copy(store.settings.clientKey); notify("本地连接密钥已复制。") }
                    Button("复制模型 ID") { store.copy(model); notify("模型 ID 已复制。") }.disabled(model.isEmpty)
                }
                if !profile.command.isEmpty {
                    Button(tool == .kimi ? "复制启动命令（先应用配置）" : "复制临时启动命令") { store.copy(profile.command); notify("启动命令已复制。") }
                }
                Divider()
                Button("导出配置文件…") { exportProfile() }
                if tool.file != nil { Button("恢复上一次配置…") { confirmingRestore = true } }
            }.menuStyle(.borderlessButton).fixedSize()
            Spacer()
            if tool.file != nil {
                if let blocker = applyBlocker { Text(blocker).captionText() }
                Button("应用到工具") { confirmingApply = true }
                    .buttonStyle(WorkspaceButtonStyle(prominent: true)).disabled(applyBlocker != nil)
            } else {
                Button("复制配置") { store.copy(profile.snippet); notify("配置已复制，包含本地连接密钥。") }
                    .buttonStyle(WorkspaceButtonStyle(prominent: true))
            }
        }
    }

    private func select(_ item: ClientTool) {
        tool = item; message = ""; resetPath(); model = store.settings.selectedModels[item.rawValue] ?? ""
    }
    private func notify(_ text: String, _ tone: NoticeTone = .success) { message = text; messageTone = tone }
    private func resetPath() {
        filePath = tool.file.map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).path } ?? ""
        if tool == .kimi { context = String(BridgeStore.managedContextSize(at: URL(fileURLWithPath: filePath)) ?? 32768) }
    }
    private func chooseFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { filePath = url.path }
    }
    private func apply() {
        do {
            guard filePath.hasPrefix("/") else { throw BridgeError.message("请填写完整的绝对路径。") }
            try ConfigurationInstaller(directory: store.dataDirectory).apply(profile, to: URL(fileURLWithPath: filePath))
            notify("已备份并应用。请重新启动 \(tool.rawValue) 的会话。")
            store.record("已应用 \(tool.rawValue) 配置 · \(model)")
            var next = store.settings; next.selectedModels[tool.rawValue] = model
            Task { do { try await store.update(next) } catch { store.report(error) } }
        } catch { notify(store.redacted(error.localizedDescription), .failure); store.report(error) }
    }
    private func exportProfile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tool == .claude ? "bridgedock-claude.json" : "bridgedock-\(tool.id).txt"
        if [.codex, .kimi].contains(tool) { panel.nameFieldStringValue = "bridgedock-\(tool.id).toml" }
        if panel.runModal() == .OK, let url = panel.url {
            do { try privateWrite(Data(profile.snippet.utf8), to: url); notify("已导出，文件包含本地连接密钥。") }
            catch { notify(store.redacted(error.localizedDescription), .failure); store.report(error) }
        }
    }
}

struct CursorLocalView: View {
    @EnvironmentObject var store: BridgeStore
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(accent)
                    Text("Cursor 连接方式").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if store.cursorBusy { ProgressView().controlSize(.small) }
                    Toggle("使用 BD 反代", isOn: Binding(get: { store.cursorToggleEnabled }, set: { enabled in
                        Task { await store.setCursorLocalEnabled(enabled) }
                    })).toggleStyle(.switch).disabled(store.cursorBusy || store.busy || store.launchingAgent)
                        .help("首次开启会自动备份并适配 Cursor；关闭后保留适配，恢复使用原来的官方账号。")
                }
                Text("打开开关，使用 BridgeDock 中接入的模型；关闭开关，使用 Cursor 原来的官方账号。")
                    .font(.system(size: 12)).foregroundStyle(mutedInk)
                HStack {
                    Text("当前：" + store.cursorModeTitle).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(store.cursorStatus).font(.system(size: 11)).foregroundStyle(mutedInk)
                }
                if store.cursorNeedsRecovery {
                    HStack {
                        Text("开关显示实际连接状态；上次的 BD 模式选择已保留。")
                            .font(.system(size: 11)).foregroundStyle(mutedInk)
                        Spacer()
                        Button("重试连接") { Task { await store.setCursorLocalEnabled(true) } }
                        Button("使用官方账号") { Task { await store.setCursorLocalEnabled(false) } }
                    }.disabled(store.busy || store.launchingAgent)
                }
                Divider().opacity(0.25)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("在 Cursor 中调整模型参数").font(.system(size: 13, weight: .medium))
                        Text("开启后点击 Cursor 输入框中的模型按钮，直接调整当前渠道支持的参数。Cursor 账号模型沿用官方档位，其他渠道显示思考档位和上下文预算。")
                            .font(.system(size: 11)).foregroundStyle(mutedInk)
                    }
                    Spacer()
                    Toggle("模型参数补丁", isOn: Binding(get: { store.cursorIdentity.modelParametersEnabled }, set: { enabled in
                        Task { await store.setCursorModelParametersEnabled(enabled) }
                    })).labelsHidden().toggleStyle(.switch)
                        .disabled(store.cursorBusy || store.busy || store.launchingAgent)
                }
                HStack {
                    Text("切换时会正常重启 Cursor。如出现保存提示，请在 Cursor 中处理。")
                        .font(.system(size: 10)).foregroundStyle(mutedInk)
                    Spacer()
                    Button("打开 Cursor 主窗口") { Task { await store.openCursorWindow() } }
                        .buttonStyle(WorkspaceButtonStyle(prominent: true)).disabled(store.cursorBusy || store.busy || store.launchingAgent)
                }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: BridgeStore
    @State private var port = ""
    @State private var proxy = ""
    @State private var startURL = ""
    @State private var region = ""
    @State private var saved = false
    var body: some View {
        VStack(spacing: 28) {
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    Text("本地服务").font(.system(size: 15, weight: .semibold))
                    Form {
                        TextField("监听端口", text: $port).disabled(store.running)
                        TextField("出站网络代理", text: $proxy, prompt: Text("例如 socks5://127.0.0.1:1080，留空为直连"))
                        TextField("Kiro 组织 Start URL", text: $startURL, prompt: Text("个人 Builder ID 账号留空"))
                        TextField("Kiro 组织区域", text: $region)
                    }.textFieldStyle(.roundedBorder)
                    Text("监听地址固定为 127.0.0.1。修改端口前请停止服务；修改后需要重新应用工具配置。订阅登录与模型请求可使用出站代理。").font(.system(size: 11)).foregroundStyle(mutedInk).lineSpacing(4)
                    HStack {
                        Button("保存设置") {
                            var next = store.settings; next.port = Int(port) ?? 0; next.proxyURL = proxy.trimmingCharacters(in: .whitespacesAndNewlines); next.kiroStartURL = startURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            let trimmedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines)
                            next.kiroRegion = trimmedRegion.isEmpty ? "us-east-1" : trimmedRegion
                            Task { do { try await store.update(next); saved = true; store.record("本地服务设置已保存") } catch { store.report(error) } }
                        }.buttonStyle(WorkspaceButtonStyle(prominent: true)).disabled(store.busy)
                        if saved { Text("已保存").font(.system(size: 12)).foregroundStyle(accent) }
                        Spacer()
                        Button("打开数据与备份目录") { store.showDataDirectory() }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("中转站一键导入").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Toggle("接管 CC Switch 导入链接", isOn: Binding(get: { store.settings.handlesImportLinks }, set: { enabled in
                            Task { await store.setHandlesImportLinks(enabled) }
                        })).toggleStyle(.switch).disabled(store.busy)
                    }
                    Text("Sub2API、New API 等中转站的令牌页有“导入 CC Switch”按钮。开启后点击该按钮，BridgeDock 自动识别地址、Key、协议和模型，直接存成 API 渠道，经本地反代使用，并记住中转站后台地址。识别不全时才打开编辑器补充。")
                        .font(.system(size: 12)).foregroundStyle(mutedInk).lineSpacing(5)
                    Text(store.importLinkStatus).font(.system(size: 11)).foregroundStyle(mutedInk).textSelection(.enabled)
                }
            }.onAppear { store.refreshImportLinkStatus() }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("本地数据与内核").font(.system(size: 14, weight: .semibold))
                    Text(store.dataDirectory.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(mutedInk)
                    Text("API Key 和订阅凭据以本地文件保存，数据目录仅当前用户可读写。配置导出会包含本地连接密钥。关闭窗口后服务继续运行，可从菜单栏返回；退出 App 时停止内核。").font(.system(size: 12)).foregroundStyle(mutedInk).lineSpacing(5)
                    HStack { Pill(text: "CLIProxyAPI 8.0.53", active: false); Pill(text: "Kiro Plugin 0.1.1", active: false); Pill(text: "kiro2cc 3.5.1", active: false); Pill(text: "MIT", active: false) }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 22) {
                    HStack { Text("本次运行记录").font(.system(size: 14, weight: .semibold)); Spacer(); Button("清空") { store.activities.removeAll() } }
                    if store.activities.isEmpty { Text("暂无操作记录").foregroundStyle(mutedInk).font(.system(size: 12)) }
                    ForEach(store.activities.prefix(25)) { event in
                        HStack(alignment: .top, spacing: 12) {
                            Text(event.date, style: .time).font(.system(size: 10, design: .monospaced)).foregroundStyle(mutedInk).frame(width: 65, alignment: .leading)
                            Circle().fill(event.failed ? warning : healthy).frame(width: 5, height: 5).padding(.top, 5)
                            Text(event.message).font(.system(size: 12)).foregroundStyle(event.failed ? warning : ink).textSelection(.enabled)
                            Spacer()
                        }
                    }
                }
            }
        }.onAppear { port = String(store.settings.port); proxy = store.settings.proxyURL; startURL = store.settings.kiroStartURL; region = store.settings.kiroRegion }
    }
}
