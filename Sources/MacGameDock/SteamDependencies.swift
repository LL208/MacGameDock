import Foundation
import CryptoKit

struct SteamDependency {
    let executable: URL
    let arguments: [String]
    let marker: URL
}
enum SteamDependencies {
    static func plan(in directory: URL) throws -> [SteamDependency] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var steps: [SteamDependency] = []
        for case let file as URL in enumerator {
            guard file.lastPathComponent.lowercased().contains("installscript"), file.pathExtension.lowercased() == "vdf" else { continue }
            let bytes = try Data(contentsOf: file)
            guard bytes.count < 8_000_000, let text = String(data: bytes, encoding: .utf8) else { throw DockError.message("Script delle dipendenze non leggibile.") }
            let values = try VDF.parse(text)
            let script = values.first(where: { $0.key.lowercased() == "installscript" })?.value.fields ?? values
            if script.keys.contains(where: { $0.lowercased() == "registry" }) {
                throw DockError.message("Il gioco richiede modifiche al registro dal suo script Steam: supporto non ancora disponibile. Download conservato.")
            }
            guard let processes = script.first(where: { $0.key.lowercased() == "run process" })?.value.fields else { continue }
            for (name, item) in processes.sorted(by: { $0.key < $1.key }) {
                guard let fields = item.fields else { throw DockError.message("Script delle dipendenze Steam non valido.") }
                let lower = Dictionary(fields.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
                let keys = lower.keys.filter { $0.hasPrefix("process") }.sorted()
                for key in keys {
                    guard let raw = lower[key]?.string, raw.lowercased().hasPrefix("%installdir%") else {
                        throw DockError.message("La dipendenza \(name) si trova fuori dai file del gioco: preparazione non ancora supportata.")
                    }
                    let relative = String(raw.dropFirst("%INSTALLDIR%".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
                    let executable = try DeckMetadata.contained(relative, in: directory)
                    guard FileManager.default.fileExists(atPath: executable.path), ["exe", "msi"].contains(executable.pathExtension.lowercased()) else {
                        throw DockError.message("Installer della dipendenza \(name) mancante.")
                    }
                    let suffix = key.dropFirst("process".count)
                    let command = lower["command" + suffix]?.string ?? ""
                    let args = try WindowsArguments.parse(command)
                    let digest = SHA256.hash(data: bytes + Data((name + key).utf8)).map { String(format: "%02x", $0) }.joined()
                    let marker = directory.appendingPathComponent(".MacGameDeck/dependencies/" + digest)
                    if !FileManager.default.fileExists(atPath: marker.path) {
                        steps.append(SteamDependency(executable: executable, arguments: args, marker: marker))
                    }
                }
            }
        }
        return steps
    }
}
