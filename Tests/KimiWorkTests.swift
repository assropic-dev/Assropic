import Foundation
import CryptoKit

@main
struct KimiWorkTests {
    static var count = 0
    static var failures: [String] = []
    static let fakeKey = "fake-work-api-key-sensitive"
    static let fakeWeb = "fake-work-web-token-sensitive"
    static let fakeUser = "fake-work-user-sensitive"

    static func check(_ condition: Bool, _ message: String) {
        count += 1
        if !condition { failures.append(message) }
    }

    static func rejection(_ message: String, _ operation: () throws -> Void) -> String {
        count += 1
        do {
            try operation()
            failures.append(message)
            return ""
        } catch {
            let text = error.localizedDescription
            check(![fakeKey, fakeWeb, fakeUser, "never-read-refresh-sensitive"].contains(where: text.contains),
                  "Read errors never expose credentials or upstream file contents")
            return text
        }
    }

    static func document(endpoint: String = KimiWorkSession.baseURL, key: Any = fakeKey, web: Any = fakeWeb, user: Any = fakeUser) -> [String: Any] {
        ["credentials": ["kimiCode": ["baseUrl": endpoint, "apiKey": key],
                         "kimiWeb": ["accessToken": web, "userId": user, "refreshToken": "never-read-refresh-sensitive"]],
         "unrelatedSetting": ["keep": true]]
    }

    static func write(_ value: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: file)
    }

    static func main() throws {
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("bridgedock-kimi-work-tests-" + UUID().uuidString)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("config.json")
        try write(document(), to: file)
        let original = try Data(contentsOf: file)
        let originalAttributes = try files.attributesOfItem(atPath: file.path)
        let session = try KimiWorkSession.read(file: file)
        check(session.apiKey == fakeKey && session.webToken == fakeWeb, "Read Work credentials from the verified native field paths")
        let expectedHash = SHA256.hash(data: Data(("kimi-work-account\0" + fakeUser).utf8)).map { String(format: "%02x", $0) }.joined()
        check(session.accountHash == expectedHash && session.accountHash.count == 64, "Account reference is the domain-separated SHA-256 of the user ID")
        check(try KimiWorkSession.read(expectedAccountHash: expectedHash, file: file).accountHash == expectedHash, "The previously connected account can be reopened")
        check(try Data(contentsOf: file) == original, "Reading leaves native Work configuration bytes unchanged")
        let finalAttributes = try files.attributesOfItem(atPath: file.path)
        check(finalAttributes[.modificationDate] as? Date == originalAttributes[.modificationDate] as? Date, "Reading does not rewrite Work configuration")
        check(!(session.description + session.debugDescription).contains(fakeKey) && !(session.description + session.debugDescription).contains(fakeWeb), "Session diagnostics do not print raw credentials")
        check(KimiWorkSession.defaultURL.path.hasSuffix("/Library/Application Support/kimi-desktop/daimon-share/daimon/config.json"), "The default path selects native desktop Work state")

        try write(document(endpoint: KimiWorkSession.baseURL + "/"), to: file)
        check(try KimiWorkSession.read(file: file).accountHash == expectedHash, "One trailing slash on the exact Work gateway is accepted")
        for endpoint in [
            "https://api.kimi.com/coding/v1", "https://api.kimi.ai/coding/v1", "http://agent-gw.kimi.com/coding/v1",
            "https://agent-gw.kimi.com.evil.invalid/coding/v1", "https://agent-gw.kimi.com@evil.invalid/coding/v1",
            "https://secret@agent-gw.kimi.com/coding/v1", "https://agent-gw.kimi.com:8443/coding/v1",
            KimiWorkSession.baseURL + "//", KimiWorkSession.baseURL + "?secret=" + fakeKey,
            KimiWorkSession.baseURL + "#fragment", "https://agent-gw.kimi.com/coding", " " + KimiWorkSession.baseURL
        ] {
            try write(document(endpoint: endpoint), to: file)
            let message = rejection("Only the exact Work gateway may supply Work credentials") { _ = try KimiWorkSession.read(file: file) }
            check(message.contains("Kimi Work") && message.contains("重新连接"), "Wrong endpoint errors explain the Work reconnection action")
        }

        for invalid in ["{", "[]", "null", "true", "\"" + fakeKey + "\""] {
            try Data(invalid.utf8).write(to: file)
            _ = rejection("Malformed or non-object native configuration is rejected") { _ = try KimiWorkSession.read(file: file) }
        }
        for invalidDocument: [String: Any] in [[:], ["credentials": [:]], ["credentials": ["kimiCode": ["apiKey": fakeKey]]],
                                              ["credentials": ["kimiCode": "wrong", "kimiWeb": [:]]]] {
            try write(invalidDocument, to: file)
            _ = rejection("Incomplete login structure is rejected") { _ = try KimiWorkSession.read(file: file) }
        }
        for invalid: Any in ["", " ", "bad\nheader", 42, NSNull()] {
            for invalidDocument in [document(key: invalid), document(web: invalid), document(user: invalid)] {
                try write(invalidDocument, to: file)
                let message = rejection("Empty, malformed or header-unsafe login fields are rejected") { _ = try KimiWorkSession.read(file: file) }
                check(message.contains("重新登录"), "An incomplete login explains how to sign in again")
            }
        }

        try write(document(key: "rotated-fake-key", web: "rotated-fake-web"), to: file)
        let rotated = try KimiWorkSession.read(expectedAccountHash: session.accountHash, file: file)
        check(rotated.accountHash == session.accountHash && rotated.apiKey != session.apiKey, "Token rotation preserves the connected account identity")
        check(rotated.fingerprint != session.fingerprint, "API key rotation changes the in-memory refresh fingerprint")
        check(session.fingerprint == SHA256.hash(data: Data(fakeKey.utf8)).map { String(format: "%02x", $0) }.joined(), "The fingerprint contains a SHA-256 digest rather than a token copy")
        try write(document(user: "another-local-work-user"), to: file)
        let changed = rejection("A different native Work account cannot silently replace the connected account") {
            _ = try KimiWorkSession.read(expectedAccountHash: session.accountHash, file: file)
        }
        check(changed.contains("切换账号") && changed.contains("重新连接"), "Account-switch errors offer an explicit reconnection path")
        check(try KimiWorkSession.read(file: file).accountHash != session.accountHash, "Explicit reconnection can read the newly selected native account")

        var noRefresh = document()
        var credentials = noRefresh["credentials"] as! [String: Any]
        var web = credentials["kimiWeb"] as! [String: Any]
        web["refreshToken"] = ["unusable": true]
        credentials["kimiWeb"] = web
        noRefresh["credentials"] = credentials
        try write(noRefresh, to: file)
        check(try KimiWorkSession.read(file: file).apiKey == fakeKey, "Read does not depend on or process native refresh tokens")

        let atLimit = try JSONSerialization.data(withJSONObject: document(), options: [.sortedKeys])
        var padded = atLimit
        padded.append(Data(repeating: 32, count: KimiWorkSession.maximumFileSize - atLimit.count))
        try padded.write(to: file)
        check(try KimiWorkSession.read(file: file).accountHash == expectedHash, "A valid document exactly at 8 MiB remains readable")
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(KimiWorkSession.maximumFileSize + 1))
        try handle.close()
        _ = rejection("Files larger than 8 MiB are rejected before JSON parsing") { _ = try KimiWorkSession.read(file: file) }

        try files.removeItem(at: file)
        let missing = rejection("Missing desktop login is reported without exposing a filesystem error") { _ = try KimiWorkSession.read(file: file) }
        check(missing.contains("本机") && missing.contains("重新登录"), "Missing native login directs the user back to local Work")
        _ = rejection("A directory cannot act as a credential file") { _ = try KimiWorkSession.read(file: scratch) }
        let target = scratch.appendingPathComponent("actual-config.json")
        try write(document(), to: target)
        try files.createSymbolicLink(at: file, withDestinationURL: target)
        _ = rejection("A credential symlink is never followed") { _ = try KimiWorkSession.read(file: file) }
        check(try Data(contentsOf: target) == original, "Rejected symlinks leave the original credential target untouched")
        _ = rejection("Non-file URLs are rejected without attempting network access") { _ = try KimiWorkSession.read(file: URL(string: "https://example.invalid/" + fakeKey)!) }

        if failures.isEmpty {
            print("PASS \(count) Kimi Work native-login, origin, account-binding and read-only assertions")
        } else {
            failures.forEach { print("FAIL: " + $0) }
            print("FAILED \(failures.count) of \(count) Kimi Work assertions")
            exit(1)
        }
    }
}
