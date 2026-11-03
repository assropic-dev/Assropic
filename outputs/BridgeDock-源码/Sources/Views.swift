import SwiftUI
import AppKit

enum Destination: String, CaseIterable, Identifiable {
    case overview = "总览", accounts = "订阅账号", channels = "API 渠道", models = "模型与测试", clients = "工具接入", balances = "余额与额度", settings = "设置与诊断"
    var id: String { rawValue }
    static let sections: [(title: String, items: [Destination])] = [
        ("", [.overview]),
        ("接入来源", [.accounts, .channels]),
        ("使用", [.models, .clients, .balances]),
        ("系统", [.settings])
    ]
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .channels: return "point.3.connected.trianglepath.dotted"
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
        case .channels: return "添加官方 API、Coding Plan 或第三方中转站。"
        case .accounts: return "通过浏览器授权接入订阅账号，凭据保存在本机。"
        case .balances: return "逐账号查看余额、周期额度、用量和重置时间。"
        case .models: return "检查模型联通程度、路由标识与实际回答表现。"
        case .clients: return "选择模型，再将本地接口接入你的编程工具。"
        case .settings: return "管理本地端口、出站代理与配置备份。"
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(hairline.opacity(0.75), lineWidth: 1))
            .shadow(color: ink.opacity(0.025), radius: 8, x: 0, y: 3)
    }
}

struct Pill: View {
    let text: String
    var active = true
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium))
            .foregroundStyle(active ? accent : mutedInk)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background((active ? accent : Color.gray).opacity(0.1), in: Capsule())
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
                        case .channels: ChannelsView()
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
    }

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
        case .accounts: count = store.accounts.count + store.settings.channels.filter(\.isKimiWork).count
        case .channels: count = store.settings.channels.filter { !$0.isKimiWork }.count
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
                    statistic("API 渠道", String(store.settings.channels.filter { $0.enabled && !$0.isKimiWork }.count), "network", .channels)
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

struct ChannelsView: View {
    @EnvironmentObject var store: BridgeStore
    @State private var editing: Channel?
    @State private var deleting: Channel?
    private var channels: [Channel] { store.settings.channels.filter { !$0.isKimiWork } }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("已添加渠道 · \(channels.count)").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        if store.settings.channels.contains(where: \.isKimiWork) {
                            Text("Kimi Work 在“订阅账号”中管理").font(.system(size: 11)).foregroundStyle(mutedInk)
                        }
                    }.padding(.bottom, 8)
                    if channels.isEmpty {
                        Text("还没有添加 API 渠道。从下方选择服务商，填入 Key 即可。每个渠道都有独立的地址、密钥、前缀和模型别名。")
                            .font(.system(size: 12)).foregroundStyle(mutedInk).padding(.vertical, 18)
                    }
                    ForEach(channels) { channel in
                        Divider().opacity(0.3)
                        channelRow(channel)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("添加渠道").font(.system(size: 16, weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(Preset.all) { preset in
                        Button {
                            editing = preset.makeChannel(existing: store.settings.channels, accounts: store.accounts)
                        } label: {
                            HStack {
                                Text(preset.title).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                Image(systemName: "plus").foregroundStyle(accent)
                            }.padding(.horizontal, 12).padding(.vertical, 11)
                                .background(panel, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(hairline.opacity(0.7)))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.sheet(item: $editing) { channel in ChannelEditor(channel: channel) }
            .confirmationDialog("删除这个 API 渠道？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("删除渠道", role: .destructive) { if let value = deleting { Task { await store.deleteChannel(value) } }; deleting = nil }
            }
    }

    private func channelRow(_ channel: Channel) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Circle().fill(channel.enabled ? healthy : mutedInk.opacity(0.5)).frame(width: 7, height: 7).padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(channel.name).font(.system(size: 13, weight: .medium))
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
            Button("编辑") { editing = channel }
            Menu {
                Button(channel.enabled ? "停用渠道" : "启用渠道") {
                    var value = channel; value.enabled.toggle()
                    Task { do { try await store.saveChannel(value) } catch { store.report(error) } }
                }
                Divider()
                Button("删除渠道…", role: .destructive) { deleting = channel }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(store.busy).accessibilityLabel("更多操作：" + channel.name)
        }.padding(.vertical, 8)
    }
}

struct ChannelEditor: View {
    @EnvironmentObject var store: BridgeStore
    @Environment(\.dismiss) private var dismiss
    @State var channel: Channel
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
        guard let preset, preset.id != "relay",
              let expected = URL(string: preset.url), let actual = URL(string: channel.baseURL),
              expected.host?.lowercased() == actual.host?.lowercased(),
              actual.scheme?.lowercased() == "https" else { return false }
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
                Text("配置 API 渠道").font(.system(size: 24, weight: .regular, design: .serif))
                Spacer()
                Button("取消") { cancelLookup(); dismiss() }.disabled(saving)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if channel.isKimiWork {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Kimi Work · 本机桌面登录").font(.system(size: 13, weight: .semibold))
                            Text("本机 Work 凭据由 Kimi 桌面端维护，无需填写 API Key。此渠道使用 Work 独立网关和会员月度共享额度；Code 的 5 小时 / 周限制不作为该通道的额度，但仍受上游实际限制。")
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
                                Text("由本机 Kimi 桌面端维护").font(.system(size: 12)).foregroundStyle(mutedInk).frame(height: 32)
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
                    Text(channel.isKimiWork ? "从当前本机 Work 登录获取模型，实际可用性以上游返回为准。查询失败会保留当前模型，你编辑的模型和别名不会被自动覆盖。" : "查询失败会保留当前模型。官方预设仅作默认配置，实际权限以服务商返回及模型测试结果为准；你编辑的模型和别名不会被自动覆盖。")
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
    @State private var providerFilter = ""
    @State private var loginProxy = ""
    @State private var kiroMethod = "builder-id"
    @State private var addingCursor = false
    @State private var addingKiro = false
    @State private var editingWork: Channel?
    @State private var removingWork: Channel?

    private func isKimiAccount(_ account: Account) -> Bool {
        ["kimi", "kimi-ai"].contains(SubscriptionProvider.find(account.loginProvider)?.id ?? account.provider)
    }

    private var workChannels: [Channel] { store.settings.channels.filter(\.isKimiWork) }
    private var visibleWorkChannels: [Channel] {
        guard providerFilter.isEmpty || providerFilter == "kimi-family" else { return [] }
        return workChannels.filter { channel in
            search.isEmpty || [channel.name, channel.prefix, "Kimi Work 本机桌面登录 会员月度共享额度"]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
    private var connectedCount: Int { store.accounts.count + workChannels.count }

    private var accountGroups: [(title: String, accounts: [Account], work: [Channel])] {
        var groups: [(title: String, accounts: [Account], work: [Channel])] = []
        let kimi = visibleAccounts.filter(isKimiAccount)
        if !kimi.isEmpty || !visibleWorkChannels.isEmpty { groups.append(("Kimi · Code / Work", kimi, visibleWorkChannels)) }
        var titles: [String] = []
        var byTitle: [String: [Account]] = [:]
        for account in visibleAccounts where !isKimiAccount(account) {
            let title = account.providerTitle
            if byTitle[title] == nil { titles.append(title) }
            byTitle[title, default: []].append(account)
        }
        for title in titles.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            groups.append((title, byTitle[title] ?? [], []))
        }
        return groups
    }

    private var visibleAccounts: [Account] {
        store.accounts.filter { account in
            let provider = SubscriptionProvider.find(account.loginProvider)
            let matchesProvider = providerFilter.isEmpty || (providerFilter == "kimi-family" ? isKimiAccount(account) : (provider?.id ?? account.provider) == providerFilter)
            let fields = [account.displayName, account.email, account.provider, provider?.title ?? "", account.providerTitle, account.note, account.name, isKimiAccount(account) ? "Kimi Code 订阅额度" : ""]
            return matchesProvider && (search.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(search) })
        }.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            loginSession
            connectedAccounts
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("添加订阅账号").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text("同一服务商可添加多个账号，默认轮流使用；优先级高的优先，独立前缀可指定账号。")
                        .font(.system(size: 11)).foregroundStyle(mutedInk)
                }
                DisclosureGroup("本次登录的出站代理（可选）") {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("留空继承全局代理，例如 socks5://127.0.0.1:1080", text: $loginProxy).textFieldStyle(.roundedBorder)
                        Text("仅影响接下来发起的授权及新账号请求。已有账号可在“账号设置”中单独修改。此处不支持 direct；直连请清空全局代理。").font(.system(size: 11)).foregroundStyle(mutedInk)
                    }.padding(.top, 10)
                }.font(.system(size: 12))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                    ForEach(SubscriptionProvider.all) { provider in
                        Card { providerControls(provider) }
                    }
                    Card { kimiWorkControls }
                }
            }
        }
        .sheet(item: $editing) { account in AccountOptionsView(account: account).environmentObject(store) }
        .sheet(item: $inspecting) { account in AccountModelsView(account: account).environmentObject(store) }
        .sheet(isPresented: $addingCursor) { CursorAccountView(proxyURL: loginProxy).environmentObject(store) }
        .sheet(isPresented: $addingKiro) { KiroCredentialImportView().environmentObject(store) }
        .sheet(item: $editingWork) { channel in ChannelEditor(channel: channel).environmentObject(store) }
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
        VStack(alignment: .leading, spacing: 14) {
            providerHeader(title: "Kimi Work", symbol: "desktopcomputer",
                           detail: "本机 Kimi 桌面登录 · 会员月度共享额度，与 Kimi Code 分开计费。")
            if !store.kimiWorkStatus.isEmpty {
                Text(store.kimiWorkStatus).font(.system(size: 11)).foregroundStyle(mutedInk).textSelection(.enabled)
            }
            HStack {
                Button(workChannels.isEmpty ? "连接本机 Work" : "重新连接本机 Work") {
                    Task { await store.connectKimiWork() }
                }.buttonStyle(WorkspaceButtonStyle(prominent: workChannels.isEmpty)).disabled(!store.running || store.busy)
                Spacer()
            }
        }
    }

    private func providerHeader(title: String, symbol: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 16, weight: .semibold))
                Spacer()
                Image(systemName: symbol).foregroundStyle(accent.opacity(0.7))
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(mutedInk).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connectedCount(_ provider: SubscriptionProvider) -> Int {
        store.accounts.filter { (SubscriptionProvider.find($0.loginProvider)?.id ?? $0.provider) == provider.id }.count
    }

    private func providerControls(_ provider: SubscriptionProvider) -> some View {
        let isCursor = provider.id == CursorAccountProfile.providerID
        let count = connectedCount(provider)
        return VStack(alignment: .leading, spacing: 14) {
            providerHeader(title: provider.title, symbol: provider.supportsLocalLogin ? "laptopcomputer.and.arrow.down" : "person.badge.key",
                           detail: provider.detail)
            if count > 0 { Pill(text: "已接入 \(count) 个") }
            if !provider.available {
                Text(provider.unavailableReason).font(.system(size: 11)).foregroundStyle(warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if provider.id == "kiro" {
                Picker("浏览器授权方式", selection: $kiroMethod) {
                    Text("AWS Builder ID").tag("builder-id")
                    Text("组织 SSO").tag("organization")
                }.pickerStyle(.segmented).labelsHidden().font(.system(size: 11))
            }
            if let message = store.localSubscriptionStatus[provider.id], !message.isEmpty {
                Text(message).font(.system(size: 11)).foregroundStyle(mutedInk).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if provider.supportsLocalLogin {
                    Button("连接本机登录") { Task { await store.connectLocalSubscription(provider.id) } }
                        .buttonStyle(WorkspaceButtonStyle(prominent: true)).disabled(actionsDisabled)
                    Button("浏览器授权") {
                        Task { await store.beginLogin(provider.id, proxyURL: loginProxy, method: provider.id == "kiro" ? kiroMethod : "") }
                    }.disabled(!provider.available || actionsDisabled)
                } else if isCursor {
                    Button("Grok Bot 网页登录") { Task { await store.beginLogin(provider.id, proxyURL: loginProxy) } }
                        .buttonStyle(WorkspaceButtonStyle(prominent: true)).disabled(actionsDisabled)
                    Button("使用账号 Key") { addingCursor = true }.disabled(!store.running || store.busy || store.accountOperation != nil)
                } else {
                    Button("添加账号") { Task { await store.beginLogin(provider.id, proxyURL: loginProxy) } }
                        .buttonStyle(WorkspaceButtonStyle(prominent: true))
                        .disabled(!provider.available || provider.importOnly || actionsDisabled)
                }
                Spacer(minLength: 0)
                if let source = URL(string: provider.sourceURL) {
                    Link(destination: source) { Image(systemName: "arrow.up.right.square") }
                        .foregroundStyle(mutedInk).help("查看适配来源").accessibilityLabel(provider.title + " 适配来源")
                }
            }
            if provider.id == "kiro" {
                Button("粘贴 Google / GitHub 凭据登录…") { addingKiro = true }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent).disabled(actionsDisabled)
            }
        }
    }

    private var connectedAccounts: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("已接入账号 · \(connectedCount)").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("导入凭据 JSON") { Task { await store.importAccount() } }.disabled(!store.running || store.busy)
                    Button("刷新列表") { Task { await store.refresh() } }.disabled(!store.running)
                }
                HStack {
                    TextField("搜索账号、备注或文件名", text: $search).textFieldStyle(.roundedBorder)
                    Picker("服务商", selection: $providerFilter) {
                        Text("全部服务商").tag("")
                        Text("Kimi · Code / Work").tag("kimi-family")
                        ForEach(SubscriptionProvider.all.filter { !["kimi", "kimi-ai"].contains($0.id) }) { Text($0.title).tag($0.id) }
                    }.labelsHidden().frame(width: 155)
                }
                if visibleAccounts.isEmpty && visibleWorkChannels.isEmpty {
                    Text(connectedCount == 0 ? "尚无账号。连接本机登录、完成浏览器授权，或导入账号凭据 JSON。" : "没有符合筛选条件的账号。")
                        .font(.system(size: 12)).foregroundStyle(mutedInk).padding(.vertical, 18)
                }
                ForEach(accountGroups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title + " · \(group.accounts.count + group.work.count)")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(mutedInk).padding(.top, 8)
                        ForEach(group.accounts) { account in
                            Divider().opacity(0.3)
                            accountRow(account)
                        }
                        ForEach(group.work) { channel in
                            Divider().opacity(0.3)
                            workAccountRow(channel)
                        }
                    }
                }
            }
        }
    }

    private func accountHealth(_ account: Account) -> Color {
        if account.disabled { return mutedInk.opacity(0.5) }
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
                }
                Text([account.providerTitle, account.statusText, store.publicPrefix(source: "account:" + account.id).map { "调用名 " + $0 + "/…" } ?? (account.prefix.isEmpty ? "账号池" : "前缀 " + account.prefix)].joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(account.requiresSignIn ? warning : mutedInk)
                    .help(account.name)
                if !account.statusMessage.isEmpty && (account.requiresSignIn || account.status == "error") {
                    Text(store.redacted(account.statusMessage)).font(.system(size: 11)).foregroundStyle(warning).lineLimit(3)
                }
                QuotaSummaryView(target: QuotaTarget(account: account))
            }
            Spacer(minLength: 10)
            if store.accountOperation == account.id { ProgressView().controlSize(.small) }
            Menu {
                Button("账号设置…") { editing = account }
                Button("查看账号模型…") { inspecting = account }
                Button("刷新凭据") { Task { await store.refreshAccount(account) } }
                if let provider = SubscriptionProvider.find(account.loginProvider), !provider.importOnly {
                    if provider.supportsRecovery {
                        Button("重新授权此账号") { Task { await store.beginLogin(provider.id, account: account) } }
                            .disabled(store.login != nil || !provider.available)
                    } else {
                        Button(account.provider == CursorAccountProfile.providerID ? "网页登录添加 Grok Bot" : "再次登录（添加凭据）") { Task { await store.beginLogin(provider.id) } }
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
                Button("重新连接本机 Work") { Task { await store.connectKimiWork() } }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("用 Key 添加 Cursor / Grok Bot").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }.disabled(saving)
            }
            Text("选择通道并填入账号 Key。也可以直接使用 Grok Bot 网页登录，授权完成后自动接入。")
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
                Text("Cursor API Key").font(.system(size: 12, weight: .medium))
                SecureField("粘贴官方 Dashboard 创建的 API Key", text: $key).textFieldStyle(.roundedBorder)
            }
            if !message.isEmpty { Text(message).font(.system(size: 12)).foregroundStyle(warning).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(saving ? "保存中…" : "添加账号") { Task { await save() } }
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
            try await store.addCursorAccount(label: label, key: key, profile: profile)
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
            TextField("独立模型前缀（可留空）", text: option(\.prefix)).textFieldStyle(.roundedBorder)
            Text("设置独立前缀后，这个账号单独成组，对外模型名为“备注前四字/模型名”，可在模型页复制。留空时参与同服务商的账号池。").font(.system(size: 11)).foregroundStyle(mutedInk).lineSpacing(3)
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
            if let metric = state?.snapshot?.metrics.first {
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
    var targets: [QuotaTarget] { store.quotaTargets.filter { search.isEmpty || ($0.title + $0.subtitle).localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(store.accounts.count + store.settings.channels.filter(\.isKimiWork).count) 个订阅账号 · \(store.settings.channels.filter { !$0.isKimiWork }.count) 个 API 渠道").font(.system(size: 15, weight: .medium))
                    Text("代理运行时每 5 分钟更新。各币种、平台积分和额度按原始单位分别展示。").font(.system(size: 11)).foregroundStyle(mutedInk)
                }
                Spacer()
                Button("刷新全部") { Task { await store.refreshQuotas(force: true) } }
                    .disabled(!store.running || store.quotaRefreshing)
            }
            TextField("搜索账号、渠道或服务商", text: $search).textFieldStyle(.roundedBorder)
            if store.quotaTargets.isEmpty {
                Card {
                    Text("添加订阅账号或 API 渠道后，这里会逐项显示余额和额度。").font(.system(size: 14)).foregroundStyle(mutedInk).padding(.vertical, 35)
                }
            }
            ForEach(targets) { target in QuotaCardView(target: target) }
        }.task { await store.refreshQuotas() }
    }
}

struct QuotaCardView: View {
    @EnvironmentObject var store: BridgeStore
    let target: QuotaTarget
    private var state: QuotaState? {
        let value = store.quotaStates[target.id]
        return value?.fingerprint == target.fingerprint ? value : nil
    }
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(target.title).font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
                        Text(target.subtitle).font(.system(size: 11)).foregroundStyle(mutedInk)
                    }
                    Spacer()
                    if state?.loading == true { ProgressView().controlSize(.small) }
                    Button("刷新") { Task { await store.refreshQuotas(force: true, only: target.id) } }.disabled(!store.running || store.quotaRefreshing)
                }
                if let error = state?.error {
                    Text((state?.snapshot == nil ? "" : "刷新失败，以下为上次成功数据。\n") + error).font(.system(size: 12)).foregroundStyle(warning).textSelection(.enabled)
                }
                if let snapshot = state?.snapshot {
                    if let plan = snapshot.plan { Pill(text: "套餐 · " + plan) }
                    ForEach(snapshot.metrics) { metric in QuotaMetricView(metric: metric) }
                    ForEach(snapshot.details) { detail in
                        HStack(alignment: .top) {
                            Text(detail.label).foregroundStyle(mutedInk)
                            Spacer()
                            Text(detail.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }.font(.system(size: 11))
                    }
                    ForEach(snapshot.notes, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(mutedInk).textSelection(.enabled) }
                    HStack {
                        Text(snapshot.source)
                        Spacer()
                        Text("更新于 " + snapshot.fetchedAt.formatted(date: .abbreviated, time: .standard))
                    }.font(.system(size: 10)).foregroundStyle(mutedInk)
                } else if state?.error == nil {
                    Text(state?.loading == true ? "正在向服务商读取余额与额度…" : store.running ? "尚未查询" : "启动代理后查询").font(.system(size: 12)).foregroundStyle(mutedInk)
                }
            }
        }
    }
}

struct QuotaMetricView: View {
    let metric: QuotaMetric
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(metric.title).font(.system(size: 13, weight: .medium))
                Spacer()
                if let percentage = metric.usedPercentage {
                    Text("已用 \(percentage.formatted(.number.precision(.fractionLength(0...2))))% · 剩余 \(max(0, 100 - percentage).formatted(.number.precision(.fractionLength(0...2))))%")
                        .font(.system(size: 11)).foregroundStyle(percentage >= 90 ? warning : healthy)
                }
            }
            if let percentage = metric.usedPercentage {
                ProgressView(value: min(100, max(0, percentage)), total: 100).tint(percentage >= 90 ? warning : healthy)
            }
            if metric.used != nil || metric.limit != nil {
                HStack(spacing: 28) {
                    amount("可用 / 剩余", metric.remainingAmount, override: metric.unlimited ? "无上限" : nil)
                    amount("已使用", metric.used)
                    amount("总额度 / 预算", metric.limit, override: metric.unlimited ? "无上限" : nil)
                }
            } else if metric.remaining != nil || metric.unlimited {
                Text(metric.unlimited ? "无上限" : QuotaParser.amount(metric.remaining!) + " " + metric.unit)
                    .font(.system(size: 20, weight: .medium)).textSelection(.enabled)
            } else if metric.usedPercentage == nil {
                Text("服务商未提供此项数值").font(.system(size: 11)).foregroundStyle(mutedInk)
            }
            if let date = metric.reset { Text(metric.resetLabel + " · " + date.formatted(date: .abbreviated, time: .standard)).font(.system(size: 11)).foregroundStyle(mutedInk) }
            if !metric.note.isEmpty { Text(metric.note).font(.system(size: 11)).foregroundStyle(warning) }
        }.padding(16).background(insetSurface, in: RoundedRectangle(cornerRadius: 10))
    }
    private func amount(_ label: String, _ value: Decimal?, override: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 10)).foregroundStyle(mutedInk)
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
    var filtered: [ModelItem] { store.models.filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(spacing: 28) {
            Card {
                VStack(alignment: .leading, spacing: 22) {
                    HStack { Text("模型检测").font(.system(size: 14, weight: .semibold)); Spacer(); Pill(text: "真实请求 · 消耗模型额度", active: false) }
                    Picker("检测方向", selection: $testMode) {
                        ForEach(ModelTestMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }.pickerStyle(.segmented).disabled(store.testing)
                        .accessibilityIdentifier("model-test-mode")
                    Text(testMode.detail).font(.system(size: 12)).foregroundStyle(mutedInk)
                    TextField("模型 ID，可从下方列表选择", text: $selectedModel).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                        .disabled(store.testing).accessibilityIdentifier("model-test-id")
                    HStack {
                        Picker("协议", selection: $wire) { Text("Chat Completions").tag("chat"); Text("Responses").tag("responses"); Text("Anthropic Messages").tag("anthropic") }.pickerStyle(.segmented).disabled(store.testing)
                        if store.testing {
                            Button("取消测试") { store.cancelModelTest() }
                        } else {
                            Button("开始测试") { store.startModelTest(selectedModel.trimmingCharacters(in: .whitespacesAndNewlines), wire: wire, mode: testMode) }
                                .buttonStyle(WorkspaceButtonStyle(prominent: true))
                                .disabled(selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.running)
                                .accessibilityIdentifier("model-test-start")
                        }
                    }
                    if !store.testResult.isEmpty {
                        HStack(spacing: 8) {
                            if store.testing { ProgressView().controlSize(.small) }
                            Text(store.testResult).font(.system(size: 12)).foregroundStyle(mutedInk)
                        }
                    }
                    if let report = store.testReport { ModelDiagnosticResultView(report: report) }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("已发布模型 · \(store.models.count)").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        TextField("搜索模型", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
                        ModelPublicationButton(title: "选择反代模型")
                        Button("刷新目录") { Task { await store.refresh() } }
                    }
                    if filtered.isEmpty {
                        Text(store.availableModels.isEmpty ? "暂无模型。先添加 API 渠道或登录账号，再刷新目录。" : (search.isEmpty ? "尚未发布模型。点击“选择反代模型”勾选要使用的模型。" : "没有匹配的已发布模型。"))
                            .font(.system(size: 12)).foregroundStyle(mutedInk).padding(.vertical, 30)
                    }
                    ForEach(filtered) { model in
                        HStack {
                            Image(systemName: "cube").foregroundStyle(accent.opacity(0.7))
                            VStack(alignment: .leading, spacing: 4) { Text(model.id).font(.system(size: 12, design: .monospaced)).textSelection(.enabled); Text(model.owner).font(.system(size: 10)).foregroundStyle(mutedInk) }
                            Spacer(); Button("复制") { store.copy(model.id) }; Button("选择测试") { selectedModel = model.id }.disabled(store.testing)
                        }.padding(.vertical, 5)
                        Divider().opacity(0.25)
                    }
                }
            }
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
    @State private var filePath = ""
    @State private var confirmingApply = false
    @State private var confirmingRestore = false
    var profile: ConnectionProfile { ConnectionProfile(tool: tool, baseURL: store.baseURL, key: store.settings.clientKey, model: model, contextSize: max(1, Int(context) ?? 32768)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) { ForEach(ClientTool.allCases) { item in
                Button { tool = item; message = ""; resetPath(); model = store.settings.selectedModels[item.rawValue] ?? "" } label: {
                    HStack(spacing: 12) {
                        if let logo = item.brandIcon {
                            Image(nsImage: logo).renderingMode(.original).resizable().scaledToFit()
                                .frame(width: 36, height: 36).accessibilityHidden(true)
                        } else {
                            Image(systemName: item.symbol).font(.system(size: 22)).frame(width: 36, height: 36).accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.rawValue).font(.system(size: 13, weight: .semibold))
                            if item == .cursor { Text("反代 / 官方账号").font(.system(size: 10)) }
                            if item == .claudeDesktop { Text("桌面端 · Chat / Cowork").font(.system(size: 10)) }
                        }
                        Spacer(minLength: 0)
                    }
                        .padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 76).foregroundStyle(tool == item ? accent : mutedInk)
                        .background(tool == item ? accent.opacity(0.08) : panel, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tool == item ? accent.opacity(0.35) : hairline.opacity(0.75)))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(item.rawValue)
            } }
            if tool == .cursor {
                CursorChineseCard()
                CursorLocalView()
            } else {
            if tool != .kiro {
                Card {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack { Text("给 \(tool.rawValue) 选择模型").font(.system(size: 15, weight: .semibold)); Spacer(); Pill(text: "可独立配置") }
                        HStack {
                            TextField("填写已开放的模型名，例如 渠道名称前四字/模型别名", text: $model).textFieldStyle(.roundedBorder)
                            Menu("从目录选择") { ForEach(store.models) { item in Button(item.id) { model = item.id } } }.disabled(store.models.isEmpty).frame(width: 140)
                        }
                        if tool == .kimi { TextField("模型上下文长度（按服务商填写）", text: $context).textFieldStyle(.roundedBorder) }
                        if let _ = tool.file {
                            HStack { TextField("配置文件", text: $filePath).textFieldStyle(.roundedBorder); Button("选择文件") { chooseFile() } }
                            Text("应用时备份现有文件，再合并模型连接字段。项目级配置或终端环境变量可能优先于此配置。").font(.system(size: 11)).foregroundStyle(mutedInk)
                        } else if tool == .claudeDesktop {
                            Text("在 Claude 中打开 Help → Troubleshooting → Enable Developer Mode，重启后选择 Developer → Configure Third-Party Inference。选择 Gateway 和 Static API key，填入下方地址、密钥及模型 ID，测试连接并应用后重启 Claude。").font(.system(size: 12)).foregroundStyle(mutedInk)
                            HStack {
                                Button("打开 Claude") { Task { await store.openClaudeDesktop() } }.disabled(store.launchingAgent || store.busy)
                                Link("官方配置说明", destination: URL(string: "https://claude.com/docs/third-party/claude-desktop/gateway")!)
                            }
                            Text("这里配置 Claude 桌面端的第三方推理网关。请先在“模型与测试”中验证 Anthropic Messages；模型能力与桌面端功能以实际兼容情况为准。").font(.system(size: 11)).foregroundStyle(mutedInk)
                        } else { Text("在目标工具的模型服务商设置中，新增 OpenAI 兼容服务商并粘贴下面的信息。").font(.system(size: 12)).foregroundStyle(mutedInk) }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 22) {
                    HStack { Text(tool == .kiro ? "Kiro 接入说明" : "连接配置预览").font(.system(size: 14, weight: .semibold)); Spacer(); if tool != .kiro { Toggle("显示本地密钥", isOn: $visible).toggleStyle(.checkbox).font(.system(size: 11)) } }
                    Text(visible ? profile.snippet : profile.snippet.replacingOccurrences(of: store.settings.clientKey, with: "••••••••（复制时包含完整密钥）"))
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineSpacing(5)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(insetSurface, in: RoundedRectangle(cornerRadius: 10))
                    if tool != .kiro {
                        HStack {
                            Button("复制配置") { store.copy(profile.snippet); message = "配置已复制，包含本地连接密钥。" }
                            if tool == .claudeDesktop {
                                Button("复制地址") { store.copy(store.baseURL); message = "网关地址已复制。" }
                                Button("复制密钥") { store.copy(store.settings.clientKey); message = "本地连接密钥已复制。" }
                                Button("复制模型 ID") { store.copy(model); message = "模型 ID 已复制。" }.disabled(model.isEmpty)
                            }
                            if !profile.command.isEmpty { Button(tool == .kimi ? "复制启动命令（先应用配置）" : "复制临时启动命令") { store.copy(profile.command); message = "启动命令已复制。" } }
                            Spacer()
                            if tool.file != nil { Button("应用到工具") { confirmingApply = true }.buttonStyle(WorkspaceButtonStyle(prominent: true)).disabled(model.isEmpty || filePath.isEmpty || !store.running) }
                        }
                        HStack { Button("导出配置文件") { exportProfile() }; if tool.file != nil { Button("恢复上一次配置") { confirmingRestore = true } }; Spacer() }
                    }
                    if !message.isEmpty { Text(message).font(.system(size: 12)).foregroundStyle(accent).textSelection(.enabled) }
                }
            }
            }
        }.onAppear { resetPath(); model = store.settings.selectedModels[tool.rawValue] ?? "" }
            .confirmationDialog("将应用连接配置，并备份目标文件。", isPresented: $confirmingApply) {
                Button("备份并应用") { apply() }
            } message: { Text(filePath + "\n模型 · " + model) }
            .confirmationDialog("恢复本工具上一次应用之前的配置？", isPresented: $confirmingRestore) {
                Button("恢复配置") {
                    do { try ConfigurationInstaller(directory: store.dataDirectory).restore(URL(fileURLWithPath: filePath)); message = "已恢复上一次配置。"; store.record("已恢复 \(tool.rawValue) 配置") }
                    catch { store.report(error) }
                }
            }
    }
    private func resetPath() { filePath = tool.file.map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).path } ?? "" }
    private func chooseFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { filePath = url.path }
    }
    private func apply() {
        do {
            guard filePath.hasPrefix("/") else { throw BridgeError.message("请填写完整的绝对路径。") }
            try ConfigurationInstaller(directory: store.dataDirectory).apply(profile, to: URL(fileURLWithPath: filePath))
            message = "已备份并应用。请重新启动 \(tool.rawValue) 的会话。"
            store.record("已应用 \(tool.rawValue) 配置 · \(model)")
            var next = store.settings; next.selectedModels[tool.rawValue] = model
            Task { do { try await store.update(next) } catch { store.report(error) } }
        } catch { store.report(error) }
    }
    private func exportProfile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tool == .claude ? "bridgedock-claude.json" : "bridgedock-\(tool.id).txt"
        if [.codex, .kimi].contains(tool) { panel.nameFieldStringValue = "bridgedock-\(tool.id).toml" }
        if panel.runModal() == .OK, let url = panel.url {
            do { try privateWrite(Data(profile.snippet.utf8), to: url); message = "已导出，文件包含本地连接密钥。" } catch { store.report(error) }
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
                        Text("开启后点击 Cursor 模型菜单右侧的“参数”，调整“上下文预算”和“思考深度”。预算按档位选择，上限仍由上游模型决定。")
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
                    ModelPublicationButton(title: "选择反代模型")
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
                    Text("本地数据与内核").font(.system(size: 14, weight: .semibold))
                    Text(store.dataDirectory.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(mutedInk)
                    Text("API Key 和订阅凭据以本地文件保存，数据目录仅当前用户可读写。配置导出会包含本地连接密钥。关闭窗口后服务继续运行，可从菜单栏返回；退出 App 时停止内核。").font(.system(size: 12)).foregroundStyle(mutedInk).lineSpacing(5)
                    HStack { Pill(text: "CLIProxyAPI 8.0.51", active: false); Pill(text: "Kiro Plugin 0.1.1", active: false); Pill(text: "MIT", active: false) }
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
