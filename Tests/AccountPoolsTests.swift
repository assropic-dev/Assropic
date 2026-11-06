import Foundation

/// Account pools: which accounts merge onto one prefix, which prefix a new account takes, and how
/// published route IDs follow a merge. Pure logic; no core, network or credentials.
@main
struct AccountPoolsTests {
    nonisolated(unsafe) static var passed = 0
    static func check(_ condition: Bool, _ label: String) {
        guard condition else { print("FAIL " + label); exit(1) }
        passed += 1
        print("PASS " + label)
    }

    static func account(_ name: String, _ provider: String, prefix: String = "", profile: String = "", oauth: String = "") -> Account {
        Account(["name": name, "provider": provider, "prefix": prefix, "runtime_profile": profile, "oauth_provider": oauth])
    }

    static func main() {
        // The case found on the user's machine: two local Codex imports on gpt and gpt-2.
        let gpt = account("local-codex-a.json", "codex", prefix: "gpt")
        let gpt2 = account("local-codex-b.json", "codex", prefix: "gpt-2")
        check(AccountPools.plan(accounts: [gpt, gpt2], independent: [])
              == [.init(account: "local-codex-b.json", from: "gpt-2", to: "gpt", group: "codex")],
              "gpt-2 joins gpt: one Codex pool")
        check(AccountPools.plan(accounts: [gpt, gpt2], independent: ["local-codex-b.json"]).isEmpty,
              "an account marked independent keeps its own route")
        check(AccountPools.plan(accounts: [gpt, account("c.json", "codex", prefix: "work")], independent: []).isEmpty,
              "a custom prefix is independent")
        check(AccountPools.plan(accounts: [gpt], independent: []).isEmpty, "a single account is left alone")

        // An OAuth login (no prefix) next to a local import.
        let bare = account("codex-oauth.json", "codex")
        check(AccountPools.plan(accounts: [bare, gpt], independent: []) == [.init(account: "codex-oauth.json", from: "", to: "gpt", group: "codex")],
              "a tie prefers the provider base over no prefix")
        let bare2 = account("codex-oauth-2.json", "codex")
        check(AccountPools.plan(accounts: [bare, bare2, gpt], independent: []) == [.init(account: "local-codex-a.json", from: "gpt", to: "", group: "codex")],
              "otherwise the prefix most accounts use wins")
        check(AccountPools.plan(accounts: [bare, bare2], independent: []).isEmpty, "unprefixed accounts already form one pool")

        // Groups: Kiro has its own router; Cursor and Grok Bot keys, Kimi China and Kimi.ai are separate upstreams.
        check(AccountPools.plan(accounts: [account("k1", "kiro", prefix: "kiro"), account("k2", "kiro", prefix: "kiro-2")], independent: []).isEmpty,
              "Kiro accounts are placed by the Kiro router, not merged by prefix")
        let cursorMoves = AccountPools.plan(accounts: [
            account("cursor-a.json", "cursor-agent-v1", prefix: "cursor", profile: "agent_v1"),
            account("cursor-b.json", "cursor-agent-v1", prefix: "cursor-2", profile: "agent_v1"),
            account("grok-bot-a.json", "cursor-agent-v1", prefix: "grok-bot", profile: "sand")], independent: [])
        check(cursorMoves == [.init(account: "cursor-b.json", from: "cursor-2", to: "cursor", group: "cursor-agent-v1/agent_v1")],
              "Cursor keys pool together; Grok Bot stays its own pool")
        check(AccountPools.plan(accounts: [account("cursor-a.json", "cursor-agent-v1", prefix: "cursor", profile: "agent_v1"),
                                           account("cursor-x.json", "cursor-agent-v1", profile: "agent_v1")], independent: []).isEmpty,
              "an unprefixed Cursor key has no model routes and is not merged")
        check(AccountPools.plan(accounts: [account("kimi-1", "kimi", oauth: "kimi"), account("kimi-2", "kimi", prefix: "kimi-ai", oauth: "kimi-ai")], independent: []).isEmpty,
              "Kimi China and Kimi.ai are different pools")
        check(AccountPools.plan(accounts: [account("cl-1", "claude", prefix: "claude"), account("cl-2", "claude", prefix: "claude-2"),
                                           account("cl-3", "claude", prefix: "claude-3")], independent: []).map(\.to) == ["claude", "claude"],
              "every Claude account moves onto claude")

        // New accounts join the pool.
        check(AccountPools.prefix(forNew: "codex", accounts: [gpt], independent: [], occupied: ["gpt"]) == "gpt",
              "a new Codex account joins the gpt pool")
        check(AccountPools.prefix(forNew: "codex", accounts: [bare], independent: [], occupied: []) == "",
              "a new Codex account joins an unprefixed pool")
        check(AccountPools.prefix(forNew: "claude", accounts: [gpt], independent: [], occupied: ["gpt", "kimi"]) == "claude",
              "the first account of a provider takes the base")
        check(AccountPools.prefix(forNew: "kimi", accounts: [], independent: [], occupied: ["kimi"]) == "kimi-2",
              "a base taken by an API channel falls back to a free variant")
        check(AccountPools.prefix(forNew: "codex", accounts: [account("solo.json", "codex", prefix: "gpt")], independent: ["solo.json"], occupied: ["gpt"]) == "gpt-2",
              "a new account never lands on an independent account's route")
        check(AccountPools.prefix(forNew: "cursor-agent-v1", profile: "agent_v1", accounts: [account("cursor-a.json", "cursor-agent-v1", prefix: "cursor", profile: "agent_v1")],
                                  independent: [], occupied: ["cursor"]) == "cursor",
              "a new Cursor key joins the Cursor pool")
        check(AccountPools.prefix(forNew: "kiro", accounts: [account("k1", "kiro", prefix: "kiro")], independent: [], occupied: ["kiro"]) == "kiro-2",
              "Kiro keeps one prefix per account")

        // Account settings: an empty prefix, or the pool's, rejoins the pool.
        check(AccountPools.joinPrefix(for: gpt2, accounts: [gpt, gpt2], independent: ["local-codex-b.json"]) == "gpt",
              "an independent account rejoins on the pool's prefix")
        check(AccountPools.joinPrefix(for: gpt, accounts: [gpt], independent: []) == "gpt", "a lone account keeps its automatic prefix")
        check(AccountPools.joinPrefix(for: account("x", "codex", prefix: "work"), accounts: [], independent: []) == "gpt",
              "a lone custom-prefixed account rejoins on the base")
        check(AccountPools.joinPrefix(for: account("k1", "kiro", prefix: "kiro"), accounts: [], independent: []) == nil,
              "Kiro accounts keep their prefix semantics")

        // Published routes and verified contexts follow the merge.
        let move = AccountPools.Move(account: "local-codex-b.json", from: "gpt-2", to: "gpt", group: "codex")
        let providers = ["local-codex-b.json": "codex", "codex-oauth.json": "codex", "local-codex-a.json": "codex"]
        check(AccountPools.remap(["gpt-2/gpt-6-astra", "kimi/k3"], moves: [move], owners: [:], providers: providers)
              == ["gpt-2/gpt-6-astra", "gpt/gpt-6-astra", "kimi/k3"],
              "a model published for gpt-2 is published for the merged gpt route")
        let fromBare = AccountPools.Move(account: "codex-oauth.json", from: "", to: "gpt", group: "codex")
        check(AccountPools.remap(["gpt-6-astra", "claude-sonnet-5-5"], moves: [fromBare],
                                 owners: ["gpt-6-astra": ["codex"], "claude-sonnet-5-5": ["claude"]], providers: providers)
              == ["claude-sonnet-5-5", "gpt-6-astra", "gpt/gpt-6-astra"],
              "an unprefixed account's models move only when the core lists them under its provider")
        // As found on the user's machine: the core lists Claude account models as "anthropic", and one bare ID
        // can be served by Kiro and Claude at once.
        let claudeOAuth = AccountPools.Move(account: "claude-oauth.json", from: "", to: "claude", group: "claude")
        check(AccountPools.remap(["claude-opus-5-5", "claude-sonnet-4-6", "claude-opus-5.5", "gpt/gpt-6-astra"], moves: [claudeOAuth],
                                 owners: ["claude-opus-5-5": ["anthropic"], "claude-sonnet-4-6": ["kiro", "anthropic"], "claude-opus-5.5": ["kiro"]],
                                 providers: ["claude-oauth.json": "claude"])
              == ["claude-opus-5-5", "claude-opus-5.5", "claude-sonnet-4-6", "claude/claude-opus-5-5", "claude/claude-sonnet-4-6", "gpt/gpt-6-astra"],
              "Claude models listed as anthropic, and bare IDs shared with Kiro, follow the Claude account; Kiro's own stay put")
        check(AccountPools.remap(["gpt-6-astra"], moves: [fromBare], owners: ["gpt-6-astra": ["openai"]], providers: providers) == ["gpt-6-astra", "gpt/gpt-6-astra"],
              "Codex models listed as openai follow the Codex account")
        let toBare = AccountPools.Move(account: "local-codex-a.json", from: "gpt", to: "", group: "codex")
        check(AccountPools.remap(["gpt/gpt-6-astra"], moves: [toBare], owners: [:], providers: providers) == ["gpt-6-astra", "gpt/gpt-6-astra"],
              "moving onto no prefix publishes the bare route")
        check(AccountPools.remap(["gpt-2/gpt-6-astra": [400_000], "gpt/gpt-6-astra": [1_000_000]], moves: [move], owners: [:], providers: providers)
              == ["gpt-2/gpt-6-astra": [400_000], "gpt/gpt-6-astra": [400_000, 1_000_000]],
              "verified contexts merge")

        check(AccountPools.isAutomatic("gpt-12", base: "gpt") && !AccountPools.isAutomatic("gpt-x", base: "gpt")
              && !AccountPools.isAutomatic("gpt-", base: "gpt") && AccountPools.isAutomatic("", base: "gpt"),
              "automatic prefixes are '', the base and base-N")
        print("PASS \(passed) account pool assertions; no network or real credentials.")
    }
}
