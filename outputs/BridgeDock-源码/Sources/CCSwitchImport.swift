import AppKit
import CoreServices

/// 接管中转站发出的 ccswitch:// 导入链接：自动识别后直接存成 BridgeDock 的 API 渠道，仍走 BD 自己的反代内核。
/// 只有缺少必要信息（如查不到模型）时才打开编辑器让用户补全。
extension BridgeStore {
    private static let importProbe = URL(string: "ccswitch://v1/import")!

    func receiveImportLink(_ url: URL) {
        guard settings.handlesImportLinks else {
            record("已关闭中转站一键导入，忽略收到的导入链接", failed: true)
            return
        }
        let item: ChannelImport
        do {
            item = try CCSwitchLink(url).channelImport(existing: settings.channels, accounts: accounts)
        } catch { report(error); return }
        importNotice = "正在导入 \(item.site)…"
        Task { await autoImport(item) }
    }

    private func autoImport(_ item: ChannelImport) async {
        // 冷启动时链接先于内核就绪到达；等服务起来、别的配置操作结束再保存。
        for _ in 0..<120 where !running || busy || workSyncing {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if !running && !busy { await start() }
        var channel = item.channel
        if channel.models.isEmpty, running, let found = try? await discoverModels(for: channel), !found.modelLines.isEmpty {
            channel.modelLines = found.modelLines
            if !found.capabilities.isEmpty { channel.capabilities = found.capabilities }
        }
        do {
            try await saveChannel(channel)
            await publishModels(of: channel.id)
            let count = settings.channels.first { $0.id == channel.id }?.models.count ?? channel.models.count
            importNotice = (item.existingName == nil ? "已导入" : "已更新") + " \(item.site) · \(channel.wire.title) · \(count) 个模型，经 BridgeDock 本地反代使用。"
            record("中转站一键导入 · \(channel.name)")
        } catch {
            importNotice = ""
            record("中转站导入需要补全：" + redacted(error.localizedDescription), failed: true)
            pendingImport = ChannelImport(channel: channel, site: item.site, existingName: item.existingName)
        }
    }

    /// 已手动挑选过开放模型时，新导入渠道的模型默认也开放，导入后即可在各工具里选用。
    func publishModels(of channelID: String) async {
        guard let current = settings.publishedModelIDs else { return }
        let added = availableModels.filter { $0.sourceID == "channel:" + channelID }.map(\.id)
        let next = Set(current).union(added)
        guard next.count != current.count else { return }
        try? await savePublishedModels(next)
    }

    private var importLinkHandler: URL? { NSWorkspace.shared.urlForApplication(toOpen: Self.importProbe) }

    func refreshImportLinkStatus() {
        let handler = importLinkHandler
        if !settings.handlesImportLinks {
            importLinkStatus = "已关闭，收到的导入链接会被忽略。"
        } else if handler?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL {
            importLinkStatus = "中转站的“导入 CC Switch”按钮会直接导入 BridgeDock。"
        } else if let handler, Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier {
            importLinkStatus = "导入链接由另一份 BridgeDock 副本打开：" + handler.path
        } else if let handler {
            importLinkStatus = "导入链接当前由 \(FileManager.default.displayName(atPath: handler.path)) 打开，重新打开开关可改回 BridgeDock。"
        } else {
            importLinkStatus = "系统尚未登记导入链接的打开方式。"
        }
    }

    func claimImportLinks() {
        guard settings.handlesImportLinks else { refreshImportLinkStatus(); return }
        let app = Bundle.main.bundleURL
        guard importLinkHandler?.standardizedFileURL != app.standardizedFileURL else { refreshImportLinkStatus(); return }
        LSRegisterURL(app as CFURL, true)
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "ccswitch") { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.record("未能接管中转站导入链接：" + error.localizedDescription, failed: true) }
                else { self.record("已接管中转站导入链接（ccswitch://）") }
                self.refreshImportLinkStatus()
            }
        }
    }

    func setHandlesImportLinks(_ enabled: Bool) async {
        var next = settings
        next.handlesImportLinks = enabled
        do { try await update(next) } catch { report(error); return }
        if enabled { claimImportLinks() } else { refreshImportLinkStatus() }
    }

    func openManagePage(_ channel: Channel) {
        guard let url = URL(string: channel.manageURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}

