import SwiftUI

/// The same publication picker is reachable from every page and the client setup.
struct ModelPublicationButton: View {
    @EnvironmentObject var store: BridgeStore
    var title = "模型"
    var prominent = false
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 7) {
                Label(title, systemImage: "cube")
                if title == "模型" {
                    Text(String(store.models.count)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.white.opacity(0.18), in: Capsule())
                }
            }
        }
        .buttonStyle(WorkspaceButtonStyle(prominent: prominent))
        .disabled(store.busy || store.cursorBusy)
        .help("选择向 Cursor 和其他工具开放的反代模型")
        .accessibilityIdentifier(title == "模型" ? "bridgedock-models-button" : "bridgedock-models-shortcut")
        .sheet(isPresented: $showing) { ModelPublicationView().environmentObject(store) }
    }
}

struct ModelPublicationView: View {
    @EnvironmentObject var store: BridgeStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selectedOnly = false
    @State private var selection: Set<String> = []
    @State private var edited = false
    @State private var refreshing = false
    @State private var saving = false
    @State private var failure = ""

    private var groups: [ModelPublicationGroup] {
        ModelPublishing.groups(in: store.availableModels, search: search, selected: selectedOnly ? selection : nil)
    }
    private var visibleIDs: Set<String> { Set(groups.flatMap { $0.models.map(\.id) }) }
    private var selectedCount: Int { store.availableModels.filter { selection.contains($0.id) }.count }
    private var hasSearch: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("反代模型").font(.system(size: 24, weight: .semibold))
                    Text("选择提供给 Cursor 和其他工具的模型。")
                        .font(.system(size: 12)).foregroundStyle(mutedInk)
                }
                Spacer()
                Pill(text: "已选 \(selectedCount) / \(store.availableModels.count)")
            }
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(mutedInk)
                    TextField("搜索渠道或模型", text: $search).textFieldStyle(.plain)
                        .accessibilityIdentifier("model-publication-search")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(mutedInk).help("清除搜索")
                    }
                }.padding(10).background(insetSurface, in: RoundedRectangle(cornerRadius: 9))
                Toggle("只看已选", isOn: $selectedOnly).toggleStyle(.checkbox)
                Button(refreshing ? "刷新中…" : (store.running ? "刷新目录" : "启动服务")) {
                    Task { await refreshCatalog() }
                }.disabled(refreshing || store.busy)
            }.disabled(saving)
            HStack {
                Text(hasSearch || selectedOnly ? "找到 \(visibleIDs.count) 个模型 · \(groups.count) 个渠道" : "按渠道分组 · \(groups.count) 个渠道")
                    .font(.system(size: 11)).foregroundStyle(mutedInk)
                Spacer()
                Button(hasSearch ? "全选结果" : "全选") { changeSelection(visibleIDs, enabled: true) }
                    .disabled(visibleIDs.isSubset(of: selection))
                Button("清空全部") { edited = true; selection.removeAll() }
                    .disabled(selection.isEmpty)
            }.disabled(saving || refreshing)
            if !store.running {
                Label("服务已停止，启动后可获取并保存反代模型。", systemImage: "pause.circle")
                    .font(.system(size: 12)).foregroundStyle(warning)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if groups.isEmpty { emptyState }
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            groupHeader(group)
                            ForEach(group.models) { model in
                                Toggle(isOn: Binding(get: { selection.contains(model.id) }, set: {
                                    changeSelection([model.id], enabled: $0)
                                })) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(model.modelName).font(.system(size: 13, weight: .medium))
                                        Text(model.publicID).font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(mutedInk).textSelection(.enabled)
                                        Text(ModelPublishing.capabilitySummary(model.capability))
                                            .font(.system(size: 10)).foregroundStyle(mutedInk)
                                    }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                                }.toggleStyle(.checkbox).padding(.horizontal, 16)
                                    .accessibilityIdentifier("publish-model-" + model.id)
                                if model.id != group.models.last?.id { Divider().opacity(0.3).padding(.horizontal, 16) }
                            }
                        }
                        .background(panel, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hairline.opacity(0.7)))
                    }
                }.padding(.trailing, 8)
            }.frame(maxHeight: .infinity).disabled(saving || refreshing)
            if !failure.isEmpty { Text(failure).font(.system(size: 12)).foregroundStyle(.red) }
            Divider().opacity(0.4)
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedCount == 0 ? "保存后将关闭全部模型的对外调用。" : "仅开放勾选的模型；新发现的模型需另行勾选。")
                        .foregroundStyle(selectedCount == 0 ? warning : mutedInk)
                    Text("保存后反代立即生效，客户端刷新模型列表后显示。")
                        .foregroundStyle(mutedInk)
                }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("取消") { dismiss() }.disabled(saving).keyboardShortcut(.cancelAction)
                Button(saving ? "保存中…" : "保存选择") { Task { await save() } }
                    .buttonStyle(WorkspaceButtonStyle(prominent: true))
                    .disabled(saving || refreshing || !store.running || store.busy || store.availableModels.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 790, height: 620)
        .background(canvas).foregroundStyle(ink).tint(accent).preferredColorScheme(.light)
        .buttonStyle(WorkspaceButtonStyle())
        .interactiveDismissDisabled(saving)
        .onAppear { loadSelection() }
        .onChange(of: store.availableModels.map(\.id)) { _, _ in
            // A first refresh may finish after the picker opens. Never replace a draft.
            if !edited { loadSelection() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "cube.transparent").font(.system(size: 28)).foregroundStyle(mutedInk)
            Text(hasSearch ? "没有匹配的模型" : (selectedOnly ? "还没有勾选模型" : "暂无可选模型"))
                .font(.system(size: 14, weight: .medium))
            Text(hasSearch ? "试试渠道名称或更短的模型关键词。" : (selectedOnly ? "关闭“只看已选”，从渠道中勾选需要的模型。" : "先接入并启用 API 渠道或订阅账号，再刷新目录。"))
                .font(.system(size: 12)).foregroundStyle(mutedInk)
        }.frame(maxWidth: .infinity).padding(.vertical, 45)
    }

    private func groupHeader(_ group: ModelPublicationGroup) -> some View {
        let ids = Set(group.models.map(\.id))
        let count = ids.intersection(selection).count
        return HStack(spacing: 9) {
            Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(accent)
            Text(group.name).font(.system(size: 13, weight: .semibold))
            Text("\(count) / \(ids.count)").font(.system(size: 11)).foregroundStyle(mutedInk)
            Spacer()
            Button(count == ids.count ? "取消此组" : "全选此组") {
                changeSelection(ids, enabled: count != ids.count)
            }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                .help(hasSearch ? "仅作用于当前搜索结果" : "选择或取消这个渠道的模型")
        }.padding(.horizontal, 16).padding(.vertical, 12)
            .background(insetSurface, in: UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
    }

    private func changeSelection(_ ids: Set<String>, enabled: Bool) {
        edited = true
        if enabled { selection.formUnion(ids) } else { selection.subtract(ids) }
    }

    private func loadSelection() {
        selection = Set(store.settings.publishedModelIDs ?? store.availableModels.filter(\.isEnabled).map(\.id))
    }

    private func refreshCatalog() async {
        refreshing = true
        defer { refreshing = false }
        if store.running { await store.refresh() } else { await store.start() }
    }

    private func save() async {
        saving = true
        failure = ""
        defer { saving = false }
        do { try await store.savePublishedModels(selection); dismiss() }
        catch { failure = store.redacted(error.localizedDescription) }
    }
}
