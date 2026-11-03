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
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .foregroundStyle(prominent ? Color.white : (configuration.role == .destructive ? Color(red: 0.70, green: 0.21, blue: 0.18) : ink))
            .background(prominent ? accent : panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(prominent ? Color.clear : hairline, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.42)
    }
}

