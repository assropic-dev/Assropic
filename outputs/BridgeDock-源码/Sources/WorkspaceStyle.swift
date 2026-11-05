import SwiftUI

// Shared warm, light palette for the workspace and its sheets.
let canvas = Color(red: 0.985, green: 0.980, blue: 0.969)
let panel = Color.white
let sidebarSurface = Color(red: 0.955, green: 0.947, blue: 0.929)
let insetSurface = Color(red: 0.966, green: 0.960, blue: 0.948)
let ink = Color(red: 0.19, green: 0.18, blue: 0.16)
let mutedInk = Color(red: 0.45, green: 0.43, blue: 0.40)
let hairline = Color(red: 0.87, green: 0.85, blue: 0.82)
let accent = Color(red: 0.69, green: 0.32, blue: 0.22)
let healthy = Color(red: 0.29, green: 0.44, blue: 0.34)
let warning = Color(red: 0.62, green: 0.36, blue: 0.12)

struct WorkspaceButtonStyle: ButtonStyle {
    var prominent = false
    var fixedSize: CGSize? = nil
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(fixedSize == nil ? nil : 1)
            .padding(.horizontal, fixedSize == nil ? 14 : 8)
            .padding(.vertical, fixedSize == nil ? 9 : 0)
            .frame(width: fixedSize?.width, height: fixedSize?.height)
            .foregroundStyle(prominent ? Color.white : (configuration.role == .destructive ? Color(red: 0.70, green: 0.21, blue: 0.18) : ink))
            .background(prominent ? accent : panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(prominent ? Color.clear : hairline, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.42)
    }
}

let failureTint = Color(red: 0.70, green: 0.21, blue: 0.18)

struct Card<Content: View>: View {
    var padding: CGFloat = 28
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(hairline.opacity(0.75), lineWidth: 1))
            .shadow(color: ink.opacity(0.025), radius: 8, x: 0, y: 3)
    }
}

struct Pill: View {
    let text: String
    var active = true
    var tint: Color? = nil
    var body: some View {
        let color = tint ?? (active ? accent : mutedInk)
        Text(text).font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background((tint ?? (active ? accent : Color.gray)).opacity(0.1), in: Capsule())
    }
}

extension View {
    /// 卡片或分区标题。
    func sectionTitle() -> some View { font(.system(size: 14, weight: .semibold)) }
    /// 次要说明文字。
    func captionText(_ size: CGFloat = 11) -> some View { font(.system(size: size)).foregroundStyle(mutedInk) }
    /// 模型 ID、路径等等宽小字。
    func monoSmall(_ size: CGFloat = 11) -> some View { font(.system(size: size, design: .monospaced)) }
}

enum NoticeTone { case info, success, failure }

/// 操作结果提示：成功、失败与普通信息使用不同颜色。
struct NoticeBanner: View {
    let text: String
    var tone: NoticeTone = .info
    private var color: Color { tone == .success ? healthy : (tone == .failure ? failureTint : accent) }
    private var symbol: String { tone == .success ? "checkmark.circle.fill" : (tone == .failure ? "xmark.octagon.fill" : "info.circle.fill") }
    var body: some View {
        Label(text, systemImage: symbol).font(.system(size: 12)).foregroundStyle(color).textSelection(.enabled)
            .padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// 列表搜索框。
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(mutedInk)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(mutedInk).help("清除搜索")
            }
        }.font(.system(size: 12)).padding(9).background(insetSurface, in: RoundedRectangle(cornerRadius: 9))
    }
}

