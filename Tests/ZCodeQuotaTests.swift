import Foundation

@main struct ZCodeQuotaTests {
    static var count = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        count += 1
    }

    static func rejects(_ metadata: [String: Any], _ message: String) {
        do {
            _ = try ZCodeCodingPlanRequest(metadata: metadata)
            preconditionFailure(message)
        } catch {
            count += 1
        }
    }

    static func main() throws {
        let key = "synthetic-coding-plan-key"
        let domestic = try ZCodeCodingPlanRequest(metadata: ["key": key, "site": "bigmodel"])!
        check(domestic.url == "https://open.bigmodel.cn/api/monitor/usage/quota/limit", "Domestic personal quota uses the official monitor origin")
        check(domestic.headers["Authorization"] == key, "Coding Plan authentication passes the key without a Bearer prefix")
        check(domestic.headers["Accept"] == "application/json", "Quota requests accept JSON")
        check(domestic.headers["Bigmodel-Organization"] == nil && domestic.headers["Bigmodel-Project"] == nil, "Personal quota has no team headers")
        check(domestic.proxyURL.isEmpty, "Accounts without a proxy preserve the default transport")

        let international = try ZCodeCodingPlanRequest(metadata: ["key": key, "site": "zai"])!
        check(international.url == "https://api.z.ai/api/monitor/usage/quota/limit", "International personal quota uses the official Z.ai origin")
        for site in ["bigmodel", "zai"] {
            let team = try ZCodeCodingPlanRequest(metadata: ["key": key, "site": site, "org": "fixture-org", "project": "fixture-project"])!
            let root = site == "bigmodel" ? "https://bigmodel.cn" : "https://api.z.ai"
            check(team.url == root + "/api/monitor/usage/quota/limit?type=2", "Team quota selects its official origin and type")
            check(team.headers["Bigmodel-Organization"] == "fixture-org" && team.headers["Bigmodel-Project"] == "fixture-project", "Team identity is preserved in headers")
            check(team.headers["Set-Language"] == "en" && team.headers["Accept-Language"] == "en-US,en", "Team request uses supported language headers")
        }

        let giftOnly = try ZCodeCodingPlanRequest(metadata: ["site": "zai", "jwt": "synthetic-gift-token"])
        let emptyKey = try ZCodeCodingPlanRequest(metadata: ["key": "", "site": "zai"])
        check(giftOnly == nil, "Gift-only credentials skip Coding Plan lookup")
        check(emptyKey == nil, "An empty key skips Coding Plan lookup")
        for invalidKey in [" ", "\t", "key with spaces", "key\nInjected: true", "key\r", "key\u{0}", "key\u{7f}"] {
            rejects(["key": invalidKey, "site": "zai"], "Reject whitespace or controls in the key")
        }
        for invalidSite in ["", "other", "https://api.z.ai", "zai\n", "BIGMODEL"] {
            rejects(["key": key, "site": invalidSite], "Do not derive a monitor URL from an unknown site")
        }
        rejects(["key": 123, "site": "zai"], "Reject a non-string key")
        rejects(["key": key, "site": "zai", "org": "fixture-org"], "Reject an organization without a project")
        rejects(["key": key, "site": "zai", "project": "fixture-project"], "Reject a project without an organization")
        for field in ["org", "project"] {
            for control in ["\n", "\r", "\t", "\u{0}", "\u{7f}"] {
                var metadata: [String: Any] = ["key": key, "site": "zai", "org": "fixture-org", "project": "fixture-project"]
                metadata[field] = "fixture" + control + "injected"
                rejects(metadata, "Reject controls in team headers")
            }
        }
        let fixedOrigin = try ZCodeCodingPlanRequest(metadata: ["key": key, "site": "zai", "base_url": "https://example.invalid", "base-url": "https://other.invalid", "root": "http://127.0.0.1"])!
        check(fixedOrigin.url == international.url, "Credential base fields cannot redirect quota authentication")

        for field in ["proxy_url", "proxy-url"] {
            let proxied = try ZCodeCodingPlanRequest(metadata: ["key": key, "site": "zai", field: "socks5://127.0.0.1:1080"])!
            check(proxied.proxyURL == "socks5://127.0.0.1:1080", "Account proxy is preserved for either supported field spelling")
        }
        let direct = try ZCodeCodingPlanRequest(metadata: ["key": key, "site": "zai", "proxy_url": "direct"])!
        check(direct.proxyURL == "direct", "Explicit direct transport is preserved")
        rejects(["key": key, "site": "zai", "proxy_url": "file:///tmp/socket"], "Reject unsupported proxy schemes")
        print("PASS \(count) ZCode quota request routing and validation assertions")
    }
}
