import Foundation

/// Provider families shown as icons on the merged accounts and channels page.
/// A family groups subscription logins and API Key presets from the same vendor.
enum SourceFamily: String, CaseIterable, Identifiable {
    case claude, gpt, kimi, kiro, cursor, grok, glm, deepseek, custom
    var id: String { rawValue }

    /// The accounts page presents Grok through the Cursor integration. Keep
    /// `.grok` in the model for old data and routing compatibility, but do not
    /// expose a second service-provider icon or add section.
    static let visibleCases: [SourceFamily] = [.claude, .gpt, .kimi, .kiro, .cursor, .glm, .deepseek, .custom]

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .gpt: return "GPT"
        case .kimi: return "Kimi"
        case .kiro: return "Kiro"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        case .glm: return "智谱 GLM"
        case .deepseek: return "DeepSeek"
        case .custom: return "自定义"
        }
    }

    var iconName: String? {
        switch self {
        case .claude: return "claude"
        case .gpt: return "codex"
        case .kimi: return "kimi"
        case .kiro: return "kiro"
        case .cursor: return "cursor"
        case .grok: return "grok"
        case .glm: return "zcode"
        case .deepseek: return "deepseek"
        case .custom: return nil
        }
    }

    /// Kimi and ZCode list one card each; their international variant is a region tab on that card.
    var subscriptionIDs: [String] {
        switch self {
        case .claude: return ["claude"]
        case .gpt: return ["codex"]
        case .kimi: return ["kimi"]
        case .kiro: return ["kiro"]
        // Grok Bot and Grok Build / xAI are managed from this shared page.
        case .cursor: return [CursorAccountProfile.providerID, "xai"]
        // Keep the legacy IDs for callers that still inspect the hidden family.
        case .grok: return ["xai", CursorAccountProfile.providerID]
        case .glm: return ["zcode-bigmodel"]
        case .deepseek, .custom: return []
        }
    }

    var presetIDs: [String] {
        switch self {
        case .claude: return ["claude"]
        case .gpt: return ["codex"]
        case .kimi: return ["kimi-code", "kimi-code-ai", "kimi", "kimi-ai"]
        // The API preset is rendered in the Cursor section now. Keep the
        // preset itself and the hidden family enum for old saved data.
        case .grok: return []
        case .glm: return ["zcode", "zai"]
        case .deepseek: return ["deepseek"]
        case .custom: return ["relay"]
        case .kiro: return []
        // xAI/Grok API keys are still available from the Cursor section.
        case .cursor: return ["grok"]
        }
    }

    var includesKimiWork: Bool { self == .kimi }

    static func of(subscription provider: String) -> SourceFamily {
        let id = SubscriptionProvider.find(provider)?.id ?? provider
        switch id {
        case "claude": return .claude
        case "codex": return .gpt
        case "kimi", "kimi-ai": return .kimi
        case "kiro": return .kiro
        case CursorAccountProfile.providerID, "xai": return .cursor
        case "zcode-bigmodel", "zcode-zai": return .glm
        default: return .custom
        }
    }

    static func of(_ account: Account) -> SourceFamily {
        return of(subscription: account.loginProvider)
    }

    static func of(_ channel: Channel) -> SourceFamily {
        if channel.isKimiWork { return .kimi }
        guard let preset = Preset.matching(channel) else { return .custom }
        // Grok API channels remain routable, but are shown in the Cursor
        // section together with the Cursor web integration.
        return visibleCases.first { $0.presetIDs.contains(preset.id) } ?? .custom
    }
}
