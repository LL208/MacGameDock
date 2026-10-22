import Foundation

@MainActor
final class AppDiagnostics {
    let root: URL
    var file: URL { root.appendingPathComponent("Logs/application.log") }
    init(root: URL) { self.root = root }
    static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)(\"?(?:password|access_token|refresh_token|authorization|token)\"?)(\s*[=:]\s*)(Bearer\s+[^\s&]+|\"[^\"]*\"|[^\s&]+)"#, with: "$1$2[omesso]", options: .regularExpression)
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
    func write(_ category: String, _ message: String, game: Game? = nil) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] [\(category)] " + (game.map { "\($0.title): " } ?? "") + String(message.prefix(4000)) + "\n"
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 1_000_000 {
                let previous = file.deletingLastPathComponent().appendingPathComponent("application.previous.log")
                try? FileManager.default.removeItem(at: previous)
                try FileManager.default.moveItem(at: file, to: previous)
            }
            if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file, options: .atomic) }
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: Data(Self.redact(line).utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* Diagnostics must never prevent a game from launching. */ }
    }
    static func componentLogs(for game: Game) -> [URL] {
        guard !game.isNative, let launch = game.managedLaunch, !launch.prefix.isEmpty else { return [] }
        let prefix = URL(fileURLWithPath: launch.prefix)
        guard let users = try? DeckMetadata.contained("drive_c/users", in: prefix),
              let folders = try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return [] }
        var logs: [URL] = []
        for user in folders {
            guard (try? user.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            for relative in ["Temp", "AppData/Local/Temp", "Local Settings/Temp"] {
                guard let folder = try? DeckMetadata.contained(relative, in: user),
                      let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]) else { continue }
                for file in files where file.lastPathComponent.lowercased().hasPrefix("dd_vcredist") && file.pathExtension.lowercased() == "log" {
                    guard let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]), values.isSymbolicLink != true, values.isRegularFile == true else { continue }
                    logs.append(file)
                }
            }
        }
        return Array(logs.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }.prefix(3))
    }
    static func tail(_ file: URL, limit: Int = 262144) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > UInt64(limit) ? size - UInt64(limit) : 0)
        let bytes = try handle.read(upToCount: limit) ?? Data()
        return (size > UInt64(limit) ? "… Mostrate le ultime righe del log …\n" : "") + redact(String(decoding: bytes, as: UTF8.self))
    }
}
