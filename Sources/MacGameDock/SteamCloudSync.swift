import Foundation
import Darwin

struct CloudSyncSession: Codable {
    let owner: String
    let appID: Int
    let gameID: UUID
    let remote: [String: String]
    let created: Date
}
enum CloudSyncFiles {
    static func name(_ file: SteamCloudInventory.File, in inventory: SteamCloudInventory) -> String {
        let prefix = inventory.prefixes.isEmpty ? "" : inventory.prefixes[file.prefixIndex]
        return prefix + (prefix.isEmpty || prefix.hasSuffix("/") || prefix.hasSuffix("%") ? "" : "/") + file.name
    }
    static func remote(_ inventory: SteamCloudInventory) throws -> [String: String] {
        var result: [String: String] = [:]
        for file in inventory.liveFiles { let name = try SteamCloudInventory.safeName(name(file, in: inventory)); result[name] = file.sha1.lowercased() }
        return result
    }
    // Enumerate only declared Auto-Cloud rules. Never infer paths for SDK-only saves.
    static func local(_ inventory: SteamCloudInventory, game: Game) throws -> [String: URL] {
        var result: [String: URL] = [:]; var destinations: [String: String] = [:]
        for rule in inventory.ufs?.child("savefiles")?.children ?? [] {
            guard let root = rule.text("root"), let pattern = rule.text("pattern"), !pattern.contains("/"), !pattern.contains("\\") else { continue }
            let folder = SteamCloudRestore.substitute(rule.text("path") ?? "", account: inventory.steamID).replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !folder.isEmpty || root.caseInsensitiveCompare("GameInstall") == .orderedSame else { throw DockError.message("Percorso Auto-Cloud troppo ampio: nessun file personale viene inviato automaticamente.") }
            guard !folder.contains("*"), !folder.contains("?") else { throw DockError.message("Il percorso Auto-Cloud contiene un pattern non supportato.") }
            let cloudFolder = "%\(root)%" + (folder.isEmpty ? "" : folder + "/")
            let probe = try SteamCloudRestore.destination(cloudFolder + "MacGameDeck-probe", game: game, inventory: inventory, validatePattern: false)
            let directory = probe.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            try SteamCloudRestore.rejectSymlinks(directory)
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey], options: []) else { continue }
            var count = 0
            for case let file as URL in enumerator {
                count += 1; guard count <= 10000 else { throw DockError.message("Troppi file nel percorso dei salvataggi.") }
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
                guard info.isSymbolicLink != true else { throw DockError.message("Il percorso dei salvataggi contiene un collegamento simbolico.") }
                if info.isDirectory == true { if rule.text("recursive") != "1" { enumerator.skipDescendants() }; continue }
                guard info.isRegularFile == true, fnmatch(pattern, file.lastPathComponent, 0) == 0 else { continue }
                let basePath = directory.resolvingSymlinksInPath().path
                let filePath = file.resolvingSymlinksInPath().path
                guard filePath.hasPrefix(basePath + "/") else { throw DockError.message("Il salvataggio esce dalla cartella dichiarata.") }
                let relative = String(filePath.dropFirst(basePath.count + 1))
                let name = try SteamCloudInventory.safeName(cloudFolder + relative)
                let validated = try SteamCloudRestore.destination(name, game: game, inventory: inventory)
                guard validated.resolvingSymlinksInPath() == file.resolvingSymlinksInPath() else { throw DockError.message("Percorso cloud ambiguo.") }
                if let existing = destinations[file.path.lowercased()], existing != name { throw DockError.message("Due regole cloud puntano allo stesso file.") }
                destinations[file.path.lowercased()] = name; result[name] = file
            }
        }
        // Preserve the exact names Steam already uses, including optional separators after root tokens.
        for remote in inventory.liveFiles {
            let name = try SteamCloudInventory.safeName(name(remote, in: inventory))
            guard let target = try? SteamCloudRestore.destination(name, game: game, inventory: inventory), FileManager.default.fileExists(atPath: target.path) else { continue }
            result = result.filter { $0.value.resolvingSymlinksInPath() != target.resolvingSymlinksInPath() }; result[name] = target
        }
        return result
    }
    static func uploads(local: [String: String], remote: [String: String], baseline: [String: String]) throws -> [String] {
        var uploads: [String] = []
        for (name, hash) in local {
            _ = try SteamCloudInventory.safeName(name)
            if hash == remote[name] { continue }
            guard remote[name] == baseline[name] else { throw DockError.message("Conflitto cloud per \(name): un altro dispositivo ha modificato il salvataggio. Le copie locali e remote sono conservate.") }
            uploads.append(name)
        }
        return uploads.sorted()
    }
}
extension ManagedSteam {
    func cloudSessionURL(owner: String, appID: Int) -> URL { root.appendingPathComponent("Cloud/Pending/\(owner)/\(appID).json") }
    func captureCloudSession(_ inventory: SteamCloudInventory, game: Game, replacingExisting: Bool = false) throws {
        let target = cloudSessionURL(owner: inventory.steamID, appID: inventory.appID)
        // A previous unsent session keeps its original remote baseline across restarts.
        if !replacingExisting, FileManager.default.fileExists(atPath: target.path) { return }
        _ = try CloudSyncFiles.local(inventory, game: game)
        let value = CloudSyncSession(owner: inventory.steamID, appID: inventory.appID, gameID: game.id, remote: try CloudSyncFiles.remote(inventory), created: Date())
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: target, options: .atomic)
    }
    func uploadCloudAfterPlay(_ game: Game, expected: String) async throws -> Int {
        guard let appID = game.steamAppID else { return 0 }
        let receipt = cloudSessionURL(owner: expected, appID: appID)
        guard FileManager.default.fileExists(atPath: receipt.path) else { return 0 }
        let session = try JSONDecoder().decode(CloudSyncSession.self, from: Data(contentsOf: receipt))
        guard session.owner == expected, session.appID == appID, session.gameID == game.id else { throw DockError.message("Sessione cloud appartenente a un altro gioco o account.") }
        let inventory = try await cloudInventory(game, expected: expected)
        let local = try CloudSyncFiles.local(inventory, game: game)
        let hashes = try local.mapValues { try SteamCloudRestore.hash($0) }
        let names = try CloudSyncFiles.uploads(local: hashes, remote: CloudSyncFiles.remote(inventory), baseline: session.remote)
        guard !names.isEmpty else { try FileManager.default.removeItem(at: receipt); return 0 }
        let stage = root.appendingPathComponent("Cloud/Uploads/\(expected)/\(appID)/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Keep upload snapshots as recovery backups, including on network failure.
        struct Upload: Encodable { let name: String; let sha1: String; let size: UInt64; let timestamp: UInt64; let source: String }
        struct Request: Encodable { let steamID: String; let appID: Int; let changeNumber: String; let files: [Upload] }
        var files: [Upload] = []
        for (index, name) in names.enumerated() {
            guard let source = local[name], let hash = hashes[name] else { continue }
            try SteamCloudRestore.rejectSymlinks(source)
            let info = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard info.isRegularFile == true, let size = info.fileSize, size <= 268435456, let date = info.contentModificationDate,
                  date.timeIntervalSince1970 > 0, date <= Date().addingTimeInterval(300) else { throw DockError.message("Data o dimensione del salvataggio locale non valida.") }
            let copy = stage.appendingPathComponent("\(index).save")
            try FileManager.default.copyItem(at: source, to: copy)
            guard try SteamCloudRestore.hash(copy) == hash, try SteamCloudRestore.hash(source) == hash else { throw DockError.message("Il salvataggio è cambiato durante la preparazione. Riprova dopo la chiusura del gioco.") }
            files.append(Upload(name: name, sha1: hash, size: UInt64(size), timestamp: UInt64(date.timeIntervalSince1970), source: copy.lastPathComponent))
        }
        let request = stage.appendingPathComponent("request.json")
        try JSONEncoder().encode(Request(steamID: expected, appID: appID, changeNumber: inventory.changeNumber, files: files)).write(to: request, options: .atomic)
        _ = try await run(["-app", String(appID), "-deck-cloud-upload", request.path], expected: expected)
        let verified = try CloudSyncFiles.remote(await cloudInventory(game, expected: expected))
        guard files.allSatisfy({ verified[$0.name] == $0.sha1 }) else { throw DockError.message("Steam non ha ancora confermato tutti i salvataggi. Le copie locali e i backup sono conservati.") }
        try FileManager.default.removeItem(at: receipt)
        return files.count
    }
    func resolveCloudConflict(_ game: Game, expected: String, keepLocal: Bool) async throws {
        let inventory = try await cloudInventory(game, expected: expected)
        var entries: [SteamCloudRestore.Entry] = []
        for file in inventory.liveFiles {
            let name = CloudSyncFiles.name(file, in: inventory)
            guard let target = try? SteamCloudRestore.destination(name, game: game, inventory: inventory) else { continue }
            guard file.size <= 268435456, file.timestamp > 0, Double(file.timestamp) <= Date().timeIntervalSince1970 + 300 else { throw DockError.message("Metadati cloud non validi.") }
            let previous = FileManager.default.fileExists(atPath: target.path) ? try SteamCloudRestore.hash(target) : nil
            entries.append(SteamCloudRestore.Entry(name: name, sha1: file.sha1, size: file.size, timestamp: file.timestamp, destination: target, previousHash: previous))
        }
        guard !entries.isEmpty else { throw DockError.message("Nessun salvataggio Auto-Cloud supportato da confrontare.") }
        let backup = root.appendingPathComponent("Cloud/Backups/\(expected)/\(inventory.appID)/Conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let request = backup.appendingPathComponent("request.json")
        try JSONEncoder().encode(entries).write(to: request, options: .atomic)
        // Download the remote originals before either deliberate resolution.
        _ = try await run(["-app", String(inventory.appID), "-deck-cloud-download", request.path, "-deck-cloud-directory", backup.path], expected: expected)
        for (index, entry) in entries.enumerated() {
            guard try SteamCloudRestore.hash(backup.appendingPathComponent("\(index).save")) == entry.sha1.lowercased() else { throw DockError.message("Backup cloud non verificato: nessuna copia sostituita.") }
        }
        if !keepLocal { try SteamCloudRestore.apply(entries, staging: backup, backups: backup.appendingPathComponent("LocalBeforeResolution")) }
        try captureCloudSession(inventory, game: game, replacingExisting: true)
        if keepLocal { _ = try await uploadCloudAfterPlay(game, expected: expected) }
    }

}
