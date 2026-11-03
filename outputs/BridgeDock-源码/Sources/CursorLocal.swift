import Foundation
import CryptoKit
import Network
import AppKit

struct CursorLocalIdentity: Codable {
    var id = UUID().uuidString.lowercased()
    var secret = UUID().uuidString + UUID().uuidString
    var name = "BridgeDock 本地账号"
    var enabled = false
    var modelParametersEnabled = false

    enum CodingKeys: String, CodingKey { case id, secret, name, enabled, modelParametersEnabled }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CursorLocalIdentity()
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? d.id
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? d.secret
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        modelParametersEnabled = try c.decodeIfPresent(Bool.self, forKey: .modelParametersEnabled) ?? false
    }
}

/// A loopback-only endpoint used by Cursor during workbench startup.
final class CursorSessionServer: @unchecked Sendable {
    static let port: UInt16 = 18418
    private let queue = DispatchQueue(label: "local.bridgedock.cursor-session")
    private let lock = NSLock()
    private var payload = Data()
    private var secret = ""
    private var listener: NWListener?

    func update(identity: CursorLocalIdentity, apiURL: String, key: String, model: String) throws {
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let header = base64URL(try jsonData(["alg": "HS256", "typ": "JWT"]))
        let claims = base64URL(try jsonData([
            "sub": "bridgedock|" + identity.id, "exp": Int(Date().timeIntervalSince1970) + 86400,
            "iat": Int(Date().timeIntervalSince1970), "iss": "BridgeDock"
        ]))
        let message = header + "." + claims
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(identity.secret.utf8)))
        let data = try jsonData([
            "id": identity.id, "name": identity.name, "email": "local@bridgedock.invalid",
            "token": message + "." + base64URL(Data(signature)), "baseURL": apiURL,
            "key": key, "model": model, "modelParametersEnabled": identity.modelParametersEnabled, "gatewayURL": "http://127.0.0.1:\(Self.port)"
        ])
        lock.lock()
        payload = data
        secret = identity.secret
        lock.unlock()
    }

    func start() async throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        let newListener = try NWListener(using: parameters)
        listener = newListener
        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 3) { connection.cancel() }
            self.receive(connection, accumulated: Data())
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                newListener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        newListener.stateUpdateHandler = nil
                        continuation.resume()
                    case .failed(let error):
                        newListener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    case .cancelled:
                        newListener.stateUpdateHandler = nil
                        continuation.resume(throwing: CancellationError())
                    default: break
                    }
                }
                newListener.start(queue: queue)
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        payload = Data()
        secret = ""
        lock.unlock()
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var bytes = accumulated
            bytes.append(data ?? Data())
            guard bytes.count <= 8192 else { connection.cancel(); return }
            guard let request = String(data: bytes, encoding: .utf8), request.contains("\r\n\r\n") else {
                if complete { connection.cancel() }
                else { self.receive(connection, accumulated: bytes) }
                return
            }
            let lines = request.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            let supplied = lines.dropFirst().first { $0.lowercased().hasPrefix("x-bridgedock-session:") }?
                .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
            self.lock.lock()
            let authorized = !self.secret.isEmpty && supplied == self.secret
            let body = self.payload
            self.lock.unlock()
            let method = first.first.map(String.init) ?? ""
            let path = first.count > 1 ? String(first[1]) : ""
            let status: String
            let responseBody: Data
            if method == "OPTIONS" && path == "/session" {
                status = "204 No Content"
                responseBody = Data()
            } else if method == "GET" && path == "/session" && authorized && !body.isEmpty {
                status = "200 OK"
                responseBody = body
            } else {
                status = path == "/session" ? "403 Forbidden" : "404 Not Found"
                responseBody = Data("{\"error\":\"BridgeDock local session endpoint\"}".utf8)
            }
            let headers = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, OPTIONS\r\nAccess-Control-Allow-Headers: X-BridgeDock-Session\r\nContent-Length: \(responseBody.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(headers.utf8) + responseBody, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

struct CursorLocalInstaller {
    let directory: URL
    let resources: URL
    let app: URL
    private let marker = "import \"./bridgedock-local.js\";\n"

    struct Patch: Decodable {
        let find: String
        let replace: String
        /// Only exact, previously shipped replacements belong here. Never infer a
        /// compatible patch from a similar-looking JavaScript function.
        let previousReplacements: [String]?
    }
    struct FilePatches: Decodable {
        let name: String
        let patches: [Patch]
        let scope: String?
        var loadsRuntime: Bool { scope != "app" }
    }
    struct Manifest: Decodable { let version: String; let files: [FilePatches] }
    struct Installation: Codable {
        let backup: String
        let version: String
        let hashes: [String: String]
        let adapterRevision: String?
    }

    private var recordURL: URL { directory.appendingPathComponent("cursor-installation.json") }
    private var appResources: URL { app.appendingPathComponent("Contents/Resources/app") }
    private var workbench: URL { appResources.appendingPathComponent("out/vs/workbench") }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func resourceRevision() throws -> String {
        let patches = try Data(contentsOf: resources.appendingPathComponent("patches.json"))
        let runtime = try Data(contentsOf: resources.appendingPathComponent("runtime.js"))
        return digest(patches + runtime)
    }

    func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(Installation.self, from: data),
              let revision = try? resourceRevision(), record.adapterRevision == revision,
              let manifest = try? readManifest(), record.version == manifest.version,
              let product = try? readProduct(), product["version"] as? String == manifest.version else { return false }
        // A matching revision and recorded hash already identify the exact
        // adapted bytes. Avoid rescanning the large workbench/extension bundles
        // on every launch. A translation may change the hash while retaining all
        // adapter entries, so changed files still receive the structural check.
        for file in manifest.files {
            let url = targetURL(for: file)
            guard let data = try? Data(contentsOf: url) else { return false }
            let path = String(url.path.dropFirst(app.path.count + 1))
            if let hash = record.hashes[path], digest(data) == hash { continue }
            guard let source = String(data: data, encoding: .utf8),
                  let adapted = try? adaptedSource(source, file: file), adapted == source else { return false }
        }
        let runtimePath = "Contents/Resources/app/out/vs/workbench/bridgedock-local.js"
        guard let hash = record.hashes[runtimePath],
              let runtime = try? Data(contentsOf: app.appendingPathComponent(runtimePath)) else { return false }
        return digest(runtime) == hash
    }

    func targetURL(for file: FilePatches) -> URL {
        (file.scope == "app" ? appResources : workbench).appendingPathComponent(file.name)
    }

    private func matchesInstalledFiles(_ record: Installation) -> Bool {
        return record.hashes.allSatisfy { path, hash in
            guard let current = try? Data(contentsOf: app.appendingPathComponent(path)) else { return false }
            return digest(current) == hash
        }
    }

    /// Read-only preflight; callers can check support before asking Cursor to quit.
    func validateCompatibility() throws {
        if isInstalled() { return }
        _ = try preparedChanges(identity: CursorLocalIdentity(), manifest: readManifest())
    }

    func install(identity: CursorLocalIdentity) throws {
        if isInstalled() { return }
        try requireStoppedApplication()
        let manifest = try readManifest()
        // Validate every entry before making a backup or changing any file. An
        // upgrade is applied to the current app, preserving unrelated edits.
        let changes = try preparedChanges(identity: identity, manifest: manifest)

        let backups = directory.appendingPathComponent("cursor-backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = backups.appendingPathComponent(UUID().uuidString + ".app")
        try run("/bin/cp", ["-cR", app.path, backup.path])
        // Copying a large app takes time. Recheck before the first write in case
        // the user reopened Cursor from the Dock while the backup was running.
        try requireStoppedApplication()
        do {
            for (url, data) in changes {
                if url.lastPathComponent == "bridgedock-local.js" { try privateWrite(data, to: url) }
                else { try data.write(to: url, options: .atomic) }
            }
            try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", "--options", "0", "--preserve-metadata=entitlements", app.path])
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
            let hashes = Dictionary(uniqueKeysWithValues: changes.map { url, data in
                (String(url.path.dropFirst(app.path.count + 1)), digest(data))
            })
            let record = Installation(backup: backup.path, version: manifest.version, hashes: hashes, adapterRevision: try resourceRevision())
            try privateWrite(JSONEncoder().encode(record), to: recordURL)
        } catch {
            try restoreApp(from: backup)
            throw error
        }
    }

    private func requireStoppedApplication() throws {
        guard !NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleURL?.standardizedFileURL == app.standardizedFileURL &&
                !$0.isTerminated && !ProcessLiveness.hasExited($0.processIdentifier)
        }) else {
            throw BridgeError.message("Cursor 在适配期间重新打开，已停止修改。请退出 Cursor 后重试。")
        }
    }

    private func readManifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: resources.appendingPathComponent("patches.json")))
    }

    private func readProduct() throws -> [String: Any] {
        guard let product = try JSONSerialization.jsonObject(with: Data(contentsOf: appResources.appendingPathComponent("product.json"))) as? [String: Any] else {
            throw BridgeError.message("无法读取 Cursor 的版本信息。")
        }
        return product
    }

    /// Pure preparation, also used by compatibility tests with a temporary app.
    func preparedChanges(identity: CursorLocalIdentity, manifest: Manifest) throws -> [URL: Data] {
        var product = try readProduct()
        guard product["version"] as? String == manifest.version else {
            throw BridgeError.message("当前适配支持 Cursor \(manifest.version)。检测到其他版本，请更新 BridgeDock 适配后再启用。")
        }
        var changes: [URL: Data] = [:]
        var checksums = product["checksums"] as? [String: String] ?? [:]
        for file in manifest.files {
            let url = targetURL(for: file)
            let source = try String(contentsOf: url, encoding: .utf8)
            let data = Data(try adaptedSource(source, file: file).utf8)
            changes[url] = data
            if file.loadsRuntime {
                checksums["vs/workbench/" + file.name] = Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
            }
        }
        var runtime = try String(contentsOf: resources.appendingPathComponent("runtime.js"), encoding: .utf8)
        runtime = runtime.replacingOccurrences(of: "__BD_SESSION_PORT__", with: String(CursorSessionServer.port))
            .replacingOccurrences(of: "__BD_SESSION_SECRET__", with: String(decoding: try JSONEncoder().encode(identity.secret), as: UTF8.self))
        changes[workbench.appendingPathComponent("bridgedock-local.js")] = Data(runtime.utf8)
        product["checksums"] = checksums
        changes[appResources.appendingPathComponent("product.json")] = try jsonData(product)
        return changes
    }

    func adaptedSource(_ source: String, file: FilePatches) throws -> String {
        func incompatible() -> BridgeError {
            BridgeError.message("Cursor \(file.name) 中的适配入口无法可靠识别，已保留原文件。请更新 BridgeDock 适配后重试。")
        }
        let content = NSMutableString(string: source)
        if source.hasPrefix(marker) { content.deleteCharacters(in: NSRange(location: 0, length: (marker as NSString).length)) }
        // A different or duplicate import cannot safely be normalized.
        guard content.range(of: "bridgedock-local.js", options: .literal).location == NSNotFound else { throw incompatible() }
        for patch in file.patches {
            guard !patch.find.isEmpty, !patch.replace.isEmpty, patch.find != patch.replace else { throw incompatible() }
            let candidates = [patch.replace] + (patch.previousReplacements ?? [])
            // Prefer the complete current replacement when an older replacement
            // happens to be its prefix. Only exact manifest entries are accepted.
            let matched = candidates.first { content.range(of: $0, options: .literal).location != NSNotFound }
            let target = matched ?? patch.find
            let range = content.range(of: target, options: .literal)
            guard range.location != NSNotFound else { throw incompatible() }
            let before = NSRange(location: 0, length: range.location)
            let after = NSRange(location: NSMaxRange(range), length: content.length - NSMaxRange(range))
            for needle in [patch.find] + candidates {
                guard content.range(of: needle, options: .literal, range: before).location == NSNotFound,
                      content.range(of: needle, options: .literal, range: after).location == NSNotFound else { throw incompatible() }
            }
            content.replaceCharacters(in: range, with: patch.replace)
        }
        // Reject unknown older BD injections instead of stacking a second guard
        // after an unrecognized one. Non-BD translations and edits are preserved.
        let expectedReferences = file.patches.reduce(0) { $0 + $1.replace.components(separatedBy: "__bridgeDock").count - 1 }
        var referenceCount = 0
        var scan = NSRange(location: 0, length: content.length)
        while scan.length > 0 {
            let range = content.range(of: "__bridgeDock", options: .literal, range: scan)
            if range.location == NSNotFound { break }
            referenceCount += 1
            scan = NSRange(location: NSMaxRange(range), length: content.length - NSMaxRange(range))
        }
        guard referenceCount == expectedReferences else { throw incompatible() }
        return (file.loadsRuntime ? marker : "") + (content as String)
    }

    func restore() throws {
        let record = try JSONDecoder().decode(Installation.self, from: Data(contentsOf: recordURL))
        guard matchesInstalledFiles(record) else { throw BridgeError.message("Cursor 已更新或被其他程序修改，无法自动覆盖。备份在 cursor-backups 目录。") }
        try restoreApp(from: URL(fileURLWithPath: record.backup))
        try FileManager.default.removeItem(at: recordURL)
    }

    private func restoreApp(from backup: URL) throws {
        let failed = app.deletingLastPathComponent().appendingPathComponent(".bridgedock-cursor-" + UUID().uuidString + ".app")
        try FileManager.default.moveItem(at: app, to: failed)
        do {
            try run("/bin/cp", ["-cR", backup.path, app.path])
            try FileManager.default.removeItem(at: failed)
        } catch {
            if FileManager.default.fileExists(atPath: app.path) { try? FileManager.default.removeItem(at: app) }
            try FileManager.default.moveItem(at: failed, to: app)
            throw error
        }
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BridgeError.message("Cursor 适配失败。" + String(decoding: output, as: UTF8.self).prefix(1000))
        }
    }
}
