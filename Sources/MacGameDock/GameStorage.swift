import Foundation

// Managed installation paths only. Moving an installation never deletes its original copy.
enum GameStorage {
    static func container(appID: Int, root: URL, selected: String?) throws -> URL {
        guard let selected else { return root.appendingPathComponent("Containers/Steam/\(appID)") }
        let base = URL(fileURLWithPath: selected, isDirectory: true)
        var directory: ObjCBool = false
        guard base.path.hasPrefix("/"), FileManager.default.fileExists(atPath: base.path, isDirectory: &directory), directory.boolValue else { throw DockError.message("Il disco scelto non è disponibile. Collegalo o scegli un’altra cartella nelle impostazioni.") }
        try SteamCloudRestore.rejectSymlinks(base)
        return base.appendingPathComponent("MacGameDeck/Steam/\(appID)")
    }
    static func available(at url: URL) -> Int64? {
        var current = url
        while !FileManager.default.fileExists(atPath: current.path), current.path != "/" { current.deleteLastPathComponent() }
        if let capacity = try? current.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage { return capacity }
        return (try? FileManager.default.attributesOfFileSystem(forPath: current.path)[.systemFreeSize]) as? Int64
    }
    static func remap(_ path: String, from source: URL, to target: URL) throws -> String {
        let base = source.standardizedFileURL.path
        guard path == base || path.hasPrefix(base + "/") else { throw DockError.message("Il percorso del gioco non appartiene al container selezionato.") }
        return target.standardizedFileURL.path + path.dropFirst(base.count)
    }
    static func copyVerified(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try SteamCloudRestore.rejectSymlinks(source)
        try SteamCloudRestore.rejectSymlinks(destination)
        let src = source.resolvingSymlinksInPath().path, dst = destination.resolvingSymlinksInPath().path
        guard dst != src, !dst.hasPrefix(src + "/"), !src.hasPrefix(dst + "/"), !fm.fileExists(atPath: destination.path) else { throw DockError.message("Scegli una destinazione vuota, esterna al container originale.") }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".Moving-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        guard let files = fm.enumerator(at: source.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw DockError.message("Container non leggibile.") }
        for case let file as URL in files {
            try Task.checkCancellation()
            let relative: String
            // Wine's dosdevices links may intentionally point outside; compare the link itself.
            let lexical = file.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent).path
            let base = src
            if lexical.hasPrefix(base + "/") { relative = String(lexical.dropFirst(base.count + 1)) }
            else { throw DockError.message("Percorso del container non valido.") }
            let copy = staging.appendingPathComponent(relative)
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if info.isSymbolicLink == true {
                guard try fm.destinationOfSymbolicLink(atPath: file.path) == fm.destinationOfSymbolicLink(atPath: copy.path) else { throw DockError.message("Verifica dei collegamenti Wine non riuscita.") }
            } else if info.isRegularFile == true {
                guard try SteamCloudRestore.hash(file) == SteamCloudRestore.hash(copy) else { throw DockError.message("Verifica della copia del gioco non riuscita. L’originale è conservato.") }
            }
        }
        try fm.moveItem(at: staging, to: destination)
    }
}
