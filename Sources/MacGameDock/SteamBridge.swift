import Foundation
import CryptoKit

struct SteamBridgeSetup {
    let owner: String
    let appID: Int
    let eventFile: URL
    let snapshot: SteamAchievementSnapshot
    var wineSavePath: String { "C:\\ProgramData\\MacGameDeck\\SteamBridge\\\(owner)" }
}
enum SteamBridgeInstaller {
    struct FileReceipt: Codable { let relative: String; let backup: String?; let installedHash: String }
    struct Receipt: Codable { let appID: Int; let backupDirectory: String; let files: [FileReceipt] }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func architecture(_ data: Data) throws -> String {
        guard data.count > 64, data[0] == 0x4d, data[1] == 0x5a else { throw DockError.message("La libreria Steam API non è un file Windows valido.") }
        let offset = Int(data[60]) | Int(data[61]) << 8 | Int(data[62]) << 16 | Int(data[63]) << 24
        guard offset >= 64, offset + 6 <= data.count, Array(data[offset..<offset+4]) == [0x50, 0x45, 0, 0] else { throw DockError.message("Intestazione Steam API non valida.") }
        let machine = Int(data[offset+4]) | Int(data[offset+5]) << 8
        switch machine { case 0x8664: return "x64"; case 0x14c: return "x86"; default: throw DockError.message("Architettura Steam API non supportata.") }
    }
    static func receiptURL(_ game: Game) throws -> URL {
        guard let directory = game.installDirectory else { throw DockError.message("Cartella del gioco mancante.") }
        return URL(fileURLWithPath: directory).appendingPathComponent(".MacGameDeck/steam-bridge.json")
    }
    static func checkedBackup(_ receipt: Receipt, root: URL) throws -> URL {
        let base = root.appendingPathComponent("SteamBridge/Backups/\(receipt.appID)").standardizedFileURL
        let folder = URL(fileURLWithPath: receipt.backupDirectory).standardizedFileURL
        guard folder.path.hasPrefix(base.path + "/"), UUID(uuidString: folder.lastPathComponent) != nil,
              receipt.files.allSatisfy({ $0.backup == nil || UInt($0.backup!) != nil }) else { throw DockError.message("Mappa di recupero Steam API non valida.") }
        try SteamCloudRestore.rejectSymlinks(folder)
        return folder
    }
    static func install(_ game: Game, snapshot: SteamAchievementSnapshot, root: URL, resources: URL? = nil) throws -> SteamBridgeSetup? {
        guard !game.isNative, let appID = game.steamAppID, let launch = game.managedLaunch, let directory = game.installDirectory else { return nil }
        try snapshot.validate(owner: snapshot.steamID, appID: appID)
        guard UInt64(snapshot.steamID) != nil else { throw DockError.message("Identità Steam non valida.") }
        let base = URL(fileURLWithPath: directory).standardizedFileURL
        try SteamCloudRestore.rejectSymlinks(base)
        let fm = FileManager.default
        guard let scan = fm.enumerator(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return nil }
        var libraries: [URL] = []
        for case let rawFile as URL in scan {
            let file = rawFile.standardizedFileURL
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if ["easyanticheat", "easyanticheat_eos", "battleye"].contains(file.lastPathComponent.lowercased()) { return nil }
            if values.isSymbolicLink == true { scan.skipDescendants(); continue }
            if values.isRegularFile == true, ["steam_api.dll", "steam_api64.dll"].contains(file.lastPathComponent.lowercased()) { libraries.append(file) }
            guard libraries.count <= 20 else { throw DockError.message("Troppe librerie Steam API nel gioco: integrazione non applicata.") }
        }
        guard !libraries.isEmpty else { return nil }
        let bundle = try resources ?? SteamResources.current().appendingPathComponent("SteamBridge")
        struct Manifest: Decodable { let files: [String: String] }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: bundle.appendingPathComponent("manifest.json")))
        let dataRoot = URL(fileURLWithPath: launch.prefix).appendingPathComponent("drive_c/ProgramData/MacGameDeck/SteamBridge/\(snapshot.steamID)")
        try SteamCloudRestore.rejectSymlinks(dataRoot)
        let eventFile = dataRoot.appendingPathComponent("\(appID)/achievements.json")
        try fm.createDirectory(at: eventFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Seed genuine Steam unlocks so existing trophies cannot generate new notifications.
        var earned: [String: [String: Any]] = [:]
        if let bytes = try? Data(contentsOf: eventFile), bytes.count <= 8_000_000, let existing = try? JSONSerialization.jsonObject(with: bytes) as? [String: [String: Any]] { earned = existing }
        for achievement in snapshot.achievements {
            let old = earned[achievement.name]
            earned[achievement.name] = ["earned": achievement.unlocked || (old?["earned"] as? Bool == true), "earned_time": max(achievement.unlockTime, (old?["earned_time"] as? NSNumber)?.uint32Value ?? 0)]
        }
        try JSONSerialization.data(withJSONObject: earned).write(to: eventFile, options: .atomic)
        let receiptFile = try receiptURL(game)
        let previous = (try? Data(contentsOf: receiptFile)).flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }
        if let previous { _ = try checkedBackup(previous, root: root) }
        let backup = root.appendingPathComponent("SteamBridge/Backups/\(appID)/\(UUID().uuidString)")
        try fm.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var modifications: [String: Data] = [:]
        for file in libraries {
            let original = try Data(contentsOf: file)
            let arch = try architecture(original)
            let name = arch == "x64" ? "steam_api64.dll" : "steam_api.dll"
            let resourceName = "\(arch)/\(name)"
            let payload = try Data(contentsOf: bundle.appendingPathComponent(resourceName))
            guard manifest.files[resourceName] == sha256(payload), try architecture(payload) == arch else { throw DockError.message("Integrità del ponte Steam API non valida.") }
            let relative = String(file.path.dropFirst(base.path.count + 1))
            modifications[relative] = payload
            let folder = file.deletingLastPathComponent()
            let prefix = folder.path == base.path ? "" : String(folder.path.dropFirst(base.path.count + 1)) + "/"
            let definitions: [[String: Any]] = snapshot.achievements.map { ["name": $0.name, "displayName": $0.title, "description": $0.description, "hidden": $0.hidden ? 1 : 0, "icon": "", "icon_gray": ""] }
            modifications[prefix + "steam_settings/achievements.json"] = try JSONSerialization.data(withJSONObject: definitions)
            let stats = snapshot.stats.filter { !$0.name.contains("\n") && !$0.name.contains("=") }.map { "\($0.name)=\($0.type)=\($0.defaultValue)" }.joined(separator: "\n")
            modifications[prefix + "steam_settings/stats.txt"] = Data(stats.utf8)
            modifications[prefix + "steam_settings/configs.user.ini"] = Data("[user::general]\naccount_steamid=\(snapshot.steamID)\naccount_name=MacGameDeck\nlanguage=english\n[user::saves]\nlocal_save_path=C:\\ProgramData\\MacGameDeck\\SteamBridge\\\(snapshot.steamID)\n".utf8)
            modifications[prefix + "steam_settings/configs.app.ini"] = Data("[app::dlcs]\nunlock_all=0\n".utf8)
            modifications[prefix + "steam_settings/configs.main.ini"] = Data("[main::connectivity]\ndisable_networking=1\noffline=0\n[main::general]\n".utf8)
            modifications[prefix + "steam_settings/configs.overlay.ini"] = Data("[overlay::general]\nenable_overlay=0\n".utf8)
            modifications[prefix + "steam_appid.txt"] = Data(String(appID).utf8)
        }
        var receipts: [FileReceipt] = []
        // Back up every original before applying any replacement, including originals from an earlier bridge install.
        for (relative, data) in modifications.sorted(by: { $0.key < $1.key }) {
            let target = try SteamCloudRestore.safeDestination(root: base, relative: relative)
            let index = String(receipts.count)
            var original: Data?
            if fm.fileExists(atPath: target.path) {
                let current = try Data(contentsOf: target)
                if let previous, previous.appID == appID, let entry = previous.files.first(where: { $0.relative == relative }), entry.installedHash == sha256(current) {
                    if let name = entry.backup { original = try Data(contentsOf: URL(fileURLWithPath: previous.backupDirectory).appendingPathComponent(name)) }
                } else { original = current }
            }
            if let original { try original.write(to: backup.appendingPathComponent(index), options: .atomic) }
            receipts.append(FileReceipt(relative: relative, backup: original == nil ? nil : index, installedHash: sha256(data)))
        }
        let receipt = Receipt(appID: appID, backupDirectory: backup.path, files: receipts)
        try fm.createDirectory(at: receiptFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Record the complete recovery map before writes; installation is reversible even after an interrupted app.
        try JSONEncoder().encode(receipt).write(to: receiptFile, options: .atomic)
        do {
            for entry in receipts {
                let target = try SteamCloudRestore.safeDestination(root: base, relative: entry.relative)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try modifications[entry.relative]!.write(to: target, options: .atomic)
            }
        } catch { try? restore(game, root: root); throw error }
        return SteamBridgeSetup(owner: snapshot.steamID, appID: appID, eventFile: eventFile, snapshot: snapshot)
    }
    static func restore(_ game: Game, root: URL) throws {
        let receiptFile = try receiptURL(game)
        guard let bytes = try? Data(contentsOf: receiptFile), let directory = game.installDirectory else { return }
        let receipt = try JSONDecoder().decode(Receipt.self, from: bytes)
        guard receipt.appID == game.steamAppID else { throw DockError.message("Backup Steam API di un altro gioco.") }
        let backup = try checkedBackup(receipt, root: root)
        let base = URL(fileURLWithPath: directory)
        for entry in receipt.files {
            let target = try SteamCloudRestore.safeDestination(root: base, relative: entry.relative)
            // Preserve files that an updater or the user changed after the bridge installation.
            if let current = try? Data(contentsOf: target), sha256(current) != entry.installedHash { continue }
            if let name = entry.backup { try Data(contentsOf: backup.appendingPathComponent(name)).write(to: target, options: .atomic) }
            else if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        }
        try FileManager.default.removeItem(at: receiptFile)
    }
}
