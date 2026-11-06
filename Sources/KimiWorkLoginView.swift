import SwiftUI
import WebKit

struct KimiWorkLoginView: View {
    @EnvironmentObject var store: BridgeStore
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var message = "请在下方 Kimi 官方网页完成登录。Assropic 会独立保存此次登录。"
    @State private var attempt = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("登录 Kimi Work").font(.title2)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("关闭") { dismiss() }.disabled(saving)
            }
            Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            KimiWorkWebLogin { access, refresh in
                guard !saving else { return }
                saving = true
                message = "正在验证登录并获取 Work 模型…"
                Task { @MainActor in
                    do {
                        try await store.connectKimiWork(accessToken: access, refreshToken: refresh)
                        dismiss()
                    } catch {
                        message = error.localizedDescription
                        saving = false
                    }
                }
            }.id(attempt)
            HStack {
                Text("无需 Kimi 桌面端；Work 与 Kimi Code 使用各自的额度。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("重新登录") { attempt = UUID() }.disabled(saving)
            }
        }.padding(20).frame(width: 920, height: 700)
    }
}

private struct KimiWorkWebLogin: NSViewRepresentable {
    let connected: (String, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(connected: connected) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // A separate browser session gives Assropic its own refresh token.
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.start()
        view.load(URLRequest(url: URL(string: "https://www.kimi.com/")!))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
        coordinator.timer = nil
        view.stopLoading()
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var view: WKWebView?
        var timer: Timer?
        var delivered = false
        let connected: (String, String) -> Void
        init(connected: @escaping (String, String) -> Void) { self.connected = connected }
        func start() {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkLogin() }
        }
        func checkLogin() {
            guard !delivered, let view, view.url?.scheme == "https", view.url?.host == "www.kimi.com" else { return }
            // These are the official site's signed-in keys. Anonymous tokens are ignored.
            view.evaluateJavaScript("(() => { if (location.origin !== 'https://www.kimi.com') return null; return {access: localStorage.getItem('access_token'), refresh: localStorage.getItem('refresh_token')}; })()") { [weak self] result, _ in
                guard let self, !self.delivered, let tokens = result as? [String: Any],
                      let access = tokens["access"] as? String, !access.isEmpty,
                      let refresh = tokens["refresh"] as? String, !refresh.isEmpty,
                      KimiWorkSession.claims(access)?["sub"] as? String != nil else { return }
                self.delivered = true
                self.connected(access, refresh)
            }
        }
    }
}
