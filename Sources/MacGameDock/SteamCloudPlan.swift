import Foundation

// Validated cloud inventory and comparison rules.
struct SteamCloudInventory: Decodable {
    struct File: Decodable {
        let name: String
        let sha1: String
        let size: UInt64
        let timestamp: UInt64
        let state: Int
        let prefixIndex: Int
    }
    struct Node: Decodable {
        let name: String
        let value: String?
        let children: [Node]
        func child(_ key: String) -> Node? { children.first { $0.name.lowercased() == key.lowercased() } }
        func text(_ key: String) -> String? { child(key)?.value }
    }
    let ufs: Node?
    let schemaVersion: Int
    let steamID: String
    let appID: Int
    let changeNumber: String
    let isDelta: Bool
    let prefixes: [String]
    let files: [File]
    var liveFiles: [File] { files.filter { $0.state == 0 } }
    func validate(expectedAccount: String, expectedAppID: Int) throws {
        guard schemaVersion == 1, steamID == expectedAccount, appID == expectedAppID, !isDelta,
              UInt64(changeNumber) != nil, files.count <= 10000, prefixes.count <= 10000 else {
            throw DockError.message("Inventario cloud incompleto o appartenente a un altro account/gioco.")
        }
        var names = Set<String>()
        for file in files {
            guard !file.name.isEmpty, (0...2).contains(file.state), prefixes.isEmpty ? file.prefixIndex == 0 : prefixes.indices.contains(file.prefixIndex),
                  (file.state != 0 || file.sha1.count == 40), file.sha1.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw DockError.message("Metadati del salvataggio cloud non validi.")
            }
            let prefix = prefixes.isEmpty ? "" : prefixes[file.prefixIndex]
            let key = try Self.safeName(prefix + (prefix.isEmpty || prefix.hasSuffix("/") || prefix.hasSuffix("%") ? "" : "/") + file.name)
            guard names.insert(key).inserted else { throw DockError.message("Inventario cloud con nomi duplicati.") }
        }
    }
    static func safeName(_ input: String) throws -> String {
        let name = input.replacingOccurrences(of: "\\", with: "/")
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains(":"), !name.contains("\0"),
              !name.split(separator: "/").contains(".."), !name.split(separator: "/").contains(".") else {
            throw DockError.message("Percorso cloud non sicuro.")
        }
        return name
    }
}

struct CloudSaveVersion: Codable, Equatable {
    let hash: String?
}
enum CloudSaveAction: String, Codable {
    case unchanged, upload, download, conflict
}
struct CloudSaveDecision: Equatable {
    let path: String
    let action: CloudSaveAction
}
enum SteamCloudPlan {
    // A three-way comparison protects both initial imports and concurrent changes on another device.
    // A nil baseline value is an explicit known absence, unlike a missing baseline entry.
    static func compare(local: [String: CloudSaveVersion], remote: [String: CloudSaveVersion], baseline: [String: CloudSaveVersion]) throws -> [CloudSaveDecision] {
        let names = Set(local.keys).union(remote.keys).union(baseline.keys).sorted()
        return try names.map { path in
            _ = try SteamCloudInventory.safeName(path)
            let localHash = local[path]?.hash, remoteHash = remote[path]?.hash
            let action: CloudSaveAction
            if localHash == remoteHash { action = .unchanged }
            else if let previous = baseline[path] {
                let localChanged = localHash != previous.hash, remoteChanged = remoteHash != previous.hash
                // Deletions always need a deliberate resolution; never propagate them by inference.
                if localHash == nil || remoteHash == nil {
                    if previous.hash == nil, localHash != nil, remoteHash == nil { action = .upload }
                    else if previous.hash == nil, remoteHash != nil, localHash == nil { action = .download }
                    else { action = .conflict }
                } else if localChanged && !remoteChanged { action = .upload }
                else if remoteChanged && !localChanged { action = .download }
                else { action = .conflict }
            } else {
                // No baseline: two different copies must not be resolved using unreliable clocks.
                if localHash == nil { action = .download }
                else if remoteHash == nil { action = .upload }
                else { action = .conflict }
            }
            return CloudSaveDecision(path: path, action: action)
        }
    }
}


enum SteamCloudDiagnostic {
    static func message(code: String, errorType: String? = nil) -> String {
        let reason: String
        switch code {
        case "cloud_changed": reason = "Il salvataggio cloud è cambiato durante la verifica. Le copie sono conservate; riprova la sincronizzazione."
        case "upload_unconfirmed": reason = "Steam non ha confermato l’invio del salvataggio. La copia locale e il backup sono conservati."
        case "hash_mismatch": reason = "Il file scaricato non corrisponde al salvataggio cloud."
        case "unsupported_transfer": reason = "Steam usa un formato di trasferimento cloud non ancora supportato."
        case "partial_inventory": reason = "Steam ha restituito un inventario parziale; il confronto dei salvataggi non è possibile."
        case "steam_AccessDenied", "steam_InsufficientPrivilege": reason = "Steam non ha autorizzato l'accesso al cloud di questo gioco."
        case "steam_FileNotFound", "steam_NoMatch": reason = "Steam non ha trovato salvataggi cloud per questo gioco."
        case "steam_Timeout", "steam_ServiceUnavailable", "steam_NoConnection": reason = "Il servizio Steam Cloud non è raggiungibile. Riprova più tardi."
        default:
            let safeType = errorType.flatMap { $0.count <= 80 && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) ? $0 : nil }
            reason = "Verifica Steam Cloud fallita" + (safeType.map { " (" + $0 + ")" } ?? "") + "."
        }
        return reason + " Nessun salvataggio è stato modificato."
    }
}
