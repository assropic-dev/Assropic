import Foundation

@main struct QuotaTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        count += 1
    }
    static func object(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }
    static func main() throws {
        check(QuotaParser.number("2026-11-02T00:00:00Z") == nil, "Dates must not become numeric prefixes")
        check(QuotaParser.number(true) == nil, "Booleans are not balances")
        check(QuotaParser.number("NaN") == nil, "Non-finite values stay unknown")
        check(QuotaParser.number("10USD") == nil, "Partial numeric strings stay unknown")
        check(QuotaParser.number("-0.123456") == Decimal(string: "-0.123456"), "Preserve decimal balances")
        check(QuotaParser.date("2026-11-02T00:00:00Z") == Date(timeIntervalSince1970: 1793577600), "ISO reset date")
        check(QuotaParser.date(1793577600000 as Int64) == Date(timeIntervalSince1970: 1793577600), "Millisecond reset date")

        let claude = QuotaParser.claude(object(#"{"five_hour":{"utilization":25,"resets_at":"2026-11-02T00:00:00Z"},"seven_day":{"utilization":null},"extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null}}"#))
        check(claude.metrics.first?.usedPercentage == 25, "Claude utilization")
        check(claude.metrics.first?.reset != nil, "Claude reset")
        check(!claude.metrics.contains(where: { $0.id == "seven_day" }), "Null Claude quota must not show full remaining")
        check(claude.details.first?.value == "未启用", "Disabled extra usage")
        let extra = QuotaParser.claude(object(#"{"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1250}}"#)).metrics[0]
        check(extra.limit == 50 && extra.used == Decimal(string: "12.5") && extra.unit == "USD", "Claude extra usage cents to currency")

        let codex = QuotaParser.codex(object(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_at":1793577600},"secondary_window":{"used_percent":null}},"code_review_rate_limit":{"primary_window":{"used_percent":90,"limit_window_seconds":18000}},"credits":{"balance":"12.75","unlimited":false}}"#))
        check(codex.plan == "plus", "Codex plan")
        check(codex.metrics[0].title.contains("7 天"), "Classify by actual duration")
        check(codex.metrics[0].usedPercentage == 0, "Zero is real")
        check(codex.metrics[1].usedPercentage == nil, "Missing is unknown")
        check(codex.metrics[2].title.contains("代码审查"), "Separate code review")
        check(codex.metrics.last?.remaining == Decimal(string: "12.75"), "Codex credits")

        let kimi = QuotaParser.kimi(object(#"{"limits":[{"window":{"duration":5,"timeUnit":"HOUR"},"detail":{"limit":100,"remaining":65,"resetTime":"2026-11-02T00:00:00Z"}}],"usages":{"limit_month_total":{"used_ratio":0.2}}}"#))
        check(kimi.metrics[0].used == 35, "Derive usage only from known limit and remaining")
        check(kimi.metrics[0].reset != nil, "Kimi reset")
        check(kimi.metrics[1].usedPercentage == 20, "Kimi ratio scale")
        check(!QuotaParser.hasValues(QuotaParser.kimi([:])), "Empty Kimi response is unavailable")

        let xai = QuotaParser.xai(object(#"{"config":{"currentPeriod":{"type":"weekly","end":"2026-11-02T00:00:00Z"},"creditUsagePercent":30,"monthlyLimit":{"val":2000},"used":{"val":500},"prepaidBalance":{"val":"1234"}}}"#), label: "周额度")
        check(xai.metrics.first?.usedPercentage == 30, "Grok weekly percentage")
        check(xai.metrics.first(where: { $0.title == "月度订阅预算" })?.limit == 20, "Grok cents to USD")
        check(xai.metrics.last?.remaining == Decimal(string: "12.34"), "Grok prepaid precision")

        let kiro = QuotaParser.kiro(object(#"{"subscriptionInfo":{"subscriptionTitle":"KIRO PRO"},"nextDateReset":1793577600,"usageBreakdownList":[{"displayName":"Credits","currentUsageWithPrecision":12.5,"usageLimitWithPrecision":100,"freeTrialInfo":{"currentUsage":0,"usageLimit":10,"freeTrialStatus":"ACTIVE"},"bonuses":[{"currentUsage":5,"usageLimit":20,"status":"ACTIVE"}]}]}"#))
        check(kiro.plan == "KIRO PRO", "Kiro plan")
        check(kiro.metrics.count == 3, "Separate main, trial, bonus limits")
        check(kiro.metrics[0].remainingAmount == Decimal(string: "87.5"), "Kiro precise remaining")
        check(kiro.metrics[1].used == 0, "Unused trial")

        let work = QuotaParser.kimiWork(object(#"{"subscriptionBalance":{"amountUsedRatio":0.25,"expireTime":"2026-12-01T00:00:00Z"}}"#))
        check(work.metrics.first?.usedPercentage == 25, "Work reads the member shared-pool ratio")
        check(work.metrics.first?.reset == nil, "Work subscription expiry is not a quota reset")
        check(!QuotaParser.hasValues(QuotaParser.kimiWork([:])), "Missing Work quota remains unknown")
        check(!QuotaParser.hasValues(QuotaParser.kimiWork(object(#"{"subscriptionBalance":{"amountUsedRatio":2}}"#))), "Invalid Work ratios do not imply unlimited or zero usage")

        let zcode = QuotaParser.zcode(object(#"{"subscription":{"plan":"GLM Coding Lite","tierName":"Coding Plan"},"groups":[{"displayName":"GLM Coding Plan","buckets":[{"window":"5h","remainingFraction":0.75,"resetTime":"2026-11-02T00:00:00Z"},{"window":"Weekly","remainingFraction":0},{"window":"MCP","remainingFraction":1,"description":"MCP usage; not a model limit"}]},{"displayName":"Gift plans","buckets":[{"window":"Trial · glm-5.3-flash","remainingFraction":1,"resetTime":"2026-12-01T00:00:00Z","description":"Models: glm-5.3-flash"}]}],"summary":[{"key":"gift_tokens_remaining","value":300000000,"unit":"tokens"},{"key":"five_hour_resets","value":0},{"key":"weekly_resets","value":2},{"key":"pending_claims","value":1}]}"#))
        check(zcode.plan == "GLM Coding Lite", "ZCode preserves the actual subscription name")
        check(zcode.details.first?.value == "编程套餐", "ZCode translates the subscription tier")
        check(zcode.metrics[0].title == "GLM 编程套餐 · 5 小时额度" && zcode.metrics[0].usedPercentage == 25,
              "ZCode remaining fractions become used percentages")
        check(zcode.metrics[0].reset == Date(timeIntervalSince1970: 1793577600), "ZCode reads camelCase reset dates")
        check(zcode.metrics[1].title.contains("周额度") && zcode.metrics[1].usedPercentage == 100, "Zero remaining means an exhausted window")
        check(zcode.metrics[2].usedPercentage == 0 && zcode.metrics[2].note == "MCP 工具用量，不计入模型额度",
              "Full remaining and MCP information retain their meanings")
        check(zcode.metrics[3].title == "赠送套餐 · Trial · glm-5.3-flash" && zcode.metrics[3].note == "适用模型：glm-5.3-flash",
              "Gift labels are localized while model and plan identifiers survive")
        check(zcode.metrics[3].resetLabel == "到期", "Gift expiry is not described as quota reset")
        check(zcode.metrics.last?.remaining == 300000000 && zcode.metrics.last?.unit == "tokens", "Gift token balances retain raw units")
        check(zcode.metrics.count == 5 && zcode.details.contains(where: { $0.label == "5 小时重置卡" && $0.value == "0" }),
              "Reset counts are informational details, including actual zero")
        check(zcode.details.contains(where: { $0.label == "周重置卡" && $0.value == "2" })
              && zcode.details.contains(where: { $0.label == "待领取套餐" && $0.value == "1" }), "Other auxiliary counts remain separate")

        let zcodeSnake = QuotaParser.zcode(object(#"{"subscription":{"tier_name":"Gift"},"groups":[{"display_name":"Gift plans","buckets":[{"window":"Gift · glm-5.3","remaining_fraction":0.5,"reset_time":"2026-11-02T00:00:00Z"}]}]}"#))
        check(zcodeSnake.plan == "赠送套餐" && zcodeSnake.metrics.first?.usedPercentage == 50, "ZCode accepts snake_case normalization")
        check(zcodeSnake.metrics.first?.reset == Date(timeIntervalSince1970: 1793577600), "ZCode reads snake_case reset dates")
        for bucket in [[:], ["remainingFraction": NSNull()], ["remainingFraction": true], ["remainingFraction": "NaN"],
                       ["remainingFraction": "0.5x"], ["remainingFraction": -0.1], ["remainingFraction": 1.1]] as [[String: Any]] {
            let unknown = QuotaParser.zcode(["groups": [["displayName": "GLM Coding Plan", "buckets": [bucket]]]])
            check(!QuotaParser.hasValues(unknown) && unknown.metrics.first?.usedPercentage == nil,
                  "Missing, malformed and out-of-range ZCode fractions stay unknown")
        }
        let zcodeAuxiliary = QuotaParser.zcode(object(#"{"subscription":{"plan":"GLM Coding Lite"},"summary":[{"key":"five_hour_resets","value":0},{"key":"weekly_resets","value":2},{"key":"pending_claims","value":1}]}"#))
        check(!QuotaParser.hasValues(zcodeAuxiliary) && zcodeAuxiliary.metrics.isEmpty && zcodeAuxiliary.details.count == 3,
              "Plan metadata and reset counts alone never establish a quota balance")
        let zcodeEmptyGift = QuotaParser.zcode(object(#"{"summary":[{"key":"gift_tokens_remaining","value":0}]}"#))
        check(QuotaParser.hasValues(zcodeEmptyGift) && zcodeEmptyGift.metrics.first?.remaining == 0, "Explicit zero gift tokens are a real balance")
        let zcodePending = QuotaParser.zcode(object(#"{"groups":[{"displayName":"Gift plans","buckets":[{"window":"Future · glm-5.3","remainingFraction":0,"description":"Models: glm-5.3; 未开始"}]}]}"#))
        check(!QuotaParser.hasValues(zcodePending) && zcodePending.metrics.first?.usedPercentage == nil,
              "Pending gift buckets do not masquerade as fully consumed quota")
        check(zcodePending.metrics.first?.note == "尚未开始，开始前不可用。适用模型：glm-5.3; 未开始", "Pending gifts explain their unavailable status in Chinese")

        let deepseek = QuotaParser.balance(object(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"10.20","topped_up_balance":"8","granted_balance":"2.20"},{"currency":"USD","total_balance":"-0.10"}]}"#), mode: .deepseek)
        check(deepseek.metrics.count == 6, "Separate currencies and components")
        check(deepseek.metrics[3].remaining == Decimal(string: "-0.10"), "Display negative actual balance")
        let relay = QuotaParser.balance(object(#"{"data":{"total_granted":1000,"total_used":250,"total_available":750,"unlimited_quota":false,"user_quota":{"total_available":2000,"total_used":500}}}"#), mode: .newAPI)
        check(relay.metrics.count == 2, "Separate token and account quotas")
        check(relay.metrics[0].remaining == 750, "No assumed exchange rate")
        check(relay.metrics[0].unit == "站内额度", "Raw relay units")
        let zhipu = QuotaParser.balance(object(#"{"data":{"level":"max","limits":[{"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":50,"nextResetTime":1793577600000},{"type":"TIME_LIMIT","usage":1000,"currentValue":20,"remaining":980}]}}"#), mode: .zhipu)
        check(zhipu.metrics[0].unit == "积分", "New Zhipu credit plans")
        check(zhipu.metrics[0].title.contains("周"), "Explicit Zhipu period")
        check(zhipu.metrics[1].remainingAmount == 980, "Zhipu tools remaining")
        let creditPlan = QuotaParser.balance(object(#"{"data":{"level":"lite","limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":11,"remaining":1988,"percentage":1,"nextResetTime":1793657657199},{"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,"currentValue":11,"remaining":9988,"percentage":1}]}}"#), mode: .zhipu)
        check(creditPlan.plan == "lite" && creditPlan.metrics.count == 2, "Current ZCode credit plans expose both billing windows")
        check(creditPlan.metrics[0].title == "套餐积分 · 5 小时" && creditPlan.metrics[1].title == "套餐积分 · 1 周",
              "CREDIT_LIMIT windows retain their actual duration")
        check(creditPlan.metrics[0].used == 11 && creditPlan.metrics[0].limit == 2000 && creditPlan.metrics[0].remaining == 1988,
              "Credit-plan reported remaining wins over arithmetic estimates")
        check(creditPlan.metrics[0].usedPercentage == 1 && creditPlan.metrics[0].reset == Date(timeIntervalSince1970: 1793657657.199),
              "Credit plans preserve authoritative percentages and millisecond resets")
        check(!QuotaParser.hasValues(QuotaParser.balance(object(#"{"data":{"level":"lite","limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5}]}}"#), mode: .zhipu)),
              "Credit-plan metadata alone does not invent a balance")

        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port":18417,"channels":[{"name":"old"}]}"#.utf8))
        check(old.channels[0].balanceMode == .auto, "Old channels receive query defaults")
        check(old.lastOpenedAgent == .cursor, "Old settings receive launcher default")
        var saved = old
        saved.lastOpenedAgent = .claude
        saved.lastOpenedProject = "/tmp/project with spaces"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(saved))
        check(decoded.lastOpenedAgent == .claude && decoded.lastOpenedProject == saved.lastOpenedProject, "Remember launcher choice")
        let profile = ConnectionProfile(tool: .codex, baseURL: "http://127.0.0.1:18417", key: "key", model: "model")
        check(profile.launchCommand(executable: "/path with space/codex").hasPrefix("'/path with space/codex' "), "Quote CLI executable path")
        print("PASS \(count) quota parsing, missing-value, compatibility and launcher assertions")
    }
}
