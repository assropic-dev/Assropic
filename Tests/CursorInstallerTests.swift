// Run with: swiftc Sources/CursorLocal.swift Sources/ProcessLiveness.swift Tests/CursorInstallerTests.swift -o /tmp/cursor-installer-tests
//           /tmp/cursor-installer-tests Resources/CursorLocal
import Foundation
import CryptoKit

enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case let .message(message): return message } }
}
func jsonData(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}
func privateWrite(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

@main
struct CursorInstallerTests {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("bridgedock-cursor-tests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let manifestData = try Data(contentsOf: resources.appendingPathComponent("patches.json"))
        let manifest = try JSONDecoder().decode(CursorLocalInstaller.Manifest.self, from: manifestData)
        let app = temporary.appendingPathComponent("Cursor.app")
        let appResources = app.appendingPathComponent("Contents/Resources/app")
        let workbench = appResources.appendingPathComponent("out/vs/workbench")
        let state = temporary.appendingPathComponent("state")
        let installer = CursorLocalInstaller(directory: state, resources: resources, app: app)
        var assertions = 0
        func check(_ condition: Bool, _ label: String) {
            guard condition else { fatalError("FAILED: " + label) }
            assertions += 1
        }
        func rejects(_ label: String, _ action: () throws -> Void) {
            do { try action(); fatalError("SHOULD REJECT: " + label) }
            catch { assertions += 1 }
        }
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        func sources() throws -> [String: Data] {
            Dictionary(uniqueKeysWithValues: try manifest.files.map {
                ($0.name, try Data(contentsOf: installer.targetURL(for: $0)))
            })
        }

        let legacyIdentity = try JSONDecoder().decode(CursorLocalIdentity.self, from: Data(#"{"id":"existing","secret":"existing-secret","enabled":true}"#.utf8))
        check(legacyIdentity.id == "existing" && legacyIdentity.enabled && !legacyIdentity.modelParametersEnabled, "legacy identity defaults parameter switch off")
        var enabledIdentity = legacyIdentity
        enabledIdentity.modelParametersEnabled = true
        check(try JSONDecoder().decode(CursorLocalIdentity.self, from: JSONEncoder().encode(enabledIdentity)).modelParametersEnabled, "parameter switch persists independently")

        // Model a localized installation without copying or changing the real app.
        for file in manifest.files {
            let source = "// 保留其他程序的中文翻译\n" + file.patches.map(\.find).joined(separator: "\n/* gap */\n")
            try privateWrite(Data(source.utf8), to: installer.targetURL(for: file))
        }
        let productURL = appResources.appendingPathComponent("product.json")
        try privateWrite(jsonData(["version": manifest.version, "translationMarker": "keep", "checksums": ["other.js": "keep"]]), to: productURL)
        let identity = CursorLocalIdentity()
        let originalSources = try sources()
        try installer.validateCompatibility()
        check(try sources() == originalSources, "preflight does not modify workbench")
        check(!fm.fileExists(atPath: state.path), "preflight does not create installation state or backups")
        let changes = try installer.preparedChanges(identity: identity, manifest: manifest)
        for file in manifest.files {
            let url = installer.targetURL(for: file)
            let data = changes[url]!
            let source = String(decoding: data, as: UTF8.self)
            check(source.hasPrefix("import \"./bridgedock-local.js\";\n") == file.loadsRuntime, "runtime import only belongs in workbench")
            check(source.contains("保留其他程序的中文翻译"), "preserves translation")
            check(try installer.adaptedSource(source, file: file) == source, "current patch is idempotent")
            try privateWrite(data, to: url)
        }
        let product = try JSONSerialization.jsonObject(with: changes[productURL]!) as! [String: Any]
        check(product["translationMarker"] as? String == "keep", "preserves unrelated product fields")
        let checksums = product["checksums"] as! [String: String]
        check(checksums["other.js"] == "keep", "preserves unrelated checksums")
        for file in manifest.files where file.loadsRuntime {
            let hash = Data(SHA256.hash(data: changes[installer.targetURL(for: file)]!)).base64EncodedString().replacingOccurrences(of: "=", with: "")
            check(checksums["vs/workbench/" + file.name] == hash, "refreshes each workbench checksum")
        }
        let runtimeURL = workbench.appendingPathComponent("bridgedock-local.js")
        let runtime = changes[runtimeURL]!
        check(!String(decoding: runtime, as: UTF8.self).contains("__BD_SESSION_"), "renders runtime placeholders")
        for (url, data) in changes { try privateWrite(data, to: url) }
        let hashes = Dictionary(uniqueKeysWithValues: changes.map { url, data in
            (String(url.path.dropFirst(app.path.count + 1)), digest(data))
        })
        let revision = digest(manifestData + (try Data(contentsOf: resources.appendingPathComponent("runtime.js"))))
        let record = CursorLocalInstaller.Installation(backup: temporary.appendingPathComponent("unused-backup.app").path,
                                                      version: manifest.version, hashes: hashes, adapterRevision: revision)
        try privateWrite(JSONEncoder().encode(record), to: state.appendingPathComponent("cursor-installation.json"))
        check(installer.isInstalled(), "recognizes current structure and runtime")
        let translatedURL = workbench.appendingPathComponent(manifest.files[0].name)
        let translated = try Data(contentsOf: translatedURL) + Data("\n// 新增翻译不改变适配入口\n".utf8)
        try privateWrite(translated, to: translatedURL)
        check(installer.isInstalled(), "unrelated localized source changes remain ready")
        let damaged = String(decoding: translated, as: UTF8.self)
            .replacingOccurrences(of: "__bridgeDockRefreshModels", with: "__bridgeDockMissingModels")
        try privateWrite(Data(damaged.utf8), to: translatedURL)
        check(!installer.isInstalled(), "changed bundle with a damaged adapter fails the structural fallback")
        try privateWrite(translated, to: translatedURL)
        check(installer.isInstalled(), "restoring adapter entries retains unrelated translation changes")
        rejects("restore retains strict file-hash guard") { try installer.restore() }
        check(try Data(contentsOf: translatedURL) == translated, "rejected restore preserves current app")
        try privateWrite(runtime + Data("// drift".utf8), to: runtimeURL)
        check(!installer.isInstalled(), "runtime change requires upgrade")
        try privateWrite(runtime, to: runtimeURL)

        // Taking the adapter off returns exactly the localized pre-adapter sources, so
        // the language pack can recognize and restore its own files afterwards.
        try privateWrite(changes[translatedURL]!, to: translatedURL)
        for file in manifest.files {
            let current = try String(contentsOf: installer.targetURL(for: file), encoding: .utf8)
            check(try installer.unadaptedSource(current, file: file) == String(decoding: originalSources[file.name]!, as: UTF8.self),
                  "unadapted source equals the pre-adapter source for " + file.name)
        }
        try installer.removeAdapter()
        check(try sources() == originalSources, "removing the adapter restores every patched file byte for byte")
        check(!fm.fileExists(atPath: runtimeURL.path) && !installer.hasAdapterFiles, "removing the adapter deletes the runtime")
        let unpatchedProduct = try JSONSerialization.jsonObject(with: Data(contentsOf: productURL)) as! [String: Any]
        check(unpatchedProduct["translationMarker"] as? String == "keep", "removing the adapter keeps unrelated product fields")
        for file in manifest.files where file.loadsRuntime {
            let hash = Data(SHA256.hash(data: originalSources[file.name]!)).base64EncodedString().replacingOccurrences(of: "=", with: "")
            check((unpatchedProduct["checksums"] as? [String: String])?["vs/workbench/" + file.name] == hash, "removing the adapter refreshes checksums")
        }
        rejects("an unknown injection cannot be unadapted") {
            _ = try installer.unadaptedSource("import \"./bridgedock-local.js\";\nentry(){if(globalThis.__bridgeDockUnknown)return;}", file: manifest.files[0])
        }
        for (url, data) in changes { try privateWrite(data, to: url) }

        // Check exact legacy replacement migration and unknown/duplicate rejection.
        let singleData = Data(#"{"name":"test.js","patches":[{"find":"entry(){","replace":"entry(){if(globalThis.__bridgeDockNew)return;","previousReplacements":["entry(){if(globalThis.__bridgeDockOld)return;"]}]}"#.utf8)
        let single = try JSONDecoder().decode(CursorLocalInstaller.FilePatches.self, from: singleData)
        let upgraded = try installer.adaptedSource("import \"./bridgedock-local.js\";\nentry(){if(globalThis.__bridgeDockOld)return;body}", file: single)
        check(upgraded.contains("__bridgeDockNew") && !upgraded.contains("__bridgeDockOld"), "upgrades only explicitly known legacy replacement")
        rejects("unknown old injection") { _ = try installer.adaptedSource("entry(){if(globalThis.__bridgeDockUnknown)return;body}", file: single) }
        rejects("duplicate original entry") { _ = try installer.adaptedSource("entry(){x}entry(){y}", file: single) }
        rejects("duplicate current entry") { _ = try installer.adaptedSource(upgraded + upgraded, file: single) }
        rejects("missing expected entry") { _ = try installer.adaptedSource("anotherEntry(){body}", file: single) }
        rejects("unknown import syntax") { _ = try installer.adaptedSource("import './bridgedock-local.js';\nentry(){body}", file: single) }

        // Read-only compatibility check against the installed app, if requested.
        if CommandLine.arguments.count > 2 {
            let installed = URL(fileURLWithPath: CommandLine.arguments[2])
            let actual = CursorLocalInstaller(directory: state, resources: resources, app: installed)
            try actual.validateCompatibility()
            assertions += 1
        }
        print("PASS \(assertions) Cursor installer compatibility, preservation and restore assertions")
    }
}
