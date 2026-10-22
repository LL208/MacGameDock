import Foundation
import CryptoKit

struct SteamDependency {
    let name: String
    let executable: URL
    let arguments: [String]
    let marker: URL
    let redistGroup: String?
    var isModernVisualCPP: Bool {
        guard let group = redistGroup else { return false }
        let parts = group.lowercased().split(separator: "/")
        return parts.count == 3 && parts[1] == "vcredist" && (Int(parts[2]) ?? 0) >= 2015
    }
    var isAvailable: Bool { FileManager.default.fileExists(atPath: executable.path) }
    var wineArguments: [String] {
        let path = Self.windowsPath(executable)
        switch executable.pathExtension.lowercased() {
        case "msi": return ["msiexec", "/i", path] + arguments
        case "cmd", "bat": return ["cmd", "/d", "/c", path] + arguments
        default: return [path] + arguments
        }
    }
    static func windowsPath(_ url: URL) -> String { "Z:" + url.path.replacingOccurrences(of: "/", with: "\\") }
}

enum SteamDependencies {
    static func plan(in directory: URL, allowMissing: Bool = false, prefix: URL? = nil) throws -> [SteamDependency] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent.lowercased().contains("installscript") && $0.pathExtension.lowercased() == "vdf" }.sorted { $0.path < $1.path }
        var steps: [SteamDependency] = []
        for file in files {
            _ = try DeckMetadata.contained(String(file.path.dropFirst(directory.path.count + 1)), in: directory)
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
                // Exclude process-related flags; only process N denotes an installer.
                let keys = lower.keys.filter { $0 == "process" || $0.range(of: #"^process\s+\d+$"#, options: .regularExpression) != nil }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                for key in keys {
                    guard let raw = lower[key]?.string else { throw DockError.message("Script della dipendenza \(name) non valido.") }
                    let suffix = key.dropFirst("process".count)
                    let command = lower["command" + suffix]?.string ?? ""
                    var args = try WindowsArguments.parse(command, allowPlaceholders: true)
                    var executable: URL
                    if ["msiexec", "msiexec.exe"].contains(raw.lowercased()) {
                        guard let i = args.firstIndex(where: { ["/i", "/package"].contains($0.lowercased()) }), i + 1 < args.count else { throw DockError.message("Pacchetto MSI di \(name) non specificato.") }
                        executable = try installer(args[i + 1], directory: directory)
                        guard executable.pathExtension.lowercased() == "msi" else { throw DockError.message("Pacchetto MSI non valido.") }
                        args.removeSubrange(i...i + 1)
                    } else { executable = try installer(raw, directory: directory) }
                    if ["cmd", "bat"].contains(executable.pathExtension.lowercased()), FileManager.default.fileExists(atPath: executable.path),
                       let wrapper = try simpleSteamWrapper(executable) {
                        executable = wrapper.0
                        args = wrapper.1 + args
                    }
                    guard ["exe", "msi", "cmd", "bat"].contains(executable.pathExtension.lowercased()) else { throw DockError.message("Formato dell'installer \(name) non supportato.") }
                    for index in args.indices where args[index].contains("%") {
                        guard args[index].lowercased().hasPrefix("%installdir%") else { throw DockError.message("Parametro della dipendenza \(name) non risolto.") }
                        args[index] = SteamDependency.windowsPath(try installer(args[index], directory: directory))
                    }
                    let relative = String(executable.path.dropFirst(directory.path.count + 1)).replacingOccurrences(of: "\\", with: "/")
                    let components = relative.split(separator: "/").map(String.init)
                    let group = components.count >= 4 && components[0].lowercased() == "_commonredist" ? components.prefix(3).joined(separator: "/") : nil
                    let label = group.map { $0.split(separator: "/").dropFirst().joined(separator: " ") + " · " + name } ?? name
                    let digest = SHA256.hash(data: bytes + Data((name + key).utf8)).map { String(format: "%02x", $0) }.joined()
                    let marker = (prefix ?? directory).appendingPathComponent(".MacGameDeck/dependencies/" + digest)
                    if !FileManager.default.fileExists(atPath: marker.path) {
                        if !allowMissing && !FileManager.default.fileExists(atPath: executable.path) { throw DockError.message("Installer di \(label) mancante: recupero automatico necessario.") }
                        steps.append(SteamDependency(name: label, executable: executable, arguments: args, marker: marker, redistGroup: group))
                    }
                }
            }
        }
        return steps
    }
    // Steam's standard redistributable wrappers only launch a local installer and normalize reboot status.
    // Resolve those directly so paths with spaces and payload availability do not depend on cmd quoting.
    private static func simpleSteamWrapper(_ file: URL) throws -> (URL, [String])? {
        let data = try Data(contentsOf: file)
        guard data.count <= 65536, let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard lines.count == 4, lines[0].uppercased() == "@ECHO OFF",
              lines[2].uppercased() == "IF %ERRORLEVEL% == 3010 EXIT /B 0",
              lines[3].uppercased() == "EXIT /B %ERRORLEVEL%" else { return nil }
        let regex = try NSRegularExpression(pattern: #"^start /w "" "%~dp0[\\/]([^"\r\n]+)"\s*(.*)$"#, options: [.caseInsensitive])
        let line = lines[1]
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let nameRange = Range(match.range(at: 1), in: line), let argsRange = Range(match.range(at: 2), in: line) else { return nil }
        let executable = try DeckMetadata.contained(String(line[nameRange]), in: file.deletingLastPathComponent())
        guard ["exe", "msi"].contains(executable.pathExtension.lowercased()) else { return nil }
        return (executable, try WindowsArguments.parse(String(line[argsRange])))
    }
    private static func installer(_ raw: String, directory: URL) throws -> URL {
        guard raw.lowercased().hasPrefix("%installdir%") else { throw DockError.message("Percorso della dipendenza fuori dai file del gioco: preparazione non supportata.") }
        let relative = String(raw.dropFirst("%INSTALLDIR%".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
        return try DeckMetadata.contained(relative, in: directory)
    }
    static func missingGroups(_ steps: [SteamDependency]) throws -> [String] {
        var groups = Set<String>()
        for step in steps where !step.isAvailable {
            guard let group = step.redistGroup else { throw DockError.message("Manca un installer specifico del gioco (\(step.name)). La verifica dei file non lo ha recuperato.") }
            groups.insert(group)
        }
        return groups.sorted()
    }
    static func fileList(groups: [String]) -> String {
        groups.map { "regex:^(?:_CommonRedist[/\\\\])?" + $0.split(separator: "/").dropFirst().map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[/\\\\]") + "[/\\\\].*" }.joined(separator: "\n") + "\n"
    }
    static func copyGroups(_ groups: [String], from cache: URL, to directory: URL) throws {
        for group in groups {
            let alternatives = [group, group.split(separator: "/").dropFirst().joined(separator: "/")]
            guard let source = try alternatives.map({ try DeckMetadata.contained($0, in: cache) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw DockError.message("Steam non ha fornito il pacchetto \(group).") }
            guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw DockError.message("Pacchetto \(group) non leggibile.") }
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw DockError.message("Collegamento non sicuro nel pacchetto dipendenze.") }
                guard values.isRegularFile == true else { continue }
                let relative = String(file.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(source.resolvingSymlinksInPath().standardizedFileURL.path.count + 1))
                let target = try DeckMetadata.contained(group + "/" + relative, in: directory)
                // Preserve the game's own signed scripts and installers.
                if FileManager.default.fileExists(atPath: target.path) { continue }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file, to: target)
            }
        }
    }
}
