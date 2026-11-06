import Foundation

@main
struct LocalSubscriptionIdentityTests {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fatalError(name) }
            count += 1
        }
        func jwt(_ value: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            let base64 = data.base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "header." + base64 + ".signature"
        }
        let original: [String: Any] = ["account_id": "business-a", "access_token": "old-access", "refresh_token": "old-refresh"]
        let renewed: [String: Any] = ["account_id": "business-a", "access_token": "new-access", "refresh_token": "new-refresh"]
        let filename = LocalSubscriptionIdentity.filename(provider: "codex", document: original)
        check(filename == LocalSubscriptionIdentity.filename(provider: "codex", document: renewed), "Renewal preserves file identity")
        check(filename != LocalSubscriptionIdentity.filename(provider: "codex", document: ["account_id": "personal-b"]), "Workspaces stay separate")
        let fromClaims: [String: Any] = ["id_token": try jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "business-a"]])]
        check(filename == LocalSubscriptionIdentity.filename(provider: "codex", document: fromClaims), "JWT account id matches native account id")
        check(filename != LocalSubscriptionIdentity.filename(provider: "claude", document: original), "Providers stay separate")
        check(LocalSubscriptionIdentity.stableIdentity(["access_token": "opaque"]) == nil, "Opaque tokens cannot prove account identity")
        check(!filename.contains("business-a") && !filename.contains("old-access"), "Filenames expose no account identity or token")
        check(LocalSubscriptionIdentity.prefix(provider: "codex", occupied: []) == "gpt", "GPT label stays distinct from API channels")
        check(LocalSubscriptionIdentity.prefix(provider: "claude", occupied: ["claude", "claude-2", "claude-3"]) == "claude-4", "Choose an unoccupied prefix")
        check(LocalSubscriptionIdentity.prefix(provider: "kiro", occupied: ["gpt"]) == "kiro", "Providers retain distinct default prefixes")
        let isolated = LocalSubscriptionIdentity.isolatedPrefix(provider: "claude", identity: "local-a", occupied: [])
        check(isolated.hasPrefix("claude-") && isolated != "claude", "CCBaga accounts receive isolated route prefixes")
        check(LocalSubscriptionIdentity.isolatedPrefix(provider: "claude", identity: "local-a", occupied: []) == isolated,
              "CCBaga route prefixes remain stable")
        print("PASS \(count) local subscription identity and prefix assertions")
    }
}
