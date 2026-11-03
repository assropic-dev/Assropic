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
    let account: Account?
    let channel: Channel?
    let fingerprint: String

    init(account: Account) {
        id = "account:" + account.name
        title = account.email
        subtitle = account.provider + " · 订阅账号"
        self.account = account
        channel = nil
        fingerprint = Self.hash([account.name, account.authIndex, account.email, account.provider, account.accountID, String(account.disabled)])
    }

    init(channel: Channel) {
        id = "channel:" + channel.id
        title = channel.name
        subtitle = channel.prefix + " · API 渠道"
        account = nil
        self.channel = channel
        fingerprint = Self.hash([channel.id, channel.baseURL, channel.apiKey, channel.balanceMode.rawValue, channel.balancePath, channel.proxyURL, String(channel.enabled), channel.credentialSource, channel.desktopAccountHash])
    }

    private static func hash(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum QuotaParser {
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
            for (index, row) in rows.enumerated() {
                let model = ((row["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"]
                snapshot.metrics.append(QuotaMetric(id: "limit-\(index)", title: string(model) ?? string(row["kind"]) ?? "额度 \(index + 1)", percentage: percent(row["percent"]), reset: reset(row)))
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
        var items = data["limits"] as? [[String: Any]] ?? []
        if let usage = data["usage"] as? [String: Any] { items.append(["detail": usage, "name": "订阅额度"]) }
        for (index, item) in items.enumerated() {
            let detail = item["detail"] as? [String: Any] ?? item
            let window = item["window"] as? [String: Any] ?? [:]
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
            result.metrics.append(QuotaMetric(id: "kimi-\(index)", title: title, used: used, limit: limit, remaining: remaining, reset: reset(detail) ?? reset(item)))
        }
        if let monthly = (data["usages"] as? [String: Any])?["limit_month_total"] as? [String: Any] {
            result.metrics.append(QuotaMetric(id: "monthly", title: "月度额度", percentage: percent(monthly["used_ratio"]).map { $0 * 100 }, reset: reset(monthly)))
        }
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
            result.metrics.append(QuotaMetric(id: label + "-monthly", title: "月度订阅预算", used: used, limit: limit, unit: "USD", reset: date(config["billingPeriodEnd"] ?? config["billing_period_end"])))
        }
        if let balance = cents(config["prepaidBalance"] ?? config["prepaid_balance"]) {
            result.metrics.append(QuotaMetric(id: label + "-balance", title: "预付余额", remaining: balance, unit: "USD"))
        }
        let overage = cents(config["onDemandUsed"] ?? config["on_demand_used"])
        let cap = cents(config["onDemandCap"] ?? config["on_demand_cap"])
        if overage != nil || cap != nil { result.metrics.append(QuotaMetric(id: label + "-overage", title: "按量用量预算", used: overage, limit: cap, unit: "USD")) }
        for (index, item) in (config["productUsage"] as? [[String: Any]] ?? []).enumerated() {
            result.metrics.append(QuotaMetric(id: label + "-product-\(index)", title: string(item["product"]) ?? "产品 \(index + 1)", percentage: percent(item["usagePercent"] ?? item["usage_percent"]), reset: end))
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
            result.metrics.append(metric(item, id: "kiro-\(index)", title: title, reset: resetDate))
            if let trial = item["freeTrialInfo"] as? [String: Any] {
                var row = metric(trial, id: "trial-\(index)", title: title + " · 试用额度", reset: date(trial["freeTrialExpiry"]))
                row.note = string(trial["freeTrialStatus"]) ?? ""
                result.metrics.append(row)
            }
            for (bonusIndex, bonus) in (item["bonuses"] as? [[String: Any]] ?? []).enumerated() {
                var row = metric(bonus, id: "bonus-\(index)-\(bonusIndex)", title: string(bonus["displayName"]) ?? "奖励额度", reset: date(bonus["expiresAt"]))
                row.note = string(bonus["status"]) ?? ""
                result.metrics.append(row)
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
            result.metrics.append(QuotaMetric(id: "token", title: "此令牌额度", used: number(body["total_used"]), limit: number(body["total_granted"]), remaining: number(body["total_available"]), unit: "站内额度", unlimited: body["unlimited_quota"] as? Bool ?? false))
            if let user = body["user_quota"] as? [String: Any] {
                result.metrics.append(QuotaMetric(id: "user", title: "账户总额度", used: number(user["total_used"]), remaining: number(user["total_available"]), unit: "站内额度"))
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
                result.metrics.append(QuotaMetric(id: "limit-\(index)", title: title, used: number(row["currentValue"]), limit: number(row["usage"]), remaining: number(row["remaining"]), unit: type == "TIME_LIMIT" ? "次" : type == "CREDIT_LIMIT" ? "积分" : "额度", percentage: percent(row["percentage"]), reset: reset(row)))
                for (detailIndex, detail) in (row["usageDetails"] as? [[String: Any]] ?? []).enumerated() {
                    result.metrics.append(QuotaMetric(id: "detail-\(index)-\(detailIndex)", title: string(detail["modelCode"] ?? detail["name"]) ?? "工具明细", used: number(detail["usage"] ?? detail["currentValue"]), unit: "次"))
                }
            }
        case .custom:
            let unit = string(body["currency"] ?? body["unit"]) ?? "接口原始单位"
            result.metrics.append(QuotaMetric(id: "custom", title: "接口余额", used: number(body["used"] ?? body["total_used"]), limit: number(body["limit"] ?? body["total_granted"]), remaining: number(body["balance"] ?? body["remaining"] ?? body["total_available"] ?? body["available_balance"]), unit: unit, reset: reset(body)))
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
