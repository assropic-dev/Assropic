import Foundation

/// Resolves BridgeDock-owned credentials only for the private core configuration.
enum KimiWorkRouting {
    static func resolve(
        _ value: AppSettings,
        read: (String) throws -> KimiWorkSession
    ) -> AppSettings {
        var resolved = value
        for index in resolved.channels.indices where resolved.channels[index].isKimiWork {
            let channel = value.channels[index]
            resolved.channels[index].apiKey = ""
            guard channel.enabled else { continue }
            guard let session = session(for: channel, read: read) else {
                resolved.channels[index].enabled = false
                continue
            }
            resolved.channels[index].apiKey = session.apiKey
        }
        return resolved
    }

    /// Detects credential replacement without exposing tokens.
    static func fingerprint(
        _ value: AppSettings,
        read: (String) throws -> KimiWorkSession
    ) -> String {
        value.channels.filter { $0.isKimiWork && $0.enabled }.map { channel in
            let credential = session(for: channel, read: read)?.fingerprint ?? "unavailable"
            return channel.id + "\0" + credential
        }.sorted().joined(separator: "\n")
    }

    private static func session(
        for channel: Channel,
        read: (String) throws -> KimiWorkSession
    ) -> KimiWorkSession? {
        // Check the destination before touching the desktop's private configuration.
        guard channel.baseURL == KimiWorkSession.baseURL,
              channel.wire == .chat,
              !channel.desktopAccountHash.isEmpty else { return nil }
        guard let session = try? read(channel.desktopAccountHash),
              session.accountHash == channel.desktopAccountHash,
              !session.apiKey.isEmpty,
              !session.apiKey.contains(where: { $0.isWhitespace }) else { return nil }
        return session
    }
}
