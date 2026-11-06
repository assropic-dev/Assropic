import Foundation

@main
struct KimiWorkRoutingTests {
    static var assertions = 0

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAIL: " + label) }
        assertions += 1
    }

    static func workChannel(_ id: String = "work-one") -> Channel {
        var channel = Channel()
        channel.id = id
        channel.name = "Kimi Work"
        channel.credentialSource = "kimi-work-desktop"
        channel.desktopAccountHash = String(repeating: "a", count: 64)
        channel.baseURL = KimiWorkSession.baseURL
        channel.wire = .chat
        channel.prefix = "work"
        channel.modelLines = "k3-agent"
        channel.balanceMode = .kimiWork
        return channel
    }

    static func main() throws {
        let channel = workChannel()
        let session = KimiWorkSession(apiKey: "synthetic-work-secret",
                                      webToken: "synthetic-membership-secret",
                                      accountHash: channel.desktopAccountHash)
        var ordinary = Channel()
        ordinary.id = "ordinary"
        ordinary.name = "Ordinary API"
        ordinary.apiKey = "synthetic-ordinary-key"
        ordinary.baseURL = "https://api.example.invalid/v1"
        ordinary.modelLines = "ordinary-model"
        ordinary.prefix = "ordinary"
        var settings = AppSettings()
        settings.channels = [channel, ordinary]
        let before = try JSONEncoder().encode(settings)
        var requestedHashes: [String] = []
        let resolved = KimiWorkRouting.resolve(settings) { expected in
            requestedHashes.append(expected)
            return session
        }
        check(requestedHashes == [channel.desktopAccountHash], "only Work account is read")
        check(resolved.channels[0].apiKey == session.apiKey, "live Work key is injected into the copy")
        check(resolved.channels[0].enabled, "valid Work account stays enabled")
        check(resolved.channels[0].desktopAccountHash == channel.desktopAccountHash, "account binding is retained")
        check(resolved.channels[1] == ordinary, "ordinary API channel is unchanged")
        check(settings.channels[0].apiKey.isEmpty, "source Work key remains empty")
        let after = try JSONEncoder().encode(settings)
        let sourceJSON = String(decoding: after, as: UTF8.self)
        // JSON key ordering is unspecified; compare the decoded documents too.
        let beforeObject = try JSONSerialization.jsonObject(with: before) as! NSDictionary
        let afterObject = try JSONSerialization.jsonObject(with: after) as! NSDictionary
        check(beforeObject == afterObject, "resolve leaves the saved settings unchanged")
        check(!sourceJSON.contains(session.apiKey), "encoded state never receives the Work key")
        check(!sourceJSON.contains(session.webToken), "encoded state never receives the membership token")

        var disabled = channel
        disabled.enabled = false
        disabled.apiKey = "stale-work-key"
        var disabledSettings = settings
        disabledSettings.channels = [disabled, ordinary]
        var disabledReads = 0
        let disabledResult = KimiWorkRouting.resolve(disabledSettings) { _ in
            disabledReads += 1
            return session
        }
        check(disabledReads == 0, "disabled Work account is not read")
        check(!disabledResult.channels[0].enabled, "disabled Work account stays disabled")
        check(disabledResult.channels[0].apiKey.isEmpty, "disabled Work copy cannot carry a stale key")
        check(disabledSettings.channels[0].apiKey == "stale-work-key", "even stale source state is not mutated")

        var wrongHost = channel
        wrongHost.baseURL = "https://example.invalid/coding/v1"
        var wrongPath = channel
        wrongPath.baseURL = KimiWorkSession.baseURL + "/other"
        var wrongProtocol = channel
        wrongProtocol.wire = .anthropic
        var unbound = channel
        unbound.desktopAccountHash = ""
        for unsafe in [wrongHost, wrongPath, wrongProtocol, unbound] {
            var unsafeSettings = settings
            unsafeSettings.channels = [unsafe]
            var reads = 0
            let result = KimiWorkRouting.resolve(unsafeSettings) { _ in
                reads += 1
                return session
            }
            check(reads == 0, "unsafe destination or missing binding is rejected before reading")
            check(!result.channels[0].enabled && result.channels[0].apiKey.isEmpty,
                  "unsafe Work channel fails closed")
        }

        let changed = KimiWorkSession(apiKey: "other-account-key", webToken: "other-web-token",
                                      accountHash: String(repeating: "b", count: 64))
        let mismatched = KimiWorkRouting.resolve(settings) { _ in changed }
        check(!mismatched.channels[0].enabled && mismatched.channels[0].apiKey.isEmpty,
              "a reader returning another account fails closed")
        let unavailable = KimiWorkRouting.resolve(settings) { _ in throw KimiWorkReadError.accountChanged }
        check(!unavailable.channels[0].enabled && unavailable.channels[0].apiKey.isEmpty,
              "desktop read failure disables only the transient Work channel")
        check(unavailable.channels[1] == ordinary, "failed Work read leaves ordinary channel intact")
        check(settings.channels[0].enabled, "failed read does not disable saved state")
        let emptyKey = KimiWorkSession(apiKey: "", webToken: "fixture", accountHash: channel.desktopAccountHash)
        check(!KimiWorkRouting.resolve(settings, read: { _ in emptyKey }).channels[0].enabled,
              "empty resolved Work key fails closed")

        let stable = KimiWorkRouting.fingerprint(settings) { _ in session }
        check(stable.contains(channel.id) && stable.contains(session.fingerprint),
              "fingerprint tracks channel identity and hashed Work key")
        check(!stable.contains(session.apiKey) && !stable.contains(session.webToken),
              "fingerprint does not expose either credential")
        check(stable == KimiWorkRouting.fingerprint(settings, read: { _ in session }),
              "unchanged Work session has a stable fingerprint")
        let rotated = KimiWorkSession(apiKey: "rotated-work-secret", webToken: session.webToken,
                                      accountHash: channel.desktopAccountHash)
        check(stable != KimiWorkRouting.fingerprint(settings, read: { _ in rotated }),
              "Work key rotation changes the fingerprint")
        let failed = KimiWorkRouting.fingerprint(settings) { _ in throw KimiWorkReadError.unavailable }
        check(failed.contains("unavailable"), "failed reads have an unavailable fingerprint")
        check(stable != failed, "available to unavailable transition changes the fingerprint")
        let empty = KimiWorkRouting.fingerprint(disabledSettings) { _ in
            fatalError("disabled/ordinary accounts must not be read")
        }
        check(empty.isEmpty, "disabled and ordinary accounts are excluded from fingerprint")
        var unsafeSettings = settings
        unsafeSettings.channels = [wrongHost]
        let unsafeFingerprint = KimiWorkRouting.fingerprint(unsafeSettings) { _ in
            fatalError("unsafe destination must not read private credentials")
        }
        check(unsafeFingerprint.contains("unavailable"), "unsafe Work destination fingerprints as unavailable")

        print("PASS \(assertions) Kimi Work routing assertions; synthetic sessions only.")
    }
}
