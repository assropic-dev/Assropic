import Foundation

struct ZCodeCodingPlanRequest {
    let url: String
    let headers: [String: String]
    let proxyURL: String

    init?(metadata: [String: Any]) throws {
        let key = try Self.string("key", in: metadata)
        guard !key.isEmpty else { return nil }
        guard key.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw BridgeError.message("ZCode Coding Plan Key 格式无效，请重新授权。")
        }
        let site = try Self.string("site", in: metadata)
        guard ["bigmodel", "zai"].contains(site) else {
            throw BridgeError.message("ZCode 账号区域无效，请重新授权。")
        }
        let organization = try Self.string("org", in: metadata)
        let project = try Self.string("project", in: metadata)
        guard [organization, project].allSatisfy({ $0.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil }) else {
            throw BridgeError.message("ZCode 团队信息格式无效，请重新授权。")
        }
        guard organization.isEmpty == project.isEmpty else {
            throw BridgeError.message("ZCode 团队账号缺少组织或项目，无法查询团队额度。")
        }

        let team = !organization.isEmpty
        let root = site == "bigmodel" ? (team ? "https://bigmodel.cn" : "https://open.bigmodel.cn") : "https://api.z.ai"
        url = root + "/api/monitor/usage/quota/limit" + (team ? "?type=2" : "")
        var requestHeaders = ["Authorization": key, "Accept": "application/json"]
        if team {
            requestHeaders["Bigmodel-Organization"] = organization
            requestHeaders["Bigmodel-Project"] = project
            requestHeaders["Set-Language"] = "en"
            requestHeaders["Accept-Language"] = "en-US,en"
        }
        headers = requestHeaders
        proxyURL = try Self.string(metadata["proxy_url"] == nil ? "proxy-url" : "proxy_url", in: metadata)
        try validateProxyURL(proxyURL)
    }

    private static func string(_ field: String, in metadata: [String: Any]) throws -> String {
        guard let value = metadata[field], !(value is NSNull) else { return "" }
        guard let text = value as? String else {
            throw BridgeError.message("ZCode 账号字段 \(field) 格式无效，请重新授权。")
        }
        return text
    }
}
