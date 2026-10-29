import Foundation
import CryptoKit
import Darwin

struct SteamPlayerSnapshot: Codable {
    let steamID: String
    let appID: Int
    let minutes: Int?
    let unlocked: Int?
    let total: Int?
    let fetchedAt: Int64
}

enum SteamCloudMappingError: Error { case outsideDeclaredPatterns }

// Only declared Auto-Cloud locations are restored. SDK-only saves need a Steam API bridge.
enum SteamCloudRestore {
    struct Entry: Encodable {
        let name: String
        let sha1: String
        let size: UInt64
        let timestamp: UInt64
        let destination: URL
        let previousHash: String?
        enum CodingKeys: String, CodingKey { case name, sha1, size, timestamp }
    }
    static func hash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var digest = Insecure.SHA1()
        while let data = try handle.read(upToCount: 65536), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func rejectSymlinks(_ url: URL) throws {
        var part = url.standardizedFileURL
        while part.path != "/" {
            if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: part.path) {
                // macOS system aliases do not come from a game/container.
                if ["/var": "private/var", "/tmp": "private/tmp", "/etc": "private/etc"][part.path] == link { break }
                throw DockError.message("Il percorso del salvataggio contiene un collegamento simbolico.")
            }
            part.deleteLastPathComponent()
        }
    }
    static func safeDestination(root: URL, relative: String) throws -> URL {
        let name = try SteamCloudInventory.safeName(relative)
        try rejectSymlinks(root.appendingPathComponent(name))
        let base = root.standardizedFileURL
        let url = base.appendingPathComponent(name).standardizedFileURL
        guard url.path.hasPrefix(base.path + "/"), url.resolvingSymlinksInPath().path == url.path,
              base.resolvingSymlinksInPath().path == base.path else { throw DockError.message("Il percorso del salvataggio esce dal container o contiene collegamenti simbolici.") }
        return url
    }
    static func wineUser(prefix: URL) throws -> URL {
        let users = prefix.appendingPathComponent("drive_c/users")
        let folders = try FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: [.isDirectoryKey]).filter {
            !["public", "all users", "default", "default user"].contains($0.lastPathComponent.lowercased()) && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        // Migrating from CrossOver can leave its old profile next to Wine's active profile.
        // Use Wine's declared USERPROFILE rather than choosing an arbitrary folder.
        if let text = try? String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8) {
            var section = ""
            for line in text.components(separatedBy: .newlines) {
                if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                    section = String(line[line.index(after: line.startIndex)..<end]).replacingOccurrences(of: "\\\\", with: "\\").lowercased()
                }
                guard section == "volatile environment", line.hasPrefix("\"USERPROFILE\"=\""), line.hasSuffix("\"") else { continue }
                let path = String(line.dropFirst(15).dropLast()).replacingOccurrences(of: "\\\\", with: "\\")
                let parts = path.components(separatedBy: "\\")
                if parts.count == 3, parts[0].lowercased() == "c:", parts[1].lowercased() == "users", ![".", ".."].contains(parts[2]),
                   let active = folders.first(where: { $0.lastPathComponent.caseInsensitiveCompare(parts[2]) == .orderedSame }) {
                    try rejectSymlinks(active); return active
                }
                throw DockError.message("Il profilo utente dichiarato da Wine non è valido.")
            }
        }
        guard folders.count == 1, let user = folders.first else { throw DockError.message("Profilo Wine ambiguo: impossibile individuare automaticamente i salvataggi.") }
        try rejectSymlinks(user); return user
    }
    static func destination(_ remote: String, game: Game, inventory: SteamCloudInventory, validatePattern: Bool = true) throws -> URL {
        guard let launch = game.managedLaunch else { throw DockError.message("Container del gioco non disponibile per Steam Cloud.") }
        let platform = game.isNative ? "macos" : "windows"
        var roots: [String: URL] = [:]
        roots["GameInstall"] = URL(fileURLWithPath: game.installDirectory ?? launch.workingDirectory)
        if !game.isNative {
            let prefix = URL(fileURLWithPath: launch.prefix)
            let user = try wineUser(prefix: prefix)
            for (key, path) in ["WinAppDataRoaming": "AppData/Roaming", "WinAppDataLocal": "AppData/Local", "WinAppDataLocalLow": "AppData/LocalLow", "WinMyDocuments": "Documents", "WinSavedGames": "Saved Games", "WinUserProfile": ""] {
                roots[key] = user.appendingPathComponent(path).standardizedFileURL
            }
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            roots["MacHome"] = home; roots["MacAppSupport"] = home.appendingPathComponent("Library/Application Support")
            roots["MacDocuments"] = home.appendingPathComponent("Documents")
        }
        var mappings: [(String, URL)] = roots.map { ("%\($0.key)%", $0.value) }
        // Steam keeps the original cloud root even when a platform override changes the local root/path.
        for override in inventory.ufs?.child("rootoverrides")?.children ?? [] {
            guard override.text("os")?.lowercased() == platform || (platform == "macos" && override.text("os") == "osx") else { continue }
            guard let original = override.text("root"), let alternate = override.text("useinstead"), let root = roots.first(where: { $0.key.caseInsensitiveCompare(alternate) == .orderedSame })?.value else {
                throw DockError.message("Questo gioco usa un percorso Steam Cloud non ancora supportato su questa piattaforma.")
            }
            let add = substitute(override.text("addpath") ?? "", account: inventory.steamID)
            let local = add.isEmpty ? root : try safeDestination(root: root, relative: add)
            mappings.removeAll { $0.0.caseInsensitiveCompare("%\(original)%") == .orderedSame }; mappings.append(("%\(original)%", local))
            if !(override.child("pathtransforms")?.children ?? []).isEmpty {
                throw DockError.message("Questo gioco richiede trasformazioni del percorso cloud non ancora supportate.")
            }
        }
        let normalized = try SteamCloudInventory.safeName(remote)
        guard let mapping = mappings.sorted(by: { $0.0.count > $1.0.count }).first(where: { normalized.lowercased().hasPrefix($0.0.lowercased()) }) else {
            throw DockError.message("Steam non ha indicato un percorso Auto-Cloud riconoscibile per questo salvataggio. Il gioco usa il cloud tramite Steam API: il ripristino diretto non è ancora supportato.")
        }
        let suffix = String(normalized.dropFirst(mapping.0.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relative = substitute(suffix, account: inventory.steamID)
        _ = try SteamCloudInventory.safeName(relative)
        let rootName = mapping.0.trimmingCharacters(in: CharacterSet(charactersIn: "%"))
        let allowed = (inventory.ufs?.child("savefiles")?.children ?? []).contains { rule in
            guard rule.text("root")?.caseInsensitiveCompare(rootName) == .orderedSame else { return false }
            let folder = substitute(rule.text("path") ?? "", account: inventory.steamID).replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let prefix = folder.isEmpty ? "" : folder + "/"
            guard relative.hasPrefix(prefix) else { return false }
            let tail = String(relative.dropFirst(prefix.count))
            guard rule.text("recursive") == "1" || !tail.contains("/") else { return false }
            return fnmatch(rule.text("pattern") ?? "*", URL(fileURLWithPath: tail).lastPathComponent, 0) == 0
        }
        guard !validatePattern || allowed else { throw SteamCloudMappingError.outsideDeclaredPatterns }
        return try safeDestination(root: mapping.1, relative: relative)
    }
    static func substitute(_ value: String, account: String) -> String {
        value.replacingOccurrences(of: "{64BitSteamID}", with: account)
            .replacingOccurrences(of: "{Steam3AccountID}", with: String((UInt64(account) ?? 0) & 0xffffffff))
    }
    static func plan(_ inventory: SteamCloudInventory, game: Game, now: Date = Date()) throws -> [Entry] {
        var result: [Entry] = []; var destinations = Set<String>()
        for file in inventory.files where file.state == 0 {
            let prefix = inventory.prefixes.isEmpty ? "" : inventory.prefixes[file.prefixIndex]
            let name = prefix + (prefix.isEmpty || prefix.hasSuffix("/") || prefix.hasSuffix("%") ? "" : "/") + file.name
            let target: URL
            do { target = try destination(name, game: game, inventory: inventory) }
            catch SteamCloudMappingError.outsideDeclaredPatterns { continue } // SDK entries are listed but have no declared local save location.
            guard destinations.insert(target.path.lowercased()).inserted else { throw DockError.message("Due salvataggi cloud usano lo stesso percorso locale.") }
            let exists = FileManager.default.fileExists(atPath: target.path)
            let previous = exists ? try hash(target) : nil
            if previous == file.sha1.lowercased() { continue }
            let remoteDate = Date(timeIntervalSince1970: TimeInterval(file.timestamp))
            guard file.timestamp > 0, remoteDate <= now.addingTimeInterval(300), file.size <= 268435456 else { throw DockError.message("Data o dimensione del salvataggio cloud non valida. Le copie locali sono conservate.") }
            if exists {
                let info = try target.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard info.isRegularFile == true, let localDate = info.contentModificationDate, localDate.timeIntervalSince1970 > 0, localDate <= now.addingTimeInterval(300) else { throw DockError.message("Data del salvataggio locale non affidabile. Le copie sono conservate.") }
                if localDate > remoteDate { continue }
                if abs(localDate.timeIntervalSince(remoteDate)) < 1 { throw DockError.message("Due salvataggi diversi hanno la stessa data: avvio sospeso per evitare di perdere progressi.") }
            }
            result.append(Entry(name: name, sha1: file.sha1, size: file.size, timestamp: file.timestamp, destination: target, previousHash: previous))
        }
        return result
    }
    static func apply(_ entries: [Entry], staging: URL, backups: URL) throws {
        let fm = FileManager.default
        // Validate the entire download and recheck local files before making any change.
        for (index, entry) in entries.enumerated() {
            let source = staging.appendingPathComponent("\(index).save")
            try rejectSymlinks(entry.destination)
            try rejectSymlinks(source)
            guard try hash(source) == entry.sha1.lowercased(), (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(entry.size),
                  entry.destination.resolvingSymlinksInPath().path == entry.destination.path,
                  (fm.fileExists(atPath: entry.destination.path) ? try hash(entry.destination) : nil) == entry.previousHash else {
                throw DockError.message("Il salvataggio è cambiato durante il download o la verifica non è riuscita. Nessun file è stato sostituito.")
            }
        }
        try fm.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        struct Receipt: Encodable { let target: String; let backup: String? }
        let receipts = entries.enumerated().map { Receipt(target: $0.element.destination.path, backup: $0.element.previousHash == nil ? nil : "\($0.offset).save") }
        try JSONEncoder().encode(receipts).write(to: backups.appendingPathComponent("restore.json"), options: .atomic)
        for (index, entry) in entries.enumerated() where entry.previousHash != nil { try fm.copyItem(at: entry.destination, to: backups.appendingPathComponent("\(index).save")) }
        var changed: [Int] = []
        do {
            for (index, entry) in entries.enumerated() {
                try fm.createDirectory(at: entry.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: staging.appendingPathComponent("\(index).save")).write(to: entry.destination, options: .atomic)
                changed.append(index)
                try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(entry.timestamp))], ofItemAtPath: entry.destination.path)
            }
        } catch {
            for index in changed.reversed() {
                let entry = entries[index]
                if entry.previousHash != nil { if let original = try? Data(contentsOf: backups.appendingPathComponent("\(index).save")) { try? original.write(to: entry.destination, options: .atomic)
                    if let attributes = try? fm.attributesOfItem(atPath: backups.appendingPathComponent("\(index).save").path), let date = attributes[.modificationDate] { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: entry.destination.path) }
                } }
                else { try? fm.removeItem(at: entry.destination) }
            }
            throw DockError.message("Ripristino cloud interrotto. Le copie originali sono disponibili nella cartella di backup: \(backups.path).")
        }
    }
}
