import SwiftUI
import AppKit

private let canvas = Color(red: 0.045, green: 0.062, blue: 0.095)
private let panel = Color(red: 0.075, green: 0.10, blue: 0.15)
private let mint = Color(red: 0.39, green: 0.87, blue: 0.72)

enum Destination: String, CaseIterable, Identifiable {
    case overview = "总览", channels = "API 渠道", accounts = "订阅账号", models = "模型与测试", clients = "工具接入", settings = "设置与诊断"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .channels: return "point.3.connected.trianglepath.dotted"
        case .accounts: return "person.crop.rectangle.stack"
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
        case .models: return "查看真实模型目录，验证不同协议的实际调用。"
        case .clients: return "选择模型，再将本地接口接入你的编程工具。"
        case .settings: return "管理本地端口、出站代理与配置备份。"
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.065)))
    }
}

struct Pill: View {
    let text: String
    var active = true
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium))
            .foregroundStyle(active ? mint : .secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background((active ? mint : Color.gray).opacity(0.1), in: Capsule())
    }
}

struct ContentView: View {
    @EnvironmentObject var store: BridgeStore
    @State private var selected: Destination = .overview
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(selected.rawValue).font(.system(size: 27, weight: .semibold))
                        Text(selected.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 7) {
                        Circle().fill(store.running ? mint : .orange).frame(width: 6, height: 6)
                        Text(store.running ? "本地服务已启动" : store.status).font(.system(size: 11))
                    }.padding(10).background(.white.opacity(0.04), in: Capsule())
                }.padding(.horizontal, 32).padding(.top, 30).padding(.bottom, 25)
                ScrollView {
                    Group {
                        switch selected {
                        case .overview: OverviewView(selected: $selected)
                        case .channels: ChannelsView()
                        case .accounts: AccountsView()
                        case .models: ModelsView()
                        case .clients: ClientsView()
                        case .settings: SettingsView()
                        }
                    }.padding(.horizontal, 32).padding(.bottom, 30)
                }
            }
        }.background(canvas).preferredColorScheme(.dark).tint(mint)
            .frame(minWidth: 1040, minHeight: 700)
            .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("知道了") { store.error = nil }
            } message: { Text(store.error ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted").font(.system(size: 26, weight: .medium)).foregroundStyle(mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("BridgeDock").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("桥 接 台").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
            }.padding(.top, 34).padding(.bottom, 40).padding(.horizontal, 24)
            Text("工作空间").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 26).padding(.bottom, 12)
            ForEach(Destination.allCases) { item in
                Button {
                    selected = item
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol).frame(width: 18)
                        Text(item.rawValue).font(.system(size: 13, weight: selected == item ? .semibold : .regular))
                        Spacer()
                        if selected == item { Circle().fill(mint).frame(width: 5, height: 5) }
                    }.foregroundStyle(selected == item ? mint : .white.opacity(0.64))
                        .padding(.horizontal, 14).padding(.vertical, 13)
                        .background(selected == item ? mint.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 4)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack { Circle().fill(store.running ? mint : .orange).frame(width: 7, height: 7); Text("仅本机访问").font(.system(size: 12, weight: .medium)) }
                Text("127.0.0.1:" + String(store.settings.port)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Button(store.running ? "停止服务" : "启动服务") {
                    if store.running { store.stop() } else { Task { await store.start() } }
                }.disabled(store.busy).controlSize(.small)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12)).padding(16)
            Text("v1.0 · macOS · ARM64").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 26).padding(.bottom, 20)
        }.background(Color.white.opacity(0.012))
    }
}

struct OverviewView: View {
    @EnvironmentObject var store: BridgeStore
    @Binding var selected: Destination
    var body: some View {
        VStack(spacing: 20) {
            Card {
                HStack(spacing: 30) {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("LOCAL MODEL GATEWAY").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(mint)
                        Text("模型在这里汇合。\n工具由你选择。").font(.system(size: 31, weight: .semibold)).lineSpacing(4)
                        Text("一个本地接口，连接你的账号、API 和中转站。\n为每个编程工具选择合适的模型。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                        HStack(spacing: 12) {
                            Button("添加 API 渠道") { selected = .channels }.buttonStyle(.borderedProminent)
                            Button("登录订阅账号") { selected = .accounts }.buttonStyle(.bordered)
                        }.padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 14) {
                        HStack(spacing: 8) { Pill(text: "Claude"); Pill(text: "Codex"); Pill(text: "Kimi") }
                        Image(systemName: "arrow.down").foregroundStyle(.secondary)
                        Label("BridgeDock", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 18, weight: .semibold)).foregroundStyle(mint).padding(18)
                            .background(mint.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
                        Image(systemName: "arrow.down").foregroundStyle(.secondary)
                        HStack(spacing: 8) { Pill(text: "编程工具", active: false); Pill(text: "自定义客户端", active: false) }
                    }.padding(.horizontal, 16)
                }.padding(6)
            }
            HStack(spacing: 14) {
                statistic("启用的 API 渠道", String(store.settings.channels.filter(\.enabled).count), "network")
                statistic("接入的账号凭据", String(store.accounts.count), "person.crop.circle")
                statistic("当前可见模型", String(store.models.count), "cube")
            }
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("统一 API 地址").font(.system(size: 13, weight: .semibold))
                        Text(store.apiURL).font(.system(size: 16, design: .monospaced)).foregroundStyle(mint).textSelection(.enabled)
                        Text("支持 Chat Completions、Responses 和 Anthropic Messages").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("复制地址") { store.copy(store.apiURL) }
                    Button("接入工具") { selected = .clients }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 15) {
                    Text("接入步骤").font(.system(size: 14, weight: .semibold))
                    HStack(alignment: .top, spacing: 25) {
                        step("01", "添加来源", "登录订阅账号，或填入 API Key。")
                        step("02", "验证模型", "获取模型列表，发送简短测试。")
                        step("03", "连接工具", "应用配置或复制本地连接信息。")
                    }
                }
            }
        }
    }
    private func statistic(_ title: String, _ value: String, _ icon: String) -> some View {
        Card {
            HStack { Text(title).font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Image(systemName: icon).foregroundStyle(mint.opacity(0.6)) }
            Text(value).font(.system(size: 29, weight: .medium, design: .rounded)).padding(.top, 7)
        }
    }
    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text(number).font(.system(size: 12, design: .monospaced)).foregroundStyle(mint).padding(8).background(mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 12, weight: .semibold)); Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChannelsView: View {
    @EnvironmentObject var store: BridgeStore
    @State private var editing: Channel?
    @State private var deleting: Channel?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card {
                VStack(alignment: .leading, spacing: 15) {
                    Text("选择服务商，快速添加").font(.system(size: 14, weight: .semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], spacing: 10) {
                        ForEach(Preset.all) { preset in
                            Button {
                                var channel = Channel()
                                channel.kind = preset.title; channel.name = preset.title; channel.wire = preset.wire
                                channel.baseURL = preset.url; channel.prefix = preset.prefix
                                editing = channel
                            } label: {
                                HStack { Text(preset.title).font(.system(size: 12)); Spacer(); Image(systemName: "plus").foregroundStyle(mint) }.padding(11)
                                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            if store.settings.channels.isEmpty {
                Card {
                    VStack(spacing: 12) {
                        Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 34)).foregroundStyle(mint.opacity(0.6))
                        Text("还没有添加 API 渠道").font(.system(size: 16, weight: .medium))
                        Text("从上方选择一个来源。每个渠道都可以设置独立地址、密钥和模型别名。").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            ForEach(store.settings.channels) { channel in
                Card {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text(channel.name).font(.system(size: 17, weight: .semibold)); Pill(text: channel.enabled ? "已启用" : "已停用", active: channel.enabled) }
                            Text(channel.baseURL).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            HStack { Pill(text: channel.wire.title, active: false); Pill(text: "\(channel.models.count) 个模型", active: false); Text(channel.prefix + "/…").font(.system(size: 11, design: .monospaced)).foregroundStyle(mint) }
                        }
                        Spacer()
                        Button("编辑") { editing = channel }
                        Button(channel.enabled ? "停用" : "启用") {
                            var value = channel; value.enabled.toggle()
                            Task { do { try await store.saveChannel(value) } catch { store.report(error) } }
                        }.disabled(store.busy)
                        Button(role: .destructive) { deleting = channel } label: { Image(systemName: "trash") }
                    }
                }
            }
        }.sheet(item: $editing) { channel in ChannelEditor(channel: channel) }
            .confirmationDialog("删除这个 API 渠道？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("删除渠道", role: .destructive) { if let value = deleting { Task { await store.deleteChannel(value) } }; deleting = nil }
            }
    }
}

struct ChannelEditor: View {
    @EnvironmentObject var store: BridgeStore
    @Environment(\.dismiss) private var dismiss
    @State var channel: Channel
    @State private var fetching = false
    @State private var localError = ""
    @State private var visibleKey = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("配置 API 渠道").font(.system(size: 24, weight: .semibold)); Spacer(); Button("取消") { dismiss() } }
            Form {
                TextField("渠道名称", text: $channel.name)
                Picker("上游协议", selection: $channel.wire) { ForEach(WireProtocol.allCases) { Text($0.title).tag($0) } }
                TextField("Base URL", text: $channel.baseURL, prompt: Text("https://your-provider.example/v1"))
                HStack {
                    if visibleKey { TextField("API Key", text: $channel.apiKey) } else { SecureField("API Key", text: $channel.apiKey) }
                    Button { visibleKey.toggle() } label: { Image(systemName: visibleKey ? "eye.slash" : "eye") }.buttonStyle(.plain)
                }
                TextField("渠道前缀", text: $channel.prefix)
                TextField("独立网络代理（可选）", text: $channel.proxyURL, prompt: Text("留空使用全局代理"))
            }.textFieldStyle(.roundedBorder)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("模型 ID 与别名").font(.system(size: 13, weight: .semibold))
                    Text("每行一个模型。也可写 上游模型ID = 自定义别名，调用时使用 前缀/别名。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(fetching ? "获取中…" : "获取模型") {
                    fetching = true; localError = ""
                    Task {
                        do { channel.modelLines = try await store.fetchModels(for: channel) }
                        catch { localError = error.localizedDescription.replacingOccurrences(of: channel.apiKey.isEmpty ? "\0" : channel.apiKey, with: "••••••") }
                        fetching = false
                    }
                }.disabled(fetching || !store.running)
            }
            TextEditor(text: $channel.modelLines).font(.system(size: 12, design: .monospaced)).frame(height: 145).padding(7).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
            Text("模型是否可用取决于你的账号权限。部分 Coding Plan 不提供模型列表，可手动填写服务商给出的模型 ID。").font(.system(size: 11)).foregroundStyle(.secondary)
            if !localError.isEmpty { Text(localError).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            HStack { Toggle("启用渠道", isOn: $channel.enabled); Spacer(); Button(store.busy ? "保存中…" : "保存渠道") {
                Task { do { try await store.saveChannel(channel); dismiss() } catch { localError = error.localizedDescription } }
            }.buttonStyle(.borderedProminent).disabled(store.busy || fetching) }
        }.padding(30).frame(width: 680).background(canvas).preferredColorScheme(.dark)
    }
}

struct AccountsView: View {
    @EnvironmentObject var store: BridgeStore
    @State private var callback = ""
    @State private var removing: Account?
    private let providers = [("claude", "Claude", "Claude Code 订阅授权"), ("codex", "Codex", "ChatGPT / Codex 授权"), ("kimi", "Kimi", "Kimi Code 国内账号"), ("kimi-ai", "Kimi 国际", "Kimi.ai Code 账号"), ("kiro", "Kiro", "AWS Builder ID / 组织账号"), ("xai", "Grok", "Grok Build / xAI 授权")]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230))], spacing: 14) {
                ForEach(providers, id: \.0) { provider in
                    Card {
                        VStack(alignment: .leading, spacing: 13) {
                            HStack { Text(provider.1).font(.system(size: 20, weight: .semibold)); Spacer(); Image(systemName: "person.badge.key.fill").foregroundStyle(mint.opacity(0.7)) }
                            Text(provider.2).font(.system(size: 11)).foregroundStyle(.secondary)
                            Button("浏览器登录") { Task { await store.beginLogin(provider.0) } }.disabled(!store.running || store.busy || store.login != nil)
                        }
                    }
                }
            }
            if let login = store.login {
                Card {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack { Text("正在登录 · " + login.provider).font(.headline); Spacer(); Button("取消登录") { Task { await store.cancelLogin() } } }
                        Text(store.loginStatus).font(.system(size: 12)).foregroundStyle(mint)
                        if !login.userCode.isEmpty { HStack { Text("设备码"); Text(login.userCode).font(.system(size: 20, weight: .bold, design: .monospaced)).textSelection(.enabled); Button("复制") { store.copy(login.userCode) } } }
                        HStack { Button("重新打开授权网页") { if let url = URL(string: login.url) { NSWorkspace.shared.open(url) } }; Button("复制授权链接") { store.copy(login.url) } }
                        if ["claude", "codex"].contains(login.provider) {
                            TextField("若浏览器无法自动返回，可粘贴完整回调 URL", text: $callback).textFieldStyle(.roundedBorder)
                            Button("提交回调") { Task { await store.submitCallback(callback) } }.disabled(callback.isEmpty)
                        }
                    }
                }
            } else if !store.loginStatus.isEmpty { Text(store.loginStatus).font(.system(size: 12)).foregroundStyle(mint) }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("已接入的凭据").font(.system(size: 14, weight: .semibold)); Spacer(); Button("导入凭据 JSON") { Task { await store.importAccount() } }.disabled(!store.running); Button("刷新") { Task { await store.refresh() } } }
                    if store.accounts.isEmpty { Text("尚无账号。完成浏览器授权，或导入已有的 CLIProxyAPI 凭据文件。").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 18) }
                    ForEach(store.accounts) { account in
                        Divider().opacity(0.4)
                        HStack {
                            VStack(alignment: .leading, spacing: 5) { Text(account.email).font(.system(size: 13)); Text(account.provider + " · " + account.status).font(.system(size: 11)).foregroundStyle(.secondary) }
                            Spacer(); Pill(text: account.disabled ? "已停用" : "已接入", active: !account.disabled)
                            Button(account.disabled ? "启用" : "停用") { Task { await store.toggleAccount(account) } }
                            Button(role: .destructive) { removing = account } label: { Image(systemName: "trash") }
                        }
                    }
                }
            }
            Text("Kiro 的 Google / GitHub 登录凭据请通过 JSON 导入，组织 Start URL 在设置中填写。Grok 授权使用 xAI / Grok Build 的可用权限，实际模型以登录后目录和调用结果为准。").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
        }.confirmationDialog("移除这个账号？本地恢复副本会保存在 removed-accounts 文件夹。", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("移除账号", role: .destructive) { if let account = removing { Task { await store.removeAccount(account) } }; removing = nil }
        }
    }
}

struct ModelsView: View {
    @EnvironmentObject var store: BridgeStore
    @State private var search = ""
    @State private var selectedModel = ""
    @State private var wire = "chat"
    var filtered: [ModelItem] { store.models.filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(spacing: 20) {
            Card {
                VStack(alignment: .leading, spacing: 15) {
                    HStack { Text("模型调用测试").font(.system(size: 14, weight: .semibold)); Spacer(); Pill(text: "真实请求 · 消耗少量额度", active: false) }
                    TextField("模型 ID，可从下方列表选择", text: $selectedModel).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    HStack {
                        Picker("协议", selection: $wire) { Text("Chat Completions").tag("chat"); Text("Responses").tag("responses"); Text("Anthropic Messages").tag("anthropic") }.pickerStyle(.segmented)
                        Button(store.testing ? "请求中…" : "发送测试") { Task { await store.testModel(selectedModel, wire: wire) } }.buttonStyle(.borderedProminent).disabled(selectedModel.isEmpty || store.testing || !store.running)
                    }
                    if !store.testResult.isEmpty { Text(store.testResult).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 9)) }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("模型目录 · \(store.models.count)").font(.system(size: 14, weight: .semibold)); Spacer(); TextField("搜索模型", text: $search).textFieldStyle(.roundedBorder).frame(width: 230); Button("刷新目录") { Task { await store.refresh() } } }
                    if filtered.isEmpty { Text("暂无模型。先添加 API 渠道或登录账号，再刷新目录。").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 30) }
                    ForEach(filtered) { model in
                        HStack {
                            Image(systemName: "cube").foregroundStyle(mint.opacity(0.7))
                            VStack(alignment: .leading, spacing: 4) { Text(model.id).font(.system(size: 12, design: .monospaced)).textSelection(.enabled); Text(model.owner).font(.system(size: 10)).foregroundStyle(.secondary) }
                            Spacer(); Button("复制") { store.copy(model.id) }; Button("选择测试") { selectedModel = model.id }
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
    @State private var tool: ClientTool = .claude
    @State private var model = ""
    @State private var context = "32768"
    @State private var visible = false
    @State private var message = ""
    @State private var filePath = ""
    @State private var confirmingApply = false
    @State private var confirmingRestore = false
    var profile: ConnectionProfile { ConnectionProfile(tool: tool, baseURL: store.baseURL, key: store.settings.clientKey, model: model, contextSize: max(1, Int(context) ?? 32768)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 9) { ForEach(ClientTool.allCases) { item in
                Button { tool = item; message = ""; resetPath(); model = store.settings.selectedModels[item.rawValue] ?? "" } label: {
                    VStack(spacing: 9) { Image(systemName: item.symbol).font(.system(size: 20)); Text(item.rawValue).font(.system(size: 11, weight: .medium)) }
                        .frame(maxWidth: .infinity).padding(.vertical, 17).foregroundStyle(tool == item ? mint : .secondary)
                        .background(tool == item ? mint.opacity(0.10) : panel, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
            } }
            if tool != .kiro {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack { Text("给 \(tool.rawValue) 选择模型").font(.system(size: 15, weight: .semibold)); Spacer(); Pill(text: "可独立配置") }
                        HStack {
                            TextField("填写模型 ID，例如 渠道前缀/模型别名", text: $model).textFieldStyle(.roundedBorder)
                            Menu("从目录选择") { ForEach(store.models) { item in Button(item.id) { model = item.id } } }.disabled(store.models.isEmpty).frame(width: 140)
                        }
                        if tool == .kimi { TextField("模型上下文长度（按服务商填写）", text: $context).textFieldStyle(.roundedBorder) }
                        if let _ = tool.file {
                            HStack { TextField("配置文件", text: $filePath).textFieldStyle(.roundedBorder); Button("选择文件") { chooseFile() } }
                            Text("应用时备份现有文件，再合并模型连接字段。项目级配置或终端环境变量可能优先于此配置。").font(.system(size: 11)).foregroundStyle(.secondary)
                        } else { Text("在目标工具的模型服务商设置中，新增 OpenAI 兼容服务商并粘贴下面的信息。").font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 15) {
                    HStack { Text(tool == .kiro ? "Kiro 接入说明" : "连接配置预览").font(.system(size: 14, weight: .semibold)); Spacer(); if tool != .kiro { Toggle("显示本地密钥", isOn: $visible).toggleStyle(.checkbox).font(.system(size: 11)) } }
                    Text(visible ? profile.snippet : profile.snippet.replacingOccurrences(of: store.settings.clientKey, with: "••••••••（复制时包含完整密钥）"))
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineSpacing(5)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                    if tool != .kiro {
                        HStack {
                            Button("复制配置") { store.copy(profile.snippet); message = "配置已复制，包含本地连接密钥。" }
                            if !profile.command.isEmpty { Button(tool == .kimi ? "复制启动命令（先应用配置）" : "复制临时启动命令") { store.copy(profile.command); message = "启动命令已复制。" } }
                            Spacer()
                            if tool.file != nil { Button("应用到工具") { confirmingApply = true }.buttonStyle(.borderedProminent).disabled(model.isEmpty || filePath.isEmpty || !store.running) }
                        }
                        HStack { Button("导出配置文件") { exportProfile() }; if tool.file != nil { Button("恢复上一次配置") { confirmingRestore = true } }; Spacer() }
                    }
                    if !message.isEmpty { Text(message).font(.system(size: 12)).foregroundStyle(mint).textSelection(.enabled) }
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

struct SettingsView: View {
    @EnvironmentObject var store: BridgeStore
    @State private var port = ""
    @State private var proxy = ""
    @State private var startURL = ""
    @State private var region = ""
    @State private var saved = false
    var body: some View {
        VStack(spacing: 20) {
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    Text("本地服务").font(.system(size: 15, weight: .semibold))
                    Form {
                        TextField("监听端口", text: $port).disabled(store.running)
                        TextField("出站网络代理", text: $proxy, prompt: Text("例如 socks5://127.0.0.1:1080，留空为直连"))
                        TextField("Kiro 组织 Start URL", text: $startURL, prompt: Text("个人 Builder ID 账号留空"))
                        TextField("Kiro 组织区域", text: $region)
                    }.textFieldStyle(.roundedBorder)
                    Text("监听地址固定为 127.0.0.1。修改端口前请停止服务；修改后需要重新应用工具配置。订阅登录与模型请求可使用出站代理。").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                    HStack {
                        Button("保存设置") {
                            var next = store.settings; next.port = Int(port) ?? 0; next.proxyURL = proxy.trimmingCharacters(in: .whitespacesAndNewlines); next.kiroStartURL = startURL; next.kiroRegion = region
                            Task { do { try await store.update(next); saved = true; store.record("本地服务设置已保存") } catch { store.report(error) } }
                        }.buttonStyle(.borderedProminent).disabled(store.busy)
                        if saved { Text("已保存").font(.system(size: 12)).foregroundStyle(mint) }
                        Spacer()
                        Button("打开数据与备份目录") { store.showDataDirectory() }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("本地数据与内核").font(.system(size: 14, weight: .semibold))
                    Text(store.dataDirectory.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                    Text("API Key 和订阅凭据以本地文件保存，数据目录仅当前用户可读写。配置导出会包含本地连接密钥。关闭窗口后服务继续运行，可从菜单栏返回；退出 App 时停止内核。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                    HStack { Pill(text: "CLIProxyAPI 8.0.51", active: false); Pill(text: "Kiro Plugin 0.1.1", active: false); Pill(text: "MIT", active: false) }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("本次运行记录").font(.system(size: 14, weight: .semibold)); Spacer(); Button("清空") { store.activities.removeAll() } }
                    if store.activities.isEmpty { Text("暂无操作记录").foregroundStyle(.secondary).font(.system(size: 12)) }
                    ForEach(store.activities.prefix(25)) { event in
                        HStack(alignment: .top, spacing: 12) {
                            Text(event.date, style: .time).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 65, alignment: .leading)
                            Circle().fill(event.failed ? .orange : mint).frame(width: 5, height: 5).padding(.top, 5)
                            Text(event.message).font(.system(size: 12)).foregroundStyle(event.failed ? .orange : .white.opacity(0.8)).textSelection(.enabled)
                            Spacer()
                        }
                    }
                }
            }
        }.onAppear { port = String(store.settings.port); proxy = store.settings.proxyURL; startURL = store.settings.kiroStartURL; region = store.settings.kiroRegion }
    }
}
