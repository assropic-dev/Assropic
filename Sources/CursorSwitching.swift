import Foundation
import AppKit

extension BridgeStore {
    var cursorInstaller: CursorLocalInstaller {
        CursorLocalInstaller(directory: dataDirectory,
                             resources: Bundle.main.resourceURL!.appendingPathComponent("CursorLocal"),
                             app: URL(fileURLWithPath: "/Applications/Cursor.app"))
    }

    var cursorProxyActive: Bool {
        cursorIdentity.enabled && running && cursorInstalled && cursorSessionReady
    }

    // A saved preference is not proof that Cursor can use the proxy. During a
    // switch, show the requested position immediately; only commit it on success.
    var cursorToggleEnabled: Bool { cursorPendingEnabled ?? cursorProxyActive }
    var cursorNeedsRecovery: Bool { cursorIdentity.enabled && !cursorProxyActive && !cursorBusy }
    var cursorModeTitle: String {
        if let pending = cursorPendingEnabled { return pending ? "正在开启 Assropic 反代" : "正在切回官方账号" }
        if cursorProxyActive { return "Assropic 反代" }
        if !cursorIdentity.enabled { return "Cursor 官方账号" }
        return running ? "Assropic 反代未就绪" : "Assropic 反代已暂停"
    }

    private var runningCursorApplications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.path == "/Applications/Cursor.app" &&
                !$0.isTerminated && !ProcessLiveness.hasExited($0.processIdentifier)
        }
    }

    private func saveCursorIdentity() throws {
        try privateWrite(JSONEncoder().encode(cursorIdentity), to: dataDirectory.appendingPathComponent("cursor-local.json"))
    }

    private func cursorAdapterIsInstalled() async -> Bool {
        let installer = cursorInstaller
        return await Task.detached { installer.isInstalled() }.value
    }

    private func activateCursorSession() async throws {
        let model = settings.selectedModels["Cursor"] ?? models.first?.id ?? ""
        guard running else { throw BridgeError.message("Assropic 服务尚未启动，未切换 Cursor 模式。") }
        guard !model.isEmpty else { throw BridgeError.message("请先在 Assropic 添加账号或 API 渠道，获取可用模型后再开启 Cursor 反代。") }
        try cursorSession.update(identity: cursorIdentity, apiURL: apiURL, key: settings.clientKey, model: model)
        try await cursorSession.start()
        guard running, cursorIdentity.enabled else {
            cursorSession.stop()
            cursorSessionReady = false
            throw BridgeError.message("Assropic 服务已停止，Assropic 反代尚未开启。")
        }
        cursorSessionReady = true
        cursorStatus = "已开启 · Cursor 使用 Assropic 反代"
    }

    /// Resume a saved choice when the core starts. An adapter update follows
    /// the same graceful restart path as a user changing the switch.
    func startCursorSession() async {
        guard cursorIdentity.enabled, running, !cursorBusy else { return }
        let installed = await cursorAdapterIsInstalled()
        guard cursorIdentity.enabled, running, !cursorBusy else { return }
        cursorInstalled = installed
        // A matching adapter can keep running Cursor windows alive while the
        // Assropic process restarts. In that case only the loopback session is
        // missing; do not re-enter the destructive quit/reinstall path. That
        // path is reserved for a missing or outdated adapter.
        if !installed {
            await setCursorLocalEnabled(true)
            return
        }
        do { try await activateCursorSession() }
        catch {
            cursorSessionReady = false
            cursorStatus = "Assropic 反代暂不可用 · " + error.localizedDescription
            report(error)
        }
    }

    func setCursorLocalEnabled(_ enabled: Bool) async {
        guard !cursorBusy else { return }
        if enabled == cursorIdentity.enabled && (!enabled || cursorProxyActive) { return }
        cursorBusy = true
        cursorPendingEnabled = enabled
        cursorStatus = enabled ? "正在检查 Cursor 与本地服务" : "正在切回 Cursor 官方账号"
        defer { cursorPendingEnabled = nil; cursorBusy = false }
        let previous = cursorIdentity.enabled
        let previousSessionReady = cursorSessionReady
        var didQuit = false

        do {
            if enabled {
                let installer = cursorInstaller
                try await Task.detached { try installer.validateCompatibility() }.value
                if !running { await start() }
                guard running else { throw BridgeError.message("Assropic 服务未能启动，Cursor 保持原模式。") }
                guard !(settings.selectedModels["Cursor"] ?? models.first?.id ?? "").isEmpty else {
                    throw BridgeError.message("请先添加账号或 API 渠道，获取可用模型后再开启 Cursor 反代。")
                }
            }

            let applications = runningCursorApplications
            if !applications.isEmpty {
                cursorStatus = "正在切换 · 请在 Cursor 中完成保存，退出后会自动重新打开"
                try await quitCursor(applications)
                didQuit = true
            }

            guard runningCursorApplications.isEmpty else {
                throw BridgeError.message("Cursor 在切换期间重新启动，当前模式保持不变。请退出 Cursor 后重试。")
            }

            if enabled {
                cursorStatus = "正在准备 Assropic 反代"
                // Save the existing session secret before installing the adapter.
                try saveCursorIdentity()
                let installer = cursorInstaller
                let identity = cursorIdentity
                try await Task.detached { try installer.install(identity: identity) }.value
                cursorInstalled = true
                cursorIdentity.enabled = true
                try await activateCursorSession()
                try saveCursorIdentity()
            } else {
                cursorIdentity.enabled = false
                try saveCursorIdentity()
                cursorSession.stop()
                cursorSessionReady = false
                cursorStatus = "已关闭 · Cursor 使用原来的官方账号"
            }
            record(enabled ? "Cursor 已切换到 Assropic 反代" : "Cursor 已切回原来的官方账号")
        } catch {
            cursorIdentity.enabled = previous
            try? saveCursorIdentity()
            cursorInstalled = await cursorAdapterIsInstalled()
            cursorSession.stop()
            cursorSessionReady = false
            if previous && previousSessionReady && running && cursorInstalled { try? await activateCursorSession() }
            cursorStatus = cursorProxyActive ? "未完成切换 · 保持 Assropic 反代" :
                (previous ? "Assropic 反代未就绪 · 可重试连接或切回官方账号" : "未完成切换 · 保持 Cursor 官方账号")
            report(error)
        }

        if didQuit {
            do { try await launchCursorWindow() }
            catch {
                cursorStatus += " · 请手动打开 Cursor"
                report(error)
            }
        }
    }

    func setCursorModelParametersEnabled(_ enabled: Bool) async {
        guard !cursorBusy, enabled != cursorIdentity.modelParametersEnabled else { return }
        let previous = cursorIdentity.modelParametersEnabled
        if !cursorIdentity.enabled {
            cursorIdentity.modelParametersEnabled = enabled
            do { try saveCursorIdentity() }
            catch { cursorIdentity.modelParametersEnabled = previous; report(error) }
            return
        }
        cursorBusy = true
        defer { cursorBusy = false }
        var didQuit = false
        do {
            let installer = cursorInstaller
            try await Task.detached { try installer.validateCompatibility() }.value
            let applications = runningCursorApplications
            if !applications.isEmpty {
                cursorStatus = "正在更新模型参数 · 请在 Cursor 中完成保存"
                try await quitCursor(applications)
                didQuit = true
            }
            guard runningCursorApplications.isEmpty else {
                throw BridgeError.message("Cursor 在切换期间重新启动，请退出后重试。")
            }
            let identity = cursorIdentity
            try await Task.detached { try installer.install(identity: identity) }.value
            cursorInstalled = true
            cursorIdentity.modelParametersEnabled = enabled
            try saveCursorIdentity()
            try await activateCursorSession()
            record(enabled ? "已开启 Cursor 模型参数设置" : "已关闭 Cursor 模型参数设置")
        } catch {
            cursorIdentity.modelParametersEnabled = previous
            try? saveCursorIdentity()
            if running { try? await activateCursorSession() }
            report(error)
        }
        if didQuit {
            do { try await launchCursorWindow() }
            catch { report(error) }
        }
    }

    private func quitCursor(_ applications: [NSRunningApplication]) async throws {
        for application in applications where !application.isTerminated && !ProcessLiveness.hasExited(application.processIdentifier) {
            guard application.terminate() || application.isTerminated || ProcessLiveness.hasExited(application.processIdentifier) else {
                throw BridgeError.message("Cursor 未同意退出，请保存工作后重试。当前模式保持不变。")
            }
        }
        // Never force quit: Cursor owns the save/cancel prompt for unsaved work.
        for _ in 0..<200 {
            try Task.checkCancellation()
            // AppKit can retain a stale termination flag after the PID is gone.
            if applications.allSatisfy({ $0.isTerminated || ProcessLiveness.hasExited($0.processIdentifier) }) { return }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw BridgeError.message("Cursor 尚未退出或已取消退出。请完成保存后重新切换，当前模式保持不变。")
    }

    func prepareCursorForLaunch() async throws {
        guard !cursorBusy else { throw BridgeError.message("Cursor 正在切换模式，请稍候再打开。") }
        guard cursorIdentity.enabled else { return }
        if !running { await start() }
        else { await startCursorSession() }
        guard running else { throw BridgeError.message("请先启动 Assropic 服务。") }
        // startCursorSession already checked the current adapter. Do not hash
        // the same large Cursor bundles a second time before every launch.
        guard !cursorBusy, cursorProxyActive else {
            throw BridgeError.message("Cursor 反代尚未就绪，请检查工具接入页。")
        }
    }

    private func launchCursorWindow() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--glass"]
        _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Cursor.app"), configuration: configuration)
    }

    func openCursorWindow() async {
        guard !cursorBusy, !launchingAgent else { return }
        launchingAgent = true
        defer { launchingAgent = false }
        do {
            try await prepareCursorForLaunch()
            try await launchCursorWindow()
        } catch { report(error) }
    }
}
