import Foundation

/// A remembered Steam session, readable only by the current macOS user.
/// No Keychain interaction is performed at launch or per download.
enum SessionStore {
    static func location(root: URL) -> URL { root.appendingPathComponent("Account/steam-session.json") }
    static func read(root: URL) throws -> SteamSession? {
        let file = location(root: root)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let bytes = try Data(contentsOf: file)
        guard bytes.count <= 8_000_000 else { throw DockError.message("Sessione Steam non valida.") }
        let value = try JSONDecoder().decode(SteamSession.self, from: bytes)
        guard SteamOpenID.validSteamID(value.steamID), !value.username.isEmpty, !value.account.isEmpty else { throw DockError.message("Sessione Steam incompleta. Ricollega l'account.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return value
    }
    static func save(_ session: SteamSession, root: URL) throws {
        let file = location(root: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.deletingLastPathComponent().path)
        try JSONEncoder().encode(session).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func delete(root: URL) throws {
        let file = location(root: root)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
