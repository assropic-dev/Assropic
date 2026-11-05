import Foundation
import CryptoKit

/// Prefers provider identity to preserve routing preferences across token renewal.
/// Opaque credentials fall back to a digest so different accounts stay separate.
enum LocalSubscriptionIdentity {
    static func stableIdentity(_ document: [String: Any]) -> String? {
        let claims = jwtClaims(document["id_token"] as? String)
        let accessClaims = jwtClaims(document["access_token"] as? String)
        let auth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let accessAuth = accessClaims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let candidates: [Any?] = [document["account_id"], auth["chatgpt_account_id"], accessAuth["chatgpt_account_id"],
                                  document["profileArn"], document["profile_arn"],
                                  claims["sub"], accessClaims["sub"], document["email"],
                                  document["local_identity"]]
        return candidates.compactMap { $0 as? String }.first { !$0.isEmpty }
    }

    static func filename(provider: String, document: [String: Any]) -> String {
        // Some Kiro social/Claude credentials contain only opaque tokens. Their
        // refresh token is safer than a path that could silently replace a user.
        let fallback = document["refresh_token"] as? String ?? document["access_token"] as? String ?? ""
        let bytes = Data((provider + "\0" + (stableIdentity(document) ?? fallback)).utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return "local-" + provider + "-" + String(digest.prefix(24)) + ".json"
    }

    static func prefix(provider: String, occupied: Set<String>) -> String {
        let base = provider == "codex" ? "gpt" : provider
        if !occupied.contains(base) { return base }
        var suffix = 2
        while occupied.contains(base + "-" + String(suffix)) { suffix += 1 }
        return base + "-" + String(suffix)
    }

    private static func jwtClaims(_ token: String?) -> [String: Any] {
        guard let token else { return [:] }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return [:] }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return claims
    }
}

