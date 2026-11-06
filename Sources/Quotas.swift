import Foundation
import CryptoKit
import CoreFoundation

struct QuotaMetric: Identifiable {
    let id: String
    let title: String
    var used: Decimal?
    var limit: Decimal?
    var remaining: Decimal?
    var unit = "额度"
    var percentage: Double?
    var reset: Date?
    var resetLabel = "重置 / 到期"
    var note = ""
    var unlimited = false

    var usedPercentage: Double? {
        if let percentage { return percentage }
        guard let used, let limit, limit > 0 else { return nil }
        return NSDecimalNumber(decimal: used / limit * 100).doubleValue
    }
    var remainingAmount: Decimal? {
        if unlimited { return nil }
        if let remaining { return remaining }
        guard let limit, let used else { return nil }
        return max(0, limit - used)
    }
}

struct QuotaDetail: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

struct QuotaSnapshot {
    var plan: String?
    var metrics: [QuotaMetric] = []
    var details: [QuotaDetail] = []
    var source = ""
    var fetchedAt = Date()
    var notes: [String] = []
}

struct QuotaState {
    var fingerprint = ""
    var snapshot: QuotaSnapshot?
    var loading = false
    var error: String?
    var attemptedAt: Date?
}

struct QuotaTarget: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let group: String
    let account: Account?
    let channel: Channel?
    let fingerprint: String
    let queryAvailable: Bool
    let queryHint: String

    init(account: Account) {
        id = "account:" + account.name
        title = account.email
        group = account.providerTitle + " 订阅"
        subtitle = account.note.isEmpty ? "订阅账号" : account.note
        self.account = account
        channel = nil
        fingerprint = Self.hash([account.name, account.authIndex, account.email, account.provider, account.accountID, String(account.disabled)])
        let provider = Self.normalizedProvider(account)
        queryAvailable = !account.runtimeOnly && Self.quotaProviders.contains(provider)
        if account.runtimeOnly {
            queryHint = "这是运行时临时凭据，没有可读取的账户区域信息。"
        } else if !Self.quotaProviders.contains(provider) {
            queryHint = "该订阅服务暂未提供统一额度接口，请在服务商账户页查看。"
        } else {
            queryHint = ""
        }
    }

    init(channel: Channel) {
        id = "channel:" + channel.id
        title = channel.name
        group = "API 渠道"
        subtitle = channel.prefix + " · API 渠道"
        account = nil
        self.channel = channel
        fingerprint = Self.hash([channel.id, channel.baseURL, channel.apiKey, channel.balanceMode.rawValue, channel.balancePath, channel.proxyURL, String(channel.enabled), channel.credentialSource, channel.desktopAccountHash])
        queryAvailable = channel.effectiveBalanceMode != .unavailable
        queryHint = queryAvailable ? "" : "此渠道未配置可识别的余额接口；在渠道设置中选择查询类型，或填写自定义余额路径。"
    }

    private static func hash(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let quotaProviders: Set<String> = ["claude", "codex", "kimi", "kimi-ai", "kiro", "xai", "zcode"]

    private static func normalizedProvider(_ account: Account) -> String {
        switch account.provider.lowercased() {
        case "anthropic": return "claude"
        case "gpt", "chatgpt": return "codex"
        case "grok": return "xai"
        case "zcode-bigmodel", "zcode-zai", "zai": return "zcode"
        default: return account.provider.lowercased()
        }
    }
}

enum QuotaParser {
    /// Empty metric rows made the balance page look like a list of failed
    /// queries. Keep pending explanatory rows, but hide entries with no value,
    /// reset date or note.
    static func displayable(_ metric: QuotaMetric) -> Bool {
        metric.used != nil || metric.limit != nil || metric.remaining != nil || metric.usedPercentage != nil
            || metric.unlimited || metric.reset != nil || !metric.note.isEmpty
    }

    static func displayMetrics(_ snapshot: QuotaSnapshot) -> [QuotaMetric] {
        snapshot.metrics.filter(displayable)
    }

    static func zcode(_ data: [String: Any]) -> QuotaSnapshot {
        let subscription = data["subscription"] as? [String: Any] ?? [:]
        let tier = string(subscription["tierName"] ?? subscription["tier_name"])
        let tierNames = ["Coding Plan": "编程套餐", "Gift": "赠送套餐"]
        var result = QuotaSnapshot(plan: string(subscription["plan"]) ?? tier.map { tierNames[$0] ?? $0 }, source: "ZCode 订阅额度接口")
        if let tier { result.details.append(QuotaDetail(label: "套餐类型", value: tierNames[tier] ?? tier)) }
        for (groupIndex, group) in (data["groups"] as? [[String: Any]] ?? []).enumerated() {
            let name = string(group["displayName"] ?? group["display_name"]) ?? "套餐"
            let gift = name == "Gift plans"
            let groupNames = ["GLM Coding Plan": "GLM 编程套餐", "Gift plans": "赠送套餐"]
            let windowNames = ["5h": "5 小时额度", "Weekly": "周额度", "MCP": "MCP 工具调用额度"]
            for (index, bucket) in (group["buckets"] as? [[String: Any]] ?? []).enumerated() {
                let window = string(bucket["window"]) ?? "额度 \(index + 1)"
                let description = (string(bucket["description"]) ?? "")
                    .replacingOccurrences(of: "Models: ", with: "适用模型：")
                    .replacingOccurrences(of: "MCP usage; not a model limit", with: "MCP 工具用量，不计入模型额度")
                let pending = gift && description.contains("未开始")
                let ratio = percent(bucket["remainingFraction"] ?? bucket["remaining_fraction"])
                let percentage: Double?
                if !pending, let ratio, ratio <= 1 { percentage = (1 - ratio) * 100 }
                else { percentage = nil }
                var row = QuotaMetric(id: "zcode-\(groupIndex)-\(index)",
                                      title: (groupNames[name] ?? name) + " · " + (windowNames[window] ?? window),
                                      percentage: percentage, reset: reset(bucket),
                                      resetLabel: gift ? "到期" : "重置 / 到期")
                row.note = pending ? "尚未开始，开始前不可用。" + description : description
                result.metrics.append(row)
            }
        }
        let summaryNames = ["five_hour_resets": "5 小时重置卡", "weekly_resets": "周重置卡", "pending_claims": "待领取套餐"]
        for item in data["summary"] as? [[String: Any]] ?? [] {
            guard let key = string(item["key"]), let value = number(item["value"]), value >= 0 else { continue }
            if key == "gift_tokens_remaining" {
                result.metrics.append(QuotaMetric(id: "zcode-gift-tokens", title: "赠送 Token 余额", remaining: value, unit: "tokens"))
            } else if let name = summaryNames[key] {
                result.details.append(QuotaDetail(label: name, value: amount(value)))
            }
        }
        return result
    }

    static func kimiWork(_ data: [String: Any]) -> QuotaSnapshot {
        var result = QuotaSnapshot(source: "Kimi Work 会员共享额度")
        if let balance = data["subscriptionBalance"] as? [String: Any],
           let ratio = percent(balance["amountUsedRatio"]), ratio <= 1 {
            result.metrics = [QuotaMetric(id: "kimi-work-shared", title: "会员月度共享额度", percentage: ratio * 100)]
        }
        result.notes = ["Work 与其他会员功能共享月度额度；Code 的 5 小时和周限额不在此处混算。"]
        return result
    }

    static func number(_ value: Any?) -> Decimal? {
        guard let value, !(value is NSNull), CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        let text: String
        if let string = value as? String { text = string }
        else if let number = value as? NSNumber { text = number.stringValue }
        else { return nil }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.range(of: "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$", options: .regularExpression) != nil,
              let decimal = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), !decimal.isNaN else { return nil }
        return decimal
    }

    static func percent(_ value: Any?) -> Double? {
        guard let decimal = number(value) else { return nil }
        let number = NSDecimalNumber(decimal: decimal).doubleValue
        return number.isFinite && number >= 0 ? number : nil
    }

    static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return String(value.prefix(200))
    }

    static func date(_ value: Any?) -> Date? {
        if let number = number(value) {
            let seconds = NSDecimalNumber(decimal: number).doubleValue
            guard seconds.isFinite, seconds > 0, seconds < 253402300800000 else { return nil }
            return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds)
        }
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func amount(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? NSDecimalNumber(decimal: value).stringValue
    }

    static func reset(_ data: [String: Any]) -> Date? {
        for key in ["resets_at", "resetAt", "reset_at", "resetTime", "reset_time", "nextResetTime"] {
            if let date = date(data[key]) { return date }
        }
        for key in ["reset_after_seconds", "resetAfterSeconds", "resetIn", "reset_in"] {
            if let seconds = percent(data[key]) { return Date().addingTimeInterval(seconds) }
        }
        return nil
    }

    static func claude(_ data: [String: Any]) -> QuotaSnapshot {
        var snapshot = QuotaSnapshot(source: "Claude OAuth 用量接口")
        let names = ["five_hour": "5 小时额度", "seven_day": "7 天额度", "seven_day_opus": "Opus · 7 天",
                     "seven_day_sonnet": "Sonnet · 7 天", "seven_day_oauth_apps": "OAuth 应用 · 7 天", "seven_day_cowork": "Cowork · 7 天"]
        for key in data.keys.sorted() {
            guard let row = data[key] as? [String: Any], key != "extra_usage" else { continue }
            let percentage = percent(row["utilization"])
            let limit = number(row["limit_dollars"])
            let used = number(row["used_dollars"])
            let remaining = number(row["remaining_dollars"])
            guard percentage != nil || limit != nil || used != nil || remaining != nil else { continue }
            snapshot.metrics.append(QuotaMetric(id: key, title: names[key] ?? key, used: used, limit: limit,
                                                remaining: remaining, unit: limit != nil || used != nil || remaining != nil ? "USD" : "额度",
                                                percentage: percentage, reset: reset(row)))
        }
        if let rows = data["limits"] as? [[String: Any]] {
            // `limits` restates the windows above under new kind names; only keep entries with no counterpart.
            let aliases = ["session": "five_hour", "weekly_all": "seven_day", "weekly_opus": "seven_day_opus",
                           "weekly_sonnet": "seven_day_sonnet", "weekly_oauth_apps": "seven_day_oauth_apps", "weekly_cowork": "seven_day_cowork"]
            let kindNames = ["session": "5 小时额度", "weekly_all": "7 天额度", "weekly": "7 天额度"]
            for (index, row) in rows.enumerated() {
                let kind = string(row["kind"])
                let percentage = percent(row["percent"] ?? row["utilization"])
                let resetDate = reset(row)
                if let kind, let alias = aliases[kind], snapshot.metrics.contains(where: { $0.id == alias }) { continue }
                if snapshot.metrics.contains(where: { metric in
                    metric.usedPercentage == percentage && percentage != nil
                        && abs((metric.reset?.timeIntervalSince1970 ?? 0) - (resetDate?.timeIntervalSince1970 ?? 0)) < 120
                }) { continue }
                let model = string(((row["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"])
                let base = kind.flatMap { kindNames[$0] ?? aliases[$0].flatMap { names[$0] } }
                let parts = [model, base].compactMap { $0 }
                let title = parts.isEmpty ? "其他额度 \(index + 1)" : parts.joined(separator: " · ")
                snapshot.metrics.append(QuotaMetric(id: "limit-\(index)", title: title, percentage: percentage, reset: resetDate))
            }
        }
        if let extra = data["extra_usage"] as? [String: Any] {
            snapshot.details.append(QuotaDetail(label: "额外用量", value: (extra["is_enabled"] as? Bool).map { $0 ? "已启用" : "未启用" } ?? "未提供状态"))
            snapshot.metrics.append(QuotaMetric(id: "extra", title: "额外用量预算", used: number(extra["used_credits"]).map { $0 / 100 }, limit: number(extra["monthly_limit"]).map { $0 / 100 }, unit: string(extra["currency"]) ?? "USD", percentage: percent(extra["utilization"])))
            if let reason = string(extra["disabled_reason"]) { snapshot.notes.append(reason) }
        }
        return snapshot
    }

    static func codex(_ data: [String: Any]) -> QuotaSnapshot {
        var result = QuotaSnapshot(plan: string(data["plan_type"] ?? data["planType"]), source: "Codex 账户用量接口")
        var groups: [(String, [String: Any])] = []
        for (key, title) in [("rate_limit", "模型调用"), ("code_review_rate_limit", "代码审查")] {
            if let group = data[key] as? [String: Any] { groups.append((title, group)) }
        }
        for (index, row) in (data["additional_rate_limits"] as? [[String: Any]] ?? []).enumerated() {
            if let group = row["rate_limit"] as? [String: Any] {
                groups.append((string(row["limit_name"] ?? row["metered_feature"]) ?? "额外额度 \(index + 1)", group))
            }
        }
        for (index, group) in groups.enumerated() {
            for key in ["primary_window", "secondary_window"] {
                guard let window = group.1[key] as? [String: Any] else { continue }
                var title = group.0 + " · " + (key == "primary_window" ? "主窗口" : "次窗口")
                if let seconds = percent(window["limit_window_seconds"]) {
                    title = group.0 + " · " + duration(seconds)
                }
                var row = QuotaMetric(id: "\(index)-\(key)", title: title, percentage: percent(window["used_percent"]), reset: reset(window))
                if group.1["allowed"] as? Bool == false || group.1["limit_reached"] as? Bool == true { row.note = "当前已限额" }
                result.metrics.append(row)
            }
        }
        if let credits = data["credits"] as? [String: Any] {
            result.metrics.append(QuotaMetric(id: "credits", title: "账户 Credits", remaining: number(credits["balance"]), unit: "credits", unlimited: credits["unlimited"] as? Bool ?? false))
        }
        return result
    }

    static func kimi(_ data: [String: Any]) -> QuotaSnapshot {
        var result = QuotaSnapshot(source: "Kimi Code 账户额度接口")
        // New Kimi Code plans report quota windows as ratios rather than
        // request counts.  Keep these as percentage-only metrics so a value
        // such as 0.25 is rendered as 25%, not as 0.25 units of quota.
        let payload: [String: Any]
        if let envelope = data["data"] as? [String: Any], let quota = envelope["quota"] as? [String: Any] {
            payload = quota
        } else {
            payload = data
        }
        let usages = payload["usages"] as? [String: Any] ?? [:]
        let ratioWindows: [(key: String, aliases: [String], title: String)] = [
            ("limit_5h", ["limit_5h", "limit5h"], "5 小时额度"),
            ("limit_7d", ["limit_7d", "limit7d"], "周额度"),
            ("limit_month_total", ["limit_month_total", "monthTotal"], "月度额度")
        ]
        var ratioKeys = Set<String>()
        var ratioMetrics: [QuotaMetric] = []
        for window in ratioWindows {
            guard let row = window.aliases.lazy.compactMap({ usages[$0] as? [String: Any] }).first,
                  let ratio = percent(row["used_ratio"] ?? row["usedRatio"]), ratio <= 1 else { continue }
            let metric = QuotaMetric(id: "kimi-\(window.key)", title: window.title,
                                     percentage: ratio * 100, reset: reset(row))
            if displayable(metric) {
                ratioMetrics.append(metric)
                ratioKeys.insert(window.key)
            }
        }

        // Older accounts expose counts in `usage` and `limits`; retain that
        // fallback for windows the server did not provide as a percentage.
        var items = payload["limits"] as? [[String: Any]] ?? []
        if let usage = payload["usage"] as? [String: Any] { items.append(["detail": usage, "name": "订阅额度"]) }
        for (index, item) in items.enumerated() {
            let detail = item["detail"] as? [String: Any] ?? item
            let window = item["window"] as? [String: Any] ?? [:]
            let unit = string(window["timeUnit"])?.uppercased().replacingOccurrences(of: "TIME_UNIT_", with: "")
            let length = number(window["duration"]).map { NSDecimalNumber(decimal: $0).doubleValue }
            let legacyKey: String?
            if item["name"] as? String == "订阅额度" {
                legacyKey = "limit_7d"
            } else if let length, let unit {
                let minutes = unit == "MINUTE" ? length : unit == "HOUR" ? length * 60 : unit == "DAY" ? length * 1440 : unit == "WEEK" ? length * 10080 : -1
                legacyKey = abs(minutes - 300) < 0.1 ? "limit_5h" : nil
            } else {
                legacyKey = nil
            }
            if let legacyKey, ratioKeys.contains(legacyKey) { continue }
            var title = string(item["name"] ?? item["title"] ?? detail["name"]) ?? "额度窗口 \(index + 1)"
            if let length = number(window["duration"]), let unit = string(window["timeUnit"]) {
                let names = ["MINUTE": "分钟", "HOUR": "小时", "DAY": "天", "WEEK": "周", "MONTH": "月"]
                let key = unit.uppercased().replacingOccurrences(of: "TIME_UNIT_", with: "")
                title += " · \(amount(length)) \(names[key] ?? unit)"
            }
            let limit = number(detail["limit"])
            let remaining = number(detail["remaining"])
            var used = number(detail["used"])
            if used == nil, let limit, let remaining { used = max(0, limit - remaining) }
            let metric = QuotaMetric(id: "kimi-\(index)", title: title, used: used, limit: limit, remaining: remaining, reset: reset(detail) ?? reset(item))
            if displayable(metric) { result.metrics.append(metric) }
        }
        result.metrics.append(contentsOf: ratioMetrics)
        return result
    }

    static func xai(_ data: [String: Any], label: String) -> QuotaSnapshot {
        var result = QuotaSnapshot(source: "Grok 订阅账单接口")
        guard let config = data["config"] as? [String: Any] else { return result }
        let period = config["currentPeriod"] as? [String: Any] ?? config["current_period"] as? [String: Any] ?? [:]
        let end = date(period["end"] ?? config["billingPeriodEnd"] ?? config["billing_period_end"])
        if let percentage = percent(config["creditUsagePercent"] ?? config["credit_usage_percent"]) {
            result.metrics.append(QuotaMetric(id: label, title: label, percentage: percentage, reset: end))
        }
        func cents(_ value: Any?) -> Decimal? {
            number((value as? [String: Any])?["val"] ?? value).map { $0 / 100 }
        }
        let limit = cents(config["monthlyLimit"] ?? config["monthly_limit"])
        let used = cents(config["used"])
        if limit != nil || used != nil {
            let metric = QuotaMetric(id: label + "-monthly", title: "月度订阅预算", used: used, limit: limit, unit: "USD", reset: date(config["billingPeriodEnd"] ?? config["billing_period_end"]))
            if displayable(metric) { result.metrics.append(metric) }
        }
        if let balance = cents(config["prepaidBalance"] ?? config["prepaid_balance"]) {
            let metric = QuotaMetric(id: label + "-balance", title: "预付余额", remaining: balance, unit: "USD")
            if displayable(metric) { result.metrics.append(metric) }
        }
        let overage = cents(config["onDemandUsed"] ?? config["on_demand_used"])
        let cap = cents(config["onDemandCap"] ?? config["on_demand_cap"])
        if overage != nil || cap != nil { result.metrics.append(QuotaMetric(id: label + "-overage", title: "按量用量预算", used: overage, limit: cap, unit: "USD")) }
        for (index, item) in (config["productUsage"] as? [[String: Any]] ?? []).enumerated() {
            let usage = percent(item["usagePercent"] ?? item["usage_percent"])
            let metric = QuotaMetric(id: label + "-product-\(index)", title: string(item["product"]) ?? "产品 \(index + 1)", percentage: usage, reset: usage == nil ? nil : end)
            if displayable(metric) { result.metrics.append(metric) }
        }
        return result
    }

    static func kiro(_ data: [String: Any]) -> QuotaSnapshot {
        let subscription = data["subscriptionInfo"] as? [String: Any] ?? [:]
        var result = QuotaSnapshot(plan: string(subscription["subscriptionTitle"] ?? subscription["subscriptionType"]), source: "Kiro getUsageLimits")
        let resetDate = date(data["nextDateReset"])
        for (index, item) in (data["usageBreakdownList"] as? [[String: Any]] ?? []).enumerated() {
            let title = string(item["displayName"] ?? item["resourceType"]) ?? "资源 \(index + 1)"
            func metric(_ row: [String: Any], id: String, title: String, reset: Date?) -> QuotaMetric {
                QuotaMetric(id: id, title: title, used: number(row["currentUsageWithPrecision"] ?? row["currentUsage"]), limit: number(row["usageLimitWithPrecision"] ?? row["usageLimit"]), unit: string(item["unit"]) ?? "credits", reset: reset)
            }
            let main = metric(item, id: "kiro-\(index)", title: title, reset: resetDate)
            if displayable(main) { result.metrics.append(main) }
            if let trial = item["freeTrialInfo"] as? [String: Any] {
                var row = metric(trial, id: "trial-\(index)", title: title + " · 试用额度", reset: date(trial["freeTrialExpiry"]))
                row.note = string(trial["freeTrialStatus"]) ?? ""
                if displayable(row) { result.metrics.append(row) }
            }
            for (bonusIndex, bonus) in (item["bonuses"] as? [[String: Any]] ?? []).enumerated() {
                var row = metric(bonus, id: "bonus-\(index)-\(bonusIndex)", title: string(bonus["displayName"]) ?? "奖励额度", reset: date(bonus["expiresAt"]))
                row.note = string(bonus["status"]) ?? ""
                if displayable(row) { result.metrics.append(row) }
            }
        }
        return result
    }

    static func balance(_ data: [String: Any], mode: BalanceMode, currency: String = "") -> QuotaSnapshot {
        var result = QuotaSnapshot(source: mode.title)
        let body = data["data"] as? [String: Any] ?? data
        switch mode {
        case .deepseek:
            for (index, item) in (data["balance_infos"] as? [[String: Any]] ?? []).enumerated() {
                let unit = string(item["currency"]) ?? "币种未提供"
                for (key, title) in [("total_balance", "可用余额"), ("topped_up_balance", "充值余额"), ("granted_balance", "赠金余额")] {
                    result.metrics.append(QuotaMetric(id: "\(index)-\(key)", title: title, remaining: number(item[key]), unit: unit))
                }
            }
            if let available = data["is_available"] as? Bool { result.details.append(QuotaDetail(label: "账户可用", value: available ? "是" : "否")) }
        case .moonshot:
            for (key, title) in [("available_balance", "可用余额"), ("cash_balance", "现金余额"), ("voucher_balance", "代金券余额")] {
                if let amount = number(body[key]) { result.metrics.append(QuotaMetric(id: key, title: title, remaining: amount, unit: currency)) }
            }
        case .newAPI:
            let token = QuotaMetric(id: "token", title: "此令牌额度", used: number(body["total_used"]), limit: number(body["total_granted"]), remaining: number(body["total_available"]), unit: "站内额度", unlimited: body["unlimited_quota"] as? Bool ?? false)
            if displayable(token) { result.metrics.append(token) }
            if let user = body["user_quota"] as? [String: Any] {
                let account = QuotaMetric(id: "user", title: "账户总额度", used: number(user["total_used"]), remaining: number(user["total_available"]), unit: "站内额度")
                if displayable(account) { result.metrics.append(account) }
            } else { result.notes.append("接口仅提供当前令牌额度，账户总余额需服务商允许查询。站内额度按原值展示。") }
            if let expiry = date(body["expires_at"]) { result.details.append(QuotaDetail(label: "令牌到期", value: expiry.formatted(date: .abbreviated, time: .shortened))) }
        case .zhipu:
            result.plan = string(body["level"])
            for (index, row) in (body["limits"] as? [[String: Any]] ?? []).enumerated() {
                let type = string(row["type"]) ?? "额度"
                var title = type == "TIME_LIMIT" ? "工具调用额度" : type == "CREDIT_LIMIT" ? "套餐积分" : "模型额度"
                if let count = number(row["number"]), let unit = percent(row["unit"]) {
                    let units: [Double: String] = [3: "小时", 6: "周"]
                    title += " · \(amount(count)) \(units[unit] ?? "周期")"
                } else { title += " \(index + 1)" }
                let metric = QuotaMetric(id: "limit-\(index)", title: title, used: number(row["currentValue"]), limit: number(row["usage"]), remaining: number(row["remaining"]), unit: type == "TIME_LIMIT" ? "次" : type == "CREDIT_LIMIT" ? "积分" : "额度", percentage: percent(row["percentage"]), reset: reset(row))
                if displayable(metric) { result.metrics.append(metric) }
                for (detailIndex, detail) in (row["usageDetails"] as? [[String: Any]] ?? []).enumerated() {
                    let metric = QuotaMetric(id: "detail-\(index)-\(detailIndex)", title: string(detail["modelCode"] ?? detail["name"]) ?? "工具明细", used: number(detail["usage"] ?? detail["currentValue"]), unit: "次")
                    if displayable(metric) { result.metrics.append(metric) }
                }
            }
        case .sub2api:
            let unit = string(data["unit"]) ?? "USD"
            result.plan = string(data["planName"])
            if let quota = data["quota"] as? [String: Any] {
                result.metrics.append(QuotaMetric(id: "key-quota", title: "此令牌总额度", used: number(quota["used"]), limit: number(quota["limit"]),
                                                  remaining: number(quota["remaining"]), unit: string(quota["unit"]) ?? unit))
            }
            for (index, row) in (data["rate_limits"] as? [[String: Any]] ?? []).enumerated() {
                let windows = ["5h": "5 小时限额", "1d": "每日限额", "7d": "7 天限额"]
                let window = string(row["window"]) ?? ""
                result.metrics.append(QuotaMetric(id: "rate-\(index)", title: windows[window] ?? "周期限额 \(window)", used: number(row["used"]), limit: number(row["limit"]),
                                                  remaining: number(row["remaining"]), unit: unit, reset: reset(row)))
            }
            if let plan = data["subscription"] as? [String: Any] {
                for (key, title) in [("daily", "订阅 · 每日"), ("weekly", "订阅 · 每周"), ("monthly", "订阅 · 每月")] {
                    let used = number(plan[key + "_usage_usd"]), limit = number(plan[key + "_limit_usd"])
                    guard limit != nil else { continue }
                    result.metrics.append(QuotaMetric(id: "plan-" + key, title: title, used: used, limit: limit, unit: "USD"))
                }
                if let expiry = date(plan["expires_at"]) { result.details.append(QuotaDetail(label: "订阅到期", value: expiry.formatted(date: .abbreviated, time: .shortened))) }
            }
            if result.metrics.isEmpty, let remaining = number(data["remaining"] ?? data["balance"]) {
                result.metrics.append(QuotaMetric(id: "wallet", title: result.plan ?? "可用余额", remaining: remaining, unit: unit))
            }
            if let expiry = date(data["expires_at"]) { result.details.append(QuotaDetail(label: "令牌到期", value: expiry.formatted(date: .abbreviated, time: .shortened))) }
            if let today = (data["usage"] as? [String: Any])?["today"] as? [String: Any], let cost = number(today["actual_cost"] ?? today["cost"]) {
                result.details.append(QuotaDetail(label: "今日消费", value: amount(cost) + " " + unit))
            }
            if data["isValid"] as? Bool == false { result.notes.append("中转站报告此令牌不可用（\(string(data["status"]) ?? "状态未知")），请到中转站后台处理。") }
        case .custom:
            let unit = string(body["currency"] ?? body["unit"]) ?? "接口原始单位"
            let custom = QuotaMetric(id: "custom", title: "接口余额", used: number(body["used"] ?? body["total_used"]), limit: number(body["limit"] ?? body["total_granted"]), remaining: number(body["balance"] ?? body["remaining"] ?? body["total_available"] ?? body["available_balance"]), unit: unit, reset: reset(body))
            if displayable(custom) { result.metrics.append(custom) }
        default: break
        }
        return result
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds > 0, seconds < 1e10 else { return "周期长度未提供" }
        if seconds.truncatingRemainder(dividingBy: 86400) == 0 { return "\(Int(seconds / 86400)) 天" }
        if seconds.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(seconds / 3600)) 小时" }
        return "\(Int(seconds / 60)) 分钟"
    }

    static func hasValues(_ snapshot: QuotaSnapshot) -> Bool {
        snapshot.metrics.contains { $0.used != nil || $0.limit != nil || $0.remaining != nil || $0.percentage != nil || $0.unlimited }
    }
}
