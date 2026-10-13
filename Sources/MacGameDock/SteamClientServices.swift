import AppKit
import Foundation

struct SteamClientReceipt: Codable {
    struct Depot: Codable {
        let depotID: UInt32
        let manifestID: String
        let size: UInt64
    }
    let appID: UInt32
    let buildID: UInt32
    let os: String
    let depots: [Depot]
    func validate(appID: Int, platform: InstallPlatform) throws {
        guard self.appID == appID, buildID > 0, os == platform.rawValue,
              !depots.isEmpty, Set(depots.map(\.depotID)).count == depots.count,
              depots.allSatisfy({ $0.depotID > 0 && UInt64($0.manifestID).map { $0 > 0 } == true }) else {
            throw DockError.message("Ricevuta Steam incompleta o non associata alla versione installata.")
        }
    }
}

enum SteamClientLayout {
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "") + "\""
    }
    static func manifest(receipt: SteamClientReceipt, title: String, folder: String, account: String) -> String {
        let installed = receipt.depots.map { depot in
            "\t\t\(quote(String(depot.depotID)))\n\t\t{\n\t\t\t\"manifest\" \(quote(depot.manifestID))\n\t\t\t\"size\" \(quote(String(depot.size)))\n\t\t}"
        }.joined(separator: "\n")
        return """
        "AppState"
        {
            "appid" "\(receipt.appID)"
            "name" \(quote(title))
            "StateFlags" "4"
            "installdir" \(quote(folder))
            "buildid" "\(receipt.buildID)"
            "LastOwner" \(quote(account))
            "InstalledDepots"
            {
        \(installed)
            }
        }
        """
    }
    static func register(game: Game, steamDirectory: URL, receipt: SteamClientReceipt, account: String) throws {
        guard let id = game.steamAppID, let path = game.installDirectory, game.managedLaunch != nil else { throw DockError.message("Installazione gestita mancante.") }
        try receipt.validate(appID: id, platform: game.isNative ? .macOS : .windows)
        let source = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &directory), directory.boolValue else { throw DockError.message("Cartella del gioco non disponibile.") }
        let apps = steamDirectory.appendingPathComponent("steamapps")
        let common = apps.appendingPathComponent("common")
        let manifestURL = apps.appendingPathComponent("appmanifest_\(id).acf")
        let name = "MacGameDeck-\(id)", link = common.appendingPathComponent(name)
        // Never replace an existing client installation or redirect its manifest.
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let parsed = try VDF.parse(String(contentsOf: manifestURL, encoding: .utf8))
            guard parsed["AppState"]?.fields?["appid"]?.string == String(id),
                  parsed["AppState"]?.fields?["installdir"]?.string == name,
                  link.resolvingSymlinksInPath().standardizedFileURL == source else {
                throw DockError.message("Steam ha già un'altra installazione di questo gioco. Avviala dal menu ‘Avvia installazione Steam esistente’; i suoi file non sono stati modificati.")
            }
            return
        }
        let base = steamDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        for target in [apps, common] {
            let resolved = target.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(base + "/") else { throw DockError.message("Cartella Steam non sicura.") }
        }
        try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
            guard link.resolvingSymlinksInPath().standardizedFileURL == source else { throw DockError.message("Collegamento Steam già occupato da un altro percorso.") }
        } else {
            guard !FileManager.default.fileExists(atPath: link.path) else { throw DockError.message("Cartella Steam già occupata; nessun file è stato sostituito.") }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        }
        try Data(manifest(receipt: receipt, title: game.title, folder: name, account: account).utf8).write(to: manifestURL, options: .atomic)
    }
    static func recentAccount(at steamDirectory: URL) throws -> String? {
        let file = steamDirectory.appendingPathComponent("config/loginusers.vdf")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let bytes = try Data(contentsOf: file)
        guard bytes.count < 2_000_000, let text = String(data: bytes, encoding: .utf8), let users = try VDF.parse(text)["users"]?.fields else { throw DockError.message("Configurazione dell'account del client Steam non leggibile.") }
        let recent = users.filter { $0.value.fields?["MostRecent"]?.string == "1" }.map(\.key)
        guard recent.count <= 1 else { throw DockError.message("Account del client Steam ambiguo. Seleziona l'account corretto nel client.") }
        return recent.first
    }
}

@MainActor
final class SteamClientServices: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var requestedGame: UUID?
    private var clients: [Process] = []
    private let root: URL
    init(root: URL) { self.root = root }

    func launch(_ game: Game, account: String, runtime: String?, downloader: ManagedSteam, existing: Bool = false, loginOnly: Bool = false) async throws {
        guard !busy else { throw DockError.message("Preparazione Steam già in corso.") }
        guard let id = game.steamAppID, id > 0 else { throw DockError.message("ID Steam mancante.") }
        busy = true; requestedGame = game.id
        var submitted = false
        defer { busy = false; if !submitted { message = "Avvio tramite Steam non completato. Consulta il messaggio di errore." } }
        let steamDirectory: URL
        let executable: URL
        let environment: [String: String]?
        var windowsPrefix: URL?
        if game.isNative {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.valvesoftware.steam") else {
                throw DockError.message("Per i trofei dei giochi Mac serve il client Steam ufficiale per macOS. Installalo una volta e riprova da MacGameDeck.")
            }
            executable = app.appendingPathComponent("Contents/MacOS/steam_osx")
            steamDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Steam")
            environment = nil
        } else {
            guard let launch = game.managedLaunch, let runtime, FileManager.default.isExecutableFile(atPath: runtime) else { throw DockError.message("Il gioco Windows richiede un container e un runtime Wine validi.") }
            let prefix = URL(fileURLWithPath: launch.prefix)
            try WineRuntime.validate(prefix: prefix)
            steamDirectory = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
            executable = steamDirectory.appendingPathComponent("steam.exe")
            environment = WineRuntime.environment(prefix: prefix, runtime: runtime)
            windowsPrefix = prefix
            guard steamDirectory.resolvingSymlinksInPath().path.hasPrefix(prefix.resolvingSymlinksInPath().path + "/") else { throw DockError.message("Percorso del client Steam fuori dal container.") }
        }
        if !loginOnly, let current = try SteamClientLayout.recentAccount(at: steamDirectory), current != account {
            throw DockError.message("Il client Steam usa un account diverso da MacGameDeck. Dal menu del gioco apri ‘Accesso Steam per i trofei’, cambia account nel client e riprova.")
        }
        if !existing && !loginOnly, game.managedLaunch != nil {
            guard let installDirectory = game.installDirectory else { throw DockError.message("Cartella d'installazione mancante.") }
            let receiptURL = URL(fileURLWithPath: installDirectory).appendingPathComponent(".MacGameDeck/client-receipt.json")
            if !FileManager.default.fileExists(atPath: receiptURL.path) {
                guard !downloader.busy else { throw DockError.message("Attendi il download Steam in corso.") }
                message = "Verifico i file installati e la ricevuta Steam…"
                let platform: InstallPlatform = game.isNative ? .macOS : .windows
                _ = try await downloader.run(["-app", String(id), "-os", platform.rawValue, "-dir", installDirectory, "-validate"] + (platform == .windows ? ["-all-archs"] : ["-osarch", "64"]), expected: account)
            }
            let receipt = try JSONDecoder().decode(SteamClientReceipt.self, from: Data(contentsOf: receiptURL))
            try SteamClientLayout.register(game: game, steamDirectory: steamDirectory, receipt: receipt, account: account)
        }
        if let prefix = windowsPrefix, let runtime, !FileManager.default.fileExists(atPath: executable.path) {
            message = "Installo il client Steam ufficiale nel container…"
            try await installWindowsClient(prefix: prefix, runtime: runtime, steamExecutable: executable)
        }
        try Task.checkCancellation()
        let process = Process()
        if let environment, let runtime {
            process.executableURL = URL(fileURLWithPath: runtime)
            process.arguments = [executable.path] + (loginOnly ? [] : ["-silent", "-applaunch", String(id)])
            process.environment = environment
        } else {
            process.executableURL = executable
            process.arguments = loginOnly ? [] : ["-silent", "-applaunch", String(id)]
        }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        clients.removeAll { !$0.isRunning }; clients.append(process)
        message = loginOnly ? "Accedi nel client Steam ufficiale con lo stesso account, poi premi Gioca in MacGameDeck." : "Avvio richiesto al client Steam. Al primo utilizzo può chiedere accesso o verificare i file. Se Steam era già aperto durante la prima importazione, riavvialo una volta. La sincronizzazione dei trofei deve essere verificata nel gioco."
        submitted = true
        // The client process is not the game: never count its lifetime as playtime.
    }

    private func installWindowsClient(prefix: URL, runtime: String, steamExecutable: URL) async throws {
        let installer = root.appendingPathComponent("Tools/SteamClient/SteamSetup.exe")
        try FileManager.default.createDirectory(at: installer.deletingLastPathComponent(), withIntermediateDirectories: true)
        let request = URLRequest(url: URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!, timeoutInterval: 120)
        let (temp, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https",
              let host = http.url?.host, host == "cdn.akamai.steamstatic.com" || host.hasSuffix(".steamstatic.com") else { throw DockError.message("Il download del client Steam ufficiale non è riuscito.") }
        let handle = try FileHandle(forReadingFrom: temp); defer { try? handle.close() }
        guard try handle.read(upToCount: 2) == Data([0x4d, 0x5a]),
              (try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 100_000_000 else { throw DockError.message("Installer Steam non valido.") }
        try Task.checkCancellation()
        try Data(contentsOf: temp).write(to: installer, options: .atomic)
        let process = Process(); process.executableURL = URL(fileURLWithPath: runtime)
        process.arguments = [installer.path, "/S"]
        process.environment = WineRuntime.environment(prefix: prefix, runtime: runtime)
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw DockError.message("Installazione Steam troppo lunga. Apri il container per completare la configurazione.") }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        } catch { if process.isRunning { process.terminate() }; throw error }
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: steamExecutable.path) else { throw DockError.message("Il runtime non ha installato Steam correttamente. I file del gioco sono conservati.") }
    }
}
