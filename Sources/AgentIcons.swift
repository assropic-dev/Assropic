import AppKit

// Bundle the brand artwork so uninstalled tools still have their own logo.
// Cache image decoding; sidebar and selection changes should not reload files.
private enum AgentArtwork {
    static let images: [String: NSImage] = {
        var images: [String: NSImage] = [:]
        for name in ["cursor", "claude", "codex", "kimi", "kiro", "zcode", "grok", "deepseek"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "AgentIcons"),
               let image = NSImage(contentsOf: url) {
                image.isTemplate = false
                images[name] = image
            }
        }
        return images
    }()
}

extension ClientTool {
    var brandIcon: NSImage? {
        let name: String
        switch self {
        case .cursor: name = "cursor"
        case .claudeDesktop, .claude: name = "claude"
        case .codex: name = "codex"
        case .kimi: name = "kimi"
        case .kiro: name = "kiro"
        case .zcode: name = "zcode"
        case .generic: return nil
        }
        return AgentArtwork.images[name]
    }
}

extension SourceFamily {
    var icon: NSImage? { iconName.flatMap { AgentArtwork.images[$0] } }
}

extension EditingAgent {
    var icon: NSImage {
        let tool: ClientTool
        switch self {
        case .cursor: tool = .cursor
        case .claudeDesktop: tool = .claudeDesktop
        case .claude: tool = .claude
        case .codex: tool = .codex
        case .kimi: tool = .kimi
        case .kiro: tool = .kiro
        case .zcode: tool = .zcode
        }
        return tool.brandIcon ?? NSImage(systemSymbolName: tool.symbol, accessibilityDescription: rawValue)!
    }
}
