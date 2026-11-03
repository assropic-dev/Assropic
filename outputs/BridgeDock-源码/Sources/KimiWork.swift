import Foundation
import CryptoKit

enum KimiWorkReadError: LocalizedError {
    case unavailable, unsafeFile, tooLarge, malformed, wrongEndpoint, missingCredentials, accountChanged, fileChanged

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "未能读取本机 Kimi Work 登录。请打开 Kimi Work，在本机重新登录后重新连接。"
        case .unsafeFile:
            return "Kimi Work 配置必须是普通文件，不能使用符号链接。请在本机 Kimi Work 重新登录后重新连接。"
        case .tooLarge:
            return "Kimi Work 配置超过 8 MiB，无法读取。请检查本机 Kimi Work 后重新连接。"
        case .malformed:
            return "Kimi Work 配置格式无效。请在本机 Kimi Work 重新登录后重新连接。"
        case .wrongEndpoint:
            return "当前配置不是受支持的 Kimi Work 网关。请在本机 Kimi Work 重新登录后重新连接。"
        case .missingCredentials:
            return "本机 Kimi Work 登录不完整或已失效。请在 Kimi Work 重新登录后重新连接。"
        case .accountChanged:
            return "本机 Kimi Work 已切换账号。请切回原账号，或在 BridgeDock 中重新连接当前 Work 账号。"
        case .fileChanged:
            return "读取时 Kimi Work 配置发生变化，请稍后重新连接。"
        }
    }
}

/// An in-memory view of Kimi Work's own login. It never refreshes or persists tokens.
struct KimiWorkSession: CustomStringConvertible, CustomDebugStringConvertible {
    static let baseURL = "https://agent-gw.kimi.com/coding/v1"
    static let maximumFileSize = 8 * 1024 * 1024
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kimi-desktop/daimon-share/daimon/config.json")
    }

    let apiKey: String
    let webToken: String
    let accountHash: String
    var fingerprint: String { Self.digest(apiKey) }
    var description: String { "KimiWorkSession(accountHash: \(accountHash))" }
    var debugDescription: String { description }

    static func read(expectedAccountHash: String? = nil, file: URL = defaultURL) throws -> KimiWorkSession {
        guard file.isFileURL else { throw KimiWorkReadError.unsafeFile }
        let before = try attributes(of: file)
        guard before[.type] as? FileAttributeType == .typeRegular else { throw KimiWorkReadError.unsafeFile }
        guard let size = before[.size] as? NSNumber, size.int64Value <= Int64(maximumFileSize) else {
            throw KimiWorkReadError.tooLarge
        }

        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: file) }
        catch { throw KimiWorkReadError.unavailable }
        defer { try? handle.close() }
        var data = Data()
        do {
            while data.count <= maximumFileSize {
                let remaining = maximumFileSize + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining)), !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch { throw KimiWorkReadError.unavailable }
        guard data.count <= maximumFileSize else { throw KimiWorkReadError.tooLarge }
        let after = try attributes(of: file)
        guard after[.type] as? FileAttributeType == .typeRegular else { throw KimiWorkReadError.unsafeFile }
        guard before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber,
              before[.systemNumber] as? NSNumber == after[.systemNumber] as? NSNumber,
              before[.size] as? NSNumber == after[.size] as? NSNumber,
              before[.modificationDate] as? Date == after[.modificationDate] as? Date else {
            throw KimiWorkReadError.fileChanged
        }

        let document: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw KimiWorkReadError.malformed
            }
            document = parsed
        } catch { throw KimiWorkReadError.malformed }
        guard let credentials = document["credentials"] as? [String: Any],
              let code = credentials["kimiCode"] as? [String: Any],
              let web = credentials["kimiWeb"] as? [String: Any] else {
            throw KimiWorkReadError.missingCredentials
        }
        guard let endpoint = code["baseUrl"] as? String,
              endpoint == baseURL || endpoint == baseURL + "/" else {
            throw KimiWorkReadError.wrongEndpoint
        }
        guard let apiKey = credential(code["apiKey"]),
              let webToken = credential(web["accessToken"]),
              let userID = credential(web["userId"]) else {
            throw KimiWorkReadError.missingCredentials
        }
        let accountHash = digest("kimi-work-account\0" + userID)
        if let expectedAccountHash, expectedAccountHash != accountHash { throw KimiWorkReadError.accountChanged }
        return KimiWorkSession(apiKey: apiKey, webToken: webToken, accountHash: accountHash)
    }

    private static func attributes(of file: URL) throws -> [FileAttributeKey: Any] {
        do { return try FileManager.default.attributesOfItem(atPath: file.path) }
        catch { throw KimiWorkReadError.unavailable }
    }

    private static func credential(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else { return nil }
        return value
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
