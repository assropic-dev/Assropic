import Foundation
import CryptoKit

/// One Kiro account served by its own kiro2cc process (see `KiroWorkerPool`).
struct KiroWorkerRoute: Equatable, Sendable {
    /// The account's stable slot number as text; shown in logs and the `X-BridgeDock-Kiro-Account` header.
    let id: String
    let port: Int
    /// The worker's client key; it is bound to the worker's single account.
    let key: String
    /// The account's routing prefix ("" for an unprefixed account).
    let prefix: String
    /// The account takes part in the shared pool.
    let pooled: Bool
}

/// The Kiro workers the gateway can send to. The gateway holds nil while no worker is ready,
/// which sends Kiro models back to the core.
struct KiroGatewayRoute: Sendable {
    let workers: [KiroWorkerRoute]

    /// Workers that may serve a model with `prefix`. When every account of the prefix belongs to
    /// the shared pool and the pool has two or more accounts, all pooled workers are candidates;
    /// otherwise only the prefix's own workers are, so an opted-out account stays reachable alone.
    func candidates(prefix: String) -> [KiroWorkerRoute] {
        let own = workers.filter { $0.prefix == prefix }
        guard !own.isEmpty else { return [] }
        let pool = workers.filter(\.pooled)
        return pool.count >= 2 && own.allSatisfy(\.pooled) ? pool : own
    }
}

/// A stable key for one client conversation, so every turn of it reaches the same account.
/// Mirrors kiro2cc's own conversation id: an explicit client session id when present, otherwise
/// a hash of the system prompt's start and the first user message, which every turn resends
/// unchanged. Tool lists and the model are left out on purpose: clients change them mid-conversation.
enum KiroSessionKey {
    static func derive(_ body: [String: Any]) -> String? {
        if let metadata = body["metadata"] as? [String: Any], let user = metadata["user_id"] as? String, !user.isEmpty {
            return digest("metadata\u{1F}" + user)
        }
        if let cache = body["prompt_cache_key"] as? String, !cache.isEmpty { return digest("cache\u{1F}" + cache) }
        var system = text(body["system"]) + text(body["instructions"])
        var firstUser: String?
        let items = (body["messages"] as? [Any]) ?? (body["input"] as? [Any]) ?? []
        for case let item as [String: Any] in items {
            let role = item["role"] as? String ?? ""
            if role == "system" || role == "developer" { system += text(item["content"]); continue }
            if role == "user" { firstUser = text(item["content"]); break }
        }
        if firstUser == nil, let input = body["input"] as? String { firstUser = input }
        guard let firstUser, !firstUser.isEmpty else { return nil }
        return digest("prompt\u{1F}" + String(system.prefix(2000)) + "\u{1F}" + firstUser)
    }

    static func text(_ value: Any?) -> String {
        switch value {
        case let text as String: return text
        case let parts as [Any]:
            return parts.map { part -> String in
                if let text = part as? String { return text }
                guard let part = part as? [String: Any] else { return "" }
                if let text = part["text"] as? String { return text }
                if let content = part["content"] { return Self.text(content) }
                return ""
            }.joined(separator: "\n")
        default: return ""
        }
    }

    /// 16 hex characters: enough to tell conversations apart, and nothing of the prompt is kept.
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Keeps each conversation on one Kiro account and spreads new conversations over the accounts.
///
/// The switching standard:
/// - A new conversation goes to the account with the fewest active conversations.
/// - A conversation stays on its account. It moves only when
///   - it failed there `sessionFailureThreshold` times in a row within `failureWindow`, or
///   - its account answered with a quota, auth or suspension error, or
///   - its account has been gone from the route for `missingGrace`.
/// - While its account's circuit is open, or its worker is restarting, single turns are served by
///   another account and the conversation returns home afterwards.
/// - An account whose requests failed `workerFailureThreshold` times in a row takes no new work for
///   `cooldown`; afterwards one request probes it, and a success closes the circuit.
/// - A failed request may be retried on another account before anything reached the client; that
///   retry does not move the conversation.
/// - 429 is a rate limit, not an exhausted quota (kiro2cc reports that as 402 after backing off on its
///   own): the account rests for its Retry-After (capped at `throttleCap`) and its conversations keep
///   their home, so the prompt cache there stays warm. Moving them would only shift the burst.
/// - 401/403 is confirmed before it counts: the first rests the account for `authConfirmCooldown`
///   (a worker that just restarted can reject its key for a moment); a second one within
///   `failureWindow` is treated like a quota error.
/// - Turns served away from home (a retry or a standby) go to the account with the fewest requests in
///   flight, so a burst of failovers spreads out instead of piling onto one account.
/// Client errors (400, 404, 413, 422…) describe the request, not the account, and count for nothing.
final class KiroSessionRouter: @unchecked Sendable {
    struct Policy {
        var affinityTTL: TimeInterval = 6 * 60 * 60
        /// A conversation counts toward its account's load while used this recently.
        var activeWindow: TimeInterval = 30 * 60
        var sessionFailureThreshold = 3
        var failureWindow: TimeInterval = 10 * 60
        var workerFailureThreshold = 5
        var cooldown: TimeInterval = 2 * 60
        /// Quota, auth and suspension errors: the account cannot serve, so it rests longer.
        var hardCooldown: TimeInterval = 10 * 60
        /// A refused connection usually means the worker is restarting; try it again soon.
        var unreachableCooldown: TimeInterval = 15
        /// How long a conversation waits for its account to come back to the route before moving.
        var missingGrace: TimeInterval = 60
        /// Rest after a 429 without a usable Retry-After, and the longest rest a Retry-After can ask for.
        var throttleDefault: TimeInterval = 5
        var throttleCap: TimeInterval = 60
        /// Rest after a first 401/403, before it is confirmed by a second one.
        var authConfirmCooldown: TimeInterval = 30
    }

    enum Outcome: Equatable {
        case success
        /// `retryAfter`: the upstream's Retry-After in seconds, when it sent one.
        case failure(status: Int, retryAfter: TimeInterval? = nil)
        case unreachable
        /// The client went away; only the in-flight count changes.
        case cancelled
    }

    /// `throttled`: rate limited (429). `auth`: rejected (401/403), confirmed by a repeat.
    /// `hard`: out of quota (402). `soft`: transient (408, 409, 5xx).
    enum FailureKind: Equatable { case none, client, soft, throttled, auth, hard }

    static func classify(status: Int) -> FailureKind {
        switch status {
        case 200..<400: return .none
        case 402: return .hard
        case 401, 403: return .auth
        case 429: return .throttled
        case 408, 409, 500...599: return .soft
        default: return .client
        }
    }

    /// Statuses worth one retry on another account, as long as nothing reached the client yet.
    static func retriesElsewhere(status: Int) -> Bool { classify(status: status) != .none && classify(status: status) != .client }

    /// Seconds from a Retry-After header: delta-seconds or an HTTP date.
    static func retryAfter(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let text = header?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = Double(text) { return seconds >= 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text).map { max(0, $0.timeIntervalSince(now)) }
    }

    struct Choice: Equatable {
        let worker: KiroWorkerRoute
        /// "sticky", "new", "moved", "retry" (this request failed on its account) or "standby" (its account is cooling down or restarting).
        let reason: String
    }

    struct Snapshot: Encodable {
        struct Session: Encodable { let id: String; let account: String; let idleSeconds: Int; let failures: Int }
        struct Account: Encodable {
            let id: String; let inFlight: Int; let sessions: Int; let consecutiveFailures: Int; let circuitOpen: Bool
            /// Seconds until the account takes new work again; 0 when it is not resting.
            let restSeconds: Int
            /// Why it rests: "throttled", "auth", "quota", "failures", "unreachable" or "" when it does not.
            let restReason: String
        }
        let sessions: [Session]
        let accounts: [Account]
    }

    private struct Binding {
        var worker: String
        var lastUsed: Date
        var failures = 0
        var lastFailure: Date?
        /// When the bound account dropped out of the route (removed, or its worker restarting).
        var missingSince: Date?
    }

    private struct Health {
        var inFlight = 0
        var failures = 0
        var openUntil: Date?
        var openReason = ""
        var authFailures = 0
        var lastAuthFailure: Date?
    }

    let policy: Policy
    private let clock: () -> Date
    private let lock = NSLock()
    private var bindings: [String: Binding] = [:]
    /// Conversations taken off an account; their next placement avoids that account when it can.
    private var evictedFrom: [String: String] = [:]
    private var health: [String: Health] = [:]
    private var rotation = 0
    /// One line per routing decision (placement, move, circuit change), called outside the lock.
    var onEvent: ((String) -> Void)?
    /// Called outside the lock after any change to bindings or in-flight counts.
    var onStateChange: (() -> Void)?

    init(policy: Policy = Policy(), clock: @escaping () -> Date = Date.init) {
        self.policy = policy
        self.clock = clock
    }

    /// Picks the account for one request. `tried` lists accounts this request already failed on.
    func select(session: String?, candidates: [KiroWorkerRoute], excluding tried: Set<String> = []) -> Choice? {
        let now = clock()
        var events: [String] = []
        let choice: Choice? = lock.withLock {
            prune(now)
            let remaining = candidates.filter { !tried.contains($0.id) }
            guard !remaining.isEmpty else { return nil }
            let closed = remaining.filter { !isOpen($0.id, now) }
            // Every circuit open: trying one still beats failing the request outright.
            let eligible = closed.isEmpty ? remaining : closed
            guard let session else { return Choice(worker: leastLoaded(eligible, now: now, temporary: true), reason: "new") }
            if var binding = bindings[session] {
                if let bound = eligible.first(where: { $0.id == binding.worker }) {
                    binding.lastUsed = now
                    binding.missingSince = nil
                    bindings[session] = binding
                    return Choice(worker: bound, reason: "sticky")
                }
                if tried.contains(binding.worker) {
                    // This request failed on the bound account; serve it elsewhere, keep the binding.
                    return Choice(worker: leastLoaded(eligible, now: now, temporary: true), reason: "retry")
                }
                let present = candidates.contains { $0.id == binding.worker }
                let missingSince = present ? nil : (binding.missingSince ?? now)
                if present || now.timeIntervalSince(missingSince!) < policy.missingGrace {
                    // Its account is cooling down or restarting: serve this turn elsewhere and keep the
                    // conversation's home, so it returns there once the account is back.
                    binding.lastUsed = now
                    binding.missingSince = missingSince
                    bindings[session] = binding
                    let stand = leastLoaded(eligible, now: now, temporary: true)
                    events.append("会话 \(session) 的账号 #\(binding.worker) \(present ? "熔断中" : "暂不可用")，本轮临时由 #\(stand.id) 处理")
                    return Choice(worker: stand, reason: "standby")
                }
                let next = leastLoaded(eligible, now: now)
                bindings[session] = Binding(worker: next.id, lastUsed: now)
                events.append("会话 \(session) 从账号 #\(binding.worker) 改到 #\(next.id)（原账号已移除超过 \(Int(policy.missingGrace)) 秒）")
                return Choice(worker: next, reason: "moved")
            }
            var pool = eligible
            var note = "当前会话数最少"
            if let avoid = evictedFrom.removeValue(forKey: session) {
                let others = pool.filter { $0.id != avoid }
                if !others.isEmpty { pool = others; note = "原账号 #\(avoid) 连续失败" }
            }
            let next = leastLoaded(pool, now: now)
            bindings[session] = Binding(worker: next.id, lastUsed: now)
            events.append("会话 \(session) 分配到账号 #\(next.id)（\(note)）")
            return Choice(worker: next, reason: "new")
        }
        emit(events)
        onStateChange?()
        return choice
    }

    func begin(_ worker: String) {
        lock.withLock { health[worker, default: Health()].inFlight += 1 }
        onStateChange?()
    }

    /// Reports how one request on `worker` ended. Call exactly once per `begin`.
    func finish(_ worker: String, session: String?, outcome: Outcome) {
        let now = clock()
        var events: [String] = []
        lock.withLock {
            var state = health[worker, default: Health()]
            state.inFlight = max(0, state.inFlight - 1)
            let bound = session.flatMap { bindings[$0] }.map { $0.worker == worker } ?? false
            switch outcome {
            case .cancelled:
                break
            case .success:
                if state.openUntil != nil || state.failures >= policy.workerFailureThreshold {
                    events.append("账号 #\(worker) 恢复正常，熔断解除")
                }
                state.failures = 0
                state.openUntil = nil
                state.openReason = ""
                state.authFailures = 0
                state.lastAuthFailure = nil
                if bound, let session { bindings[session]?.failures = 0; bindings[session]?.lastFailure = nil }
            case .unreachable:
                state.openUntil = now.addingTimeInterval(policy.unreachableCooldown)
                state.openReason = "unreachable"
                events.append("账号 #\(worker) 的进程不可达，暂停分配 \(Int(policy.unreachableCooldown)) 秒")
            case .failure(let status, let retryAfter):
                var kind = Self.classify(status: status)
                if kind == .auth {
                    if let last = state.lastAuthFailure, now.timeIntervalSince(last) > policy.failureWindow { state.authFailures = 0 }
                    state.authFailures += 1
                    state.lastAuthFailure = now
                    if state.authFailures >= 2 { kind = .hard }
                }
                switch kind {
                case .none, .client:
                    break
                case .throttled:
                    // A rate limit: rest briefly, keep every conversation's home and its prompt cache.
                    let rest = min(policy.throttleCap, max(1, retryAfter ?? policy.throttleDefault))
                    let until = now.addingTimeInterval(rest)
                    if state.openUntil.map({ $0 < until }) ?? true {
                        state.openUntil = until
                        state.openReason = "throttled"
                    }
                    events.append("账号 #\(worker) 被上游限流（429），暂停分配 \(Int(rest.rounded(.up))) 秒；会话保持原账号")
                case .auth:
                    state.openUntil = now.addingTimeInterval(policy.authConfirmCooldown)
                    state.openReason = "auth"
                    events.append("账号 #\(worker) 返回 \(status)，暂停 \(Int(policy.authConfirmCooldown)) 秒待确认；会话保持原账号")
                case .hard:
                    state.failures += 1
                    state.openUntil = now.addingTimeInterval(policy.hardCooldown)
                    state.openReason = status == 402 ? "quota" : "auth"
                    let cause = status == 402 ? "额度已用尽" : "连续两次认证失败"
                    events.append("账号 #\(worker) 返回 \(status)（\(cause)），熔断 \(Int(policy.hardCooldown / 60)) 分钟")
                    if bound, let session {
                        bindings[session] = nil
                        evictedFrom[session] = worker
                        events.append("会话 \(session) 解除与账号 #\(worker) 的绑定")
                    }
                case .soft:
                    state.failures += 1
                    if state.failures >= policy.workerFailureThreshold, !(state.openUntil.map { $0 > now } ?? false) {
                        state.openUntil = now.addingTimeInterval(policy.cooldown)
                        state.openReason = "failures"
                        events.append("账号 #\(worker) 连续失败 \(state.failures) 次（最近 \(status)），熔断 \(Int(policy.cooldown / 60)) 分钟")
                    }
                    if bound, let session, var binding = bindings[session] {
                        if let last = binding.lastFailure, now.timeIntervalSince(last) > policy.failureWindow { binding.failures = 0 }
                        binding.failures += 1
                        binding.lastFailure = now
                        if binding.failures >= policy.sessionFailureThreshold {
                            bindings[session] = nil
                            evictedFrom[session] = worker
                            events.append("会话 \(session) 在账号 #\(worker) 连续失败 \(binding.failures) 次，下一轮改派其他账号")
                        } else {
                            bindings[session] = binding
                        }
                    }
                }
            }
            health[worker] = state
        }
        emit(events)
        onStateChange?()
    }

    /// The account a conversation is bound to, if any.
    func account(of session: String) -> String? { lock.withLock { bindings[session]?.worker } }

    func snapshot() -> Snapshot {
        let now = clock()
        return lock.withLock { () -> Snapshot in
            var sessions: [Snapshot.Session] = []
            for (key, value) in bindings {
                let idle = Int(now.timeIntervalSince(value.lastUsed))
                sessions.append(Snapshot.Session(id: key, account: value.worker, idleSeconds: idle, failures: value.failures))
            }
            sessions.sort { (a: Snapshot.Session, b: Snapshot.Session) -> Bool in
                a.account == b.account ? a.idleSeconds < b.idleSeconds : a.account < b.account
            }
            var ids = Set<String>(health.keys)
            for value in bindings.values { ids.insert(value.worker) }
            var accounts: [Snapshot.Account] = []
            for id in ids.sorted() {
                let state = health[id] ?? Health()
                var active = 0
                for value in bindings.values where value.worker == id && now.timeIntervalSince(value.lastUsed) < policy.activeWindow {
                    active += 1
                }
                let rest = state.openUntil.map { max(0, $0.timeIntervalSince(now)) } ?? 0
                accounts.append(Snapshot.Account(id: id, inFlight: state.inFlight, sessions: active,
                                                 consecutiveFailures: state.failures, circuitOpen: rest > 0,
                                                 restSeconds: Int(rest.rounded(.up)), restReason: rest > 0 ? state.openReason : ""))
            }
            return Snapshot(sessions: sessions, accounts: accounts)
        }
    }

    /// When every candidate is resting: seconds until the first one takes work again (at least 1).
    /// nil while any candidate is available, so a client is never told to wait for nothing.
    func retryAfter(candidates: [KiroWorkerRoute]) -> Int? {
        let now = clock()
        return lock.withLock { () -> Int? in
            var soonest: TimeInterval?
            for worker in candidates {
                guard let until = health[worker.id]?.openUntil, until > now else { return nil }
                let wait = until.timeIntervalSince(now)
                soonest = min(soonest ?? wait, wait)
            }
            return soonest.map { max(1, Int($0.rounded(.up))) }
        }
    }

    /// Ends an account's rest at once (the user chose "立即解除冷却"); its failure counts start over.
    func clearRest(_ worker: String) {
        let ended: Bool = lock.withLock {
            guard var state = health[worker], state.openUntil != nil else { return false }
            state.openUntil = nil; state.openReason = ""; state.failures = 0
            state.authFailures = 0; state.lastAuthFailure = nil
            health[worker] = state
            return true
        }
        if ended { emit(["账号 #\(worker) 的冷却已手动解除"]) ; onStateChange?() }
    }

    private func isOpen(_ worker: String, _ now: Date) -> Bool {
        health[worker]?.openUntil.map { $0 > now } ?? false
    }

    /// Fewest active conversations first, then fewest requests in flight; ties rotate. A temporary
    /// placement (a retry, a standby turn, a request without a conversation) binds nothing, so it
    /// weighs requests in flight first: a burst of failovers then spreads over the accounts.
    private func leastLoaded(_ workers: [KiroWorkerRoute], now: Date, temporary: Bool = false) -> KiroWorkerRoute {
        var sessions: [String: Int] = [:]
        for binding in bindings.values where now.timeIntervalSince(binding.lastUsed) < policy.activeWindow {
            sessions[binding.worker, default: 0] += 1
        }
        rotation &+= 1
        let offset = rotation % workers.count
        let ordered = Array(workers[offset...] + workers[..<offset])
        return ordered.min { a, b in
            let load = (sessions[a.id] ?? 0, sessions[b.id] ?? 0)
            let flight = (health[a.id]?.inFlight ?? 0, health[b.id]?.inFlight ?? 0)
            let (first, second) = temporary ? (flight, load) : (load, flight)
            if first.0 != first.1 { return first.0 < first.1 }
            return second.0 < second.1
        }!
    }

    private func prune(_ now: Date) {
        bindings = bindings.filter { now.timeIntervalSince($0.value.lastUsed) < policy.affinityTTL }
        if evictedFrom.count > 1024 { evictedFrom.removeAll() }
    }

    private func emit(_ events: [String]) {
        guard let onEvent else { return }
        for event in events { onEvent(event) }
    }
}
