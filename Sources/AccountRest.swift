import Foundation

/// Why and until when an account takes no new requests. Shown in the account list with a countdown.
struct AccountRest: Equatable {
    enum Reason: String, Equatable {
        case quota, throttled, transient, auth, failures, unreachable

        var title: String {
            switch self {
            case .quota: return "额度用尽"
            case .throttled: return "上游限流"
            case .transient: return "临时错误"
            case .auth: return "认证待确认"
            case .failures: return "连续失败"
            case .unreachable: return "进程重启中"
            }
        }
    }

    let until: Date
    let reason: Reason
    /// Models resting on their own while the account keeps serving its other models.
    var models: [String] = []
    /// Where the state comes from: "core" (CLIProxyAPI cooldown) or "kiro" (Assropic's Kiro router).
    var source = "core"

    /// "冷却中 · 上游限流 · 约 2 分 5 秒后恢复"; nil once the rest is over.
    func text(now: Date = Date()) -> String? {
        let left = until.timeIntervalSince(now)
        guard left > 0 else { return nil }
        let scope = models.isEmpty ? "冷却中" : "部分模型冷却（" + models.prefix(3).joined(separator: "、") + (models.count > 3 ? " 等" : "") + "）"
        return [scope, reason.title, "约 " + Self.duration(left) + "后恢复"].joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(1, Int(seconds.rounded(.up)))
        if total >= 86400 { return "\(total / 86400) 天 \((total % 86400) / 3600) 小时" }
        if total >= 3600 { return "\(total / 3600) 小时 \((total % 3600) / 60) 分" }
        if total >= 60 { return "\(total / 60) 分 \(total % 60) 秒" }
        return "\(total) 秒"
    }
}

enum AccountRestReader {
    /// One CLIProxyAPI cooldown file (`*.cds`, written with `save-cooldown-status`): the credential it
    /// belongs to and its rest, or nil when nothing in it is still resting at `now`.
    /// A record without `model` rests the whole credential; records with one rest single models.
    static func parseCooldown(_ data: Data, now: Date) -> (authID: String, rest: AccountRest)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authID = object["auth_id"] as? String, !authID.isEmpty else { return nil }
        var whole: AccountRest?
        var modelRests: [(model: String, rest: AccountRest)] = []
        for case let record as [String: Any] in object["records"] as? [Any] ?? [] {
            guard let rest = rest(record, now: now) else { continue }
            if let model = record["model"] as? String, !model.isEmpty {
                modelRests.append((model, rest))
            } else if whole.map({ rest.until > $0.until }) ?? true {
                whole = rest
            }
        }
        if let whole { return (authID, whole) }
        guard let longest = modelRests.max(by: { $0.rest.until < $1.rest.until }) else { return nil }
        var partial = longest.rest
        partial.models = modelRests.map(\.model).sorted()
        return (authID, partial)
    }

    private static func rest(_ record: [String: Any], now: Date) -> AccountRest? {
        var until = date(record["next_retry_after"])
        let quota = record["quota"] as? [String: Any] ?? [:]
        let exceeded = quota["exceeded"] as? Bool ?? false
        if exceeded, let recover = date(quota["next_recover_at"]), recover > (until ?? .distantPast) { until = recover }
        guard let until, until > now else { return nil }
        let status = ((record["last_error"] as? [String: Any])?["http_status"] as? NSNumber)?.intValue ?? 0
        let reason: AccountRest.Reason
        if exceeded || status == 402 { reason = .quota }
        else if status == 429 { reason = .throttled }
        else if status == 401 || status == 403 { reason = .auth }
        else { reason = .transient }
        return AccountRest(until: until, reason: reason)
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty, !text.hasPrefix("0001-") else { return nil }
        return fractional.date(from: text) ?? plain.date(from: text)
    }

    /// Every resting credential in the core's account directory, by auth id.
    static func coreRests(directory: URL, now: Date = Date()) -> [String: AccountRest] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var rests: [String: AccountRest] = [:]
        for name in names where name.hasSuffix(".cds") && !name.hasPrefix(".") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let parsed = parseCooldown(data, now: now) else { continue }
            rests[parsed.authID] = parsed.rest
        }
        return rests
    }

    /// Kiro accounts resting in the gateway's router, by account file name. `slots` maps each account
    /// file to its worker slot, which is the id the router knows the account by.
    static func kiroRests(_ snapshot: KiroSessionRouter.Snapshot, slots: [String: Int], now: Date = Date()) -> [String: AccountRest] {
        var rests: [String: AccountRest] = [:]
        for (name, slot) in slots {
            guard let account = snapshot.accounts.first(where: { $0.id == String(slot) }), account.restSeconds > 0 else { continue }
            let reason = AccountRest.Reason(rawValue: account.restReason) ?? .failures
            rests[name] = AccountRest(until: now.addingTimeInterval(TimeInterval(account.restSeconds)), reason: reason, source: "kiro")
        }
        return rests
    }

    /// The rest shown for one account: the Kiro router's state wins for Kiro accounts, since it is what
    /// places their requests; otherwise the core's state under the account's id or file name.
    static func rest(for account: (id: String, name: String), core: [String: AccountRest], kiro: [String: AccountRest]) -> AccountRest? {
        kiro[account.name] ?? core[account.id] ?? core[account.name]
    }
}
