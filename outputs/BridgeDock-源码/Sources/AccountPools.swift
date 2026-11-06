import Foundation

/// Accounts of one subscription share one routing prefix, so the core sees them as one pool and its
/// session affinity places new conversations across them (account 1, 2, 3, 1, …) while every
/// conversation stays on its account. A separate prefix per account made each account its own
/// route: the gateway's merged model then always picked the first one, and a newly added account's
/// models were not even published.
///
/// - A pool is one upstream: the login provider (Kimi China and Kimi.ai are two) and, for Cursor keys,
///   the runtime profile (Cursor and Grok Bot are two).
/// - Kiro is not pooled by prefix: its accounts run as separate kiro2cc workers and the gateway's
///   `KiroSessionRouter` places conversations on them.
/// - Prefixes BridgeDock assigns itself ("", the provider base, or base-2, base-3…) count as automatic and
///   are merged. A custom prefix, or an account the user marked independent, keeps its own route.
enum AccountPools {
    struct Move: Equatable {
        let account: String
        let from: String
        let to: String
        let group: String
    }

    static func group(_ account: Account) -> String? {
        guard account.provider.lowercased() != "kiro" else { return nil }
        if account.provider == CursorAccountProfile.providerID {
            return account.provider + "/" + (CursorAccountProfile(rawValue: account.runtimeProfile) ?? .cursor).rawValue
        }
        return account.loginProvider
    }

    /// The prefix a pool starts with when it has no members yet.
    static func base(_ account: Account) -> String {
        if account.provider == CursorAccountProfile.providerID {
            return (CursorAccountProfile(rawValue: account.runtimeProfile) ?? .cursor).prefix
        }
        return base(provider: account.loginProvider)
    }

    static func base(provider: String) -> String {
        switch provider {
        case "codex": return "gpt"
        case "anthropic": return "claude"
        case "zcode": return "zcode-zai"
        default: return provider
        }
    }

    static func isAutomatic(_ prefix: String, base: String) -> Bool {
        prefix.isEmpty || prefix == base
            || (prefix.hasPrefix(base + "-") && prefix.dropFirst(base.count + 1).allSatisfy(\.isNumber)
                && prefix.count > base.count + 1)
    }

    /// Accounts of `group` that follow the pool (not independent, automatic prefix).
    static func members(_ group: String, in accounts: [Account], independent: Set<String>) -> [Account] {
        accounts.filter { account in
            Self.group(account) == group && !independent.contains(account.name)
                && isAutomatic(account.prefix, base: base(account))
                // Cursor model routes are keyed by prefix; an unprefixed Cursor key has none.
                && !(account.provider == CursorAccountProfile.providerID && account.prefix.isEmpty)
        }
    }

    /// The prefix most members already use. Ties prefer the provider base, then any named prefix over
    /// "" (a named prefix cannot collide with another provider's unprefixed models), then the smaller name.
    static func target(of members: [Account], base: String) -> String? {
        guard !members.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for member in members { counts[member.prefix, default: 0] += 1 }
        return counts.max { a, b in
            if a.value != b.value { return a.value < b.value }
            func rank(_ prefix: String) -> Int { prefix == base ? 2 : (prefix.isEmpty ? 0 : 1) }
            if rank(a.key) != rank(b.key) { return rank(a.key) < rank(b.key) }
            return a.key > b.key
        }?.key
    }

    /// Accounts whose prefix should change so every pool uses one prefix.
    static func plan(accounts: [Account], independent: Set<String>) -> [Move] {
        var moves: [Move] = []
        let groups = Set(accounts.compactMap(group)).sorted()
        for group in groups {
            let members = members(group, in: accounts, independent: independent)
            guard members.count >= 2, let first = members.first,
                  let target = target(of: members, base: base(first)) else { continue }
            for member in members.sorted(by: { $0.name < $1.name }) where member.prefix != target {
                moves.append(Move(account: member.name, from: member.prefix, to: target, group: group))
            }
        }
        return moves
    }

    /// The prefix for a new account of `provider` (and Cursor `profile`): the existing pool's prefix,
    /// otherwise the base, otherwise a free variant of it.
    static func prefix(forNew provider: String, profile: String = "", accounts: [Account],
                       independent: Set<String>, occupied: Set<String>) -> String {
        let probe = Account(["name": "\u{1F}new", "provider": provider, "runtime_profile": profile])
        let base = base(probe)
        if let group = group(probe),
           let pool = target(of: members(group, in: accounts, independent: independent), base: base),
           !pool.isEmpty || provider != CursorAccountProfile.providerID {
            return pool
        }
        // No pool yet. `occupied` holds channel prefixes and every account's, independent ones included,
        // so a new account never lands on an independent account's route.
        return LocalSubscriptionIdentity.prefix(provider: base, occupied: occupied)
    }

    /// The prefix `account` takes when it (re)joins its pool from account settings: the pool's prefix, or,
    /// with no other member, its own automatic prefix or the base. nil: the provider is not pooled by prefix.
    static func joinPrefix(for account: Account, accounts: [Account], independent: Set<String>) -> String? {
        guard let group = group(account) else { return nil }
        let others = accounts.filter { $0.name != account.name }
        let base = base(account)
        if let pool = target(of: members(group, in: others, independent: independent.subtracting([account.name])), base: base) {
            return pool
        }
        let cursorKey = account.provider == CursorAccountProfile.providerID
        return isAutomatic(account.prefix, base: base) && !(cursorKey && account.prefix.isEmpty) ? account.prefix : base
    }

    /// Published route IDs and verified contexts follow the move, so a merged account keeps serving the
    /// models that were published for it. Old IDs stay: they are inert once no route carries them.
    /// `owners` maps an unprefixed route ID to the owners the core lists it under (one bare ID can be served
    /// by several providers, for example Kiro and Claude), to tell which bare IDs a moved account served.
    static func remap(_ ids: [String], moves: [Move], owners: [String: Set<String>], providers: [String: String]) -> [String] {
        var result = ids
        var present = Set(ids)
        for move in moves {
            for id in ids {
                guard let moved = renamed(id, move: move, owner: owners[id], provider: providers[move.account]),
                      present.insert(moved).inserted else { continue }
                result.append(moved)
            }
        }
        return result.sorted()
    }

    static func remap(_ contexts: [String: [Int]], moves: [Move], owners: [String: Set<String>], providers: [String: String]) -> [String: [Int]] {
        var result = contexts
        for move in moves {
            for (id, values) in contexts {
                guard let moved = renamed(id, move: move, owner: owners[id], provider: providers[move.account]) else { continue }
                result[moved] = Array(Set((result[moved] ?? []) + values)).sorted()
            }
        }
        return result
    }

    /// The core's `owned_by` for a provider's models: Claude accounts list theirs as "anthropic",
    /// Codex accounts as "openai".
    static func owners(of provider: String) -> Set<String> {
        let name = provider.lowercased()
        switch name {
        case "claude", "anthropic": return ["claude", "anthropic"]
        case "codex", "openai": return ["codex", "openai"]
        default: return [name]
        }
    }

    private static func renamed(_ id: String, move: Move, owner: Set<String>?, provider: String?) -> String? {
        if move.from.isEmpty {
            // A bare ID belongs to the moved account only when the core lists it under that provider.
            guard !id.contains("/"), let owner, let provider,
                  !owners(of: provider).isDisjoint(with: owner.map { $0.lowercased() }) else { return nil }
            return move.to + "/" + id
        }
        guard id.hasPrefix(move.from + "/") else { return nil }
        let rest = id.dropFirst(move.from.count + 1)
        return move.to.isEmpty ? String(rest) : move.to + "/" + rest
    }
}
