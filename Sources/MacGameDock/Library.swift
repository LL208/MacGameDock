import AppKit
import Foundation
import SwiftUI

@MainActor
final class Library: ObservableObject {
    @Published private(set) var data = LibraryData()
    @Published private(set) var running: Set<UUID> = []
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var scanning = false
    @Published private(set) var syncingSteam = false
    @Published private(set) var signingIn = false
    @Published private(set) var scanSummary = ""
    @Published private(set) var scanWarnings: [String] = []
    @Published private(set) var steamMessage = ""
    @Published private(set) var hasSteamKey = false
    let machine = Machine.detect()
    let root: URL
    lazy var managedSteam = ManagedSteam(root: root)
    @Published var installSelection: Game?
    private var installingJob = false
    lazy var downloads = DownloadQueue(root: root, runner: { [weak self] job in
        guard let self else { throw CancellationError() }
        try await self.performInstall(job)
    }, interrupt: { [weak self] in
        if let self, self.installingJob {
            if self.managedSteam.preparing { self.managedSteam.message = "Pausa richiesta: attendo la fine della preparazione in corso." }
            else { self.managedSteam.cancel() }
        }
    })
    private var processes: [UUID: Process] = [:]
    private var logHandles: [UUID: FileHandle] = [:]
    private var canPersist = true
    private let steamLogin = SteamLogin()
    private var steamSyncTask: Task<Void, Never>?

    init() {
        if let directory = ProcessInfo.processInfo.environment["MACGAMEDOCK_DATA_DIRECTORY"], directory.hasPrefix("/") {
            root = URL(fileURLWithPath: directory, isDirectory: true)
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MacGameDock", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: url.path) {
                data = try JSONDecoder().decode(LibraryData.self, from: Data(contentsOf: url))
                guard data.schemaVersion == 1 else {
                    throw DockError.message("Versione della libreria non supportata.")
                }
            }
        } catch {
            canPersist = false
            self.error = "Impossibile leggere la libreria. Il file originale verrà preservato. \(error.localizedDescription)"
        }
        // No Keychain access during startup: the cached catalog needs no credentials.
    }

    private func commit(_ candidate: LibraryData) throws {
        guard canPersist else {
            throw DockError.message("La libreria non può essere modificata finché il problema di lettura non è risolto. Apri la cartella dati e conserva una copia di library.json prima di ripararlo.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(candidate).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        data = candidate
    }

    func scanInstalledGames() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let roots = data.extraScanRoots ?? []
        let result = await Task.detached(priority: .utility) {
            InstalledGamesScanner().scan(extraRoots: roots)
        }.value
        do {
            try commit(LibraryMerge.scan(result, into: data))
            scanWarnings = result.warnings
            scanSummary = "\(result.games.count) giochi rilevati nelle cartelle supportate."
        } catch { self.error = error.localizedDescription }
    }

    func addScanRoot() {
        let panel = NSOpenPanel()
        panel.title = "Aggiungi una cartella giochi"
        panel.message = "Scegli una libreria Steam (o steamapps), una cartella di manifest Epic, oppure una cartella con app GOG o goggame-*.info."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var candidate = data
        var roots = candidate.extraScanRoots ?? []
        if !roots.contains(url.path) { roots.append(url.path) }
        candidate.extraScanRoots = roots
        do {
            try commit(candidate)
            Task { await scanInstalledGames() }
        } catch { self.error = error.localizedDescription }
    }

    func removeScanRoot(_ path: String) {
        var candidate = data
        candidate.extraScanRoots?.removeAll { $0 == path }
        do { try commit(candidate) } catch { self.error = error.localizedDescription }
    }

    func connectSteam() { loadDirectCatalog() }
    func reconnectSteam() { loadDirectCatalog(forceQR: true) }
    func importPreviousSession() {
        do {
            guard let old = try SessionVault.read() else { steamMessage = "Nessuna sessione precedente. Accedi con QR una volta."; return }
            try SessionStore.save(old, root: root)
            managedSteam.refreshSessionStatus()
            steamMessage = "Sessione importata. I prossimi accessi non richiederanno il Portachiavi."
            loadDirectCatalog()
        } catch { self.error = error.localizedDescription }
    }
    func cancelSteamLogin() { managedSteam.cancel() }
    private func loadDirectCatalog(forceQR: Bool = false) {
        guard !signingIn, !syncingSteam, !managedSteam.busy, !installingJob else { return }
        signingIn = true
        Task {
            defer { signingIn = false }
            do {
                let (id, games) = try await managedSteam.catalog(expected: forceQR ? nil : data.steamAccount?.steamID, forceQR: forceQR)
                var candidate = data
                if candidate.steamAccount?.steamID != id { candidate = LibraryMerge.disconnect(candidate) }
                candidate.steamAccount = SteamAccount(steamID: id, connectedAt: Date())
                try commit(LibraryMerge.ownedGames(games, owner: id, into: candidate))
                steamMessage = "\(games.count) giochi caricati tramite la sessione Steam."
            } catch is CancellationError { steamMessage = "Accesso annullato." }
            catch { self.error = error.localizedDescription }
        }
    }

    func saveSteamKey(_ text: String) -> Bool {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count == 32, key.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            error = "La chiave Web API Steam deve contenere 32 caratteri esadecimali."
            return false
        }
        do {
            try SteamKeychain.save(key)
            hasSteamKey = true
            steamMessage = "Chiave salvata nel Portachiavi."
            if data.steamAccount != nil { syncSteam() }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func removeSteamKey() {
        steamSyncTask?.cancel()
        do {
            try SteamKeychain.delete()
            hasSteamKey = false
            steamMessage = "Chiave rimossa dal Portachiavi."
        } catch { self.error = error.localizedDescription }
    }

    func syncSteam() { loadDirectCatalog() }

    func disconnectSteam() {
        guard !installingJob else { error = "Metti in pausa il download prima di scollegare Steam."; return }
        cancelSteamLogin()
        steamSyncTask?.cancel()
        do {
            try SessionStore.delete(root: root)
            managedSteam.refreshSessionStatus()
            try commit(LibraryMerge.disconnect(data))
            steamMessage = "Account scollegato. I giochi locali restano disponibili."
        } catch { self.error = error.localizedDescription }
    }

    func importGame(store: GameStore) {
        let panel = NSOpenPanel()
        panel.title = "Scegli il gioco già installato"
        panel.message = "Seleziona un eseguibile Windows (.exe) o un'app Mac (.app). Lo store serve a organizzare la libreria."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ["exe", "app"].contains(url.pathExtension.lowercased()) else {
            error = "Scegli un file .exe o un'applicazione .app."
            return
        }
        guard !data.games.contains(where: { URL(fileURLWithPath: $0.executablePath).standardizedFileURL == url.standardizedFileURL }) else {
            error = "Questo gioco è già nella libreria."
            return
        }
        var candidate = data
        candidate.games.append(Game(id: UUID(), title: url.deletingPathExtension().lastPathComponent,
                                   store: store, executablePath: url.path, addedAt: Date()))
        do { try commit(candidate) } catch { self.error = error.localizedDescription }
    }

    func selectRuntime() {
        let panel = NSOpenPanel()
        panel.title = "Seleziona wine o wine64"
        panel.message = "Serve un runtime Wine per macOS compatibile con il tuo Mac. Non selezionare l'app CrossOver: scegli l'eseguibile del runtime."
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path), !url.hasDirectoryPath else {
            error = "Il file selezionato non è un eseguibile."
            return
        }
        var candidate = data
        candidate.winePath = url.path
        do { try commit(candidate) } catch { self.error = error.localizedDescription }
    }

    func prefix(for game: Game) -> URL {
        root.appendingPathComponent("Prefixes", isDirectory: true).appendingPathComponent(game.id.uuidString, isDirectory: true)
    }

    func log(for game: Game) -> URL {
        root.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent("\(game.id.uuidString).log")
    }

    func launch(_ game: Game) {
        guard !running.contains(game.id) else { return }
        if game.steamAppID != nil, game.managedLaunch == nil || !game.isInstalled {
            installSelection = game
            return
        }
        if let launchURL = game.launchURL {
            guard game.isInstalled else { error = "La cartella del gioco non è disponibile."; return }
            openStoreURL(launchURL, fallback: nil)
            return
        }
        let executable = URL(fileURLWithPath: game.executablePath)
        guard FileManager.default.fileExists(atPath: executable.path) else {
            error = "Il gioco è stato spostato o rimosso. Rimuovi la voce e importalo dal nuovo percorso."
            return
        }
        if game.isNative && executable.pathExtension.lowercased() == "app" {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = game.managedLaunch?.arguments ?? []
            NSWorkspace.shared.openApplication(at: executable, configuration: configuration) { _, error in
                Task { @MainActor in
                    if let error { self.error = error.localizedDescription }
                    else { self.notice = "Richiesta di avvio inviata a macOS. Il monitoraggio dei giochi nativi non è ancora disponibile." }
                }
            }
            return
        }
        if game.isNative {
            do {
                let p = Process(); p.executableURL = executable
                p.arguments = game.managedLaunch?.arguments ?? []
                p.currentDirectoryURL = game.managedLaunch.map { URL(fileURLWithPath: $0.workingDirectory) }
                p.terminationHandler = { _ in Task { @MainActor in self.running.remove(game.id); self.processes.removeValue(forKey: game.id) } }
                try p.run(); processes[game.id] = p; running.insert(game.id)
            } catch { self.error = error.localizedDescription }
            return
        }
        let runtime = WineRuntime.detect() ?? data.winePath
        guard !runtime.isEmpty, FileManager.default.isExecutableFile(atPath: runtime) else {
            error = "Configura un runtime Wine valido nella schermata Il tuo Mac prima di avviare giochi Windows."
            return
        }
        do {
            try FileManager.default.createDirectory(at: prefix(for: game), withIntermediateDirectories: true)
            let logURL = log(for: game)
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Start a new log for each launch; do not hold unbounded output in memory.
            try Data("MacGameDock — \(game.title) — \(Date())\n".utf8).write(to: logURL, options: .atomic)
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: runtime)
            process.arguments = [game.executablePath] + (game.managedLaunch?.arguments ?? [])
            process.currentDirectoryURL = game.managedLaunch.map { URL(fileURLWithPath: $0.workingDirectory) } ?? executable.deletingLastPathComponent()
            let environment = WineRuntime.environment(prefix: game.managedLaunch.map { URL(fileURLWithPath: $0.prefix) } ?? prefix(for: game), runtime: runtime)
            process.environment = environment
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { finished in
                let status = finished.terminationStatus
                Task { @MainActor in
                    self.running.remove(game.id)
                    self.processes.removeValue(forKey: game.id)
                    try? self.logHandles.removeValue(forKey: game.id)?.close()
                    if status != 0 {
                        self.error = "Il processo Wine è terminato con codice \(status). Apri il log del gioco per la diagnosi."
                    }
                }
            }
            processes[game.id] = process
            logHandles[game.id] = handle
            running.insert(game.id)
            do { try process.run() } catch {
                processes.removeValue(forKey: game.id)
                running.remove(game.id)
                try? logHandles.removeValue(forKey: game.id)?.close()
                throw error
            }
        } catch { self.error = error.localizedDescription }
    }

    func installSteam(_ game: Game, platform: InstallPlatform = .windows) {
        downloads.enqueue(game, platform: platform, accountID: data.steamAccount?.steamID)
        installSelection = nil
    }
    private func performInstall(_ job: DownloadJob) async throws {
        while managedSteam.busy || signingIn {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try Task.checkCancellation()
        if let owner = job.accountID, owner != data.steamAccount?.steamID {
            throw DockError.message("Questo download appartiene a un altro account Steam. Ricollegalo per continuare.")
        }
        let runtime = WineRuntime.detect() ?? (data.winePath.isEmpty ? nil : data.winePath)
        guard job.platform == .macOS || runtime != nil else { throw DockError.message("Non è stato rilevato un motore Wine per la versione Windows.") }
        installingJob = true
        defer { installingJob = false }
        let (exe, directory, launch) = try await managedSteam.install(job.game, platform: job.platform, runtime: runtime, expected: job.accountID ?? data.steamAccount?.steamID)
        try Task.checkCancellation()
        var candidate = data
        guard let index = candidate.games.firstIndex(where: { $0.id == job.game.id }) else { throw DockError.message("Gioco rimosso dalla libreria durante il download.") }
        candidate.games[index].executablePath = exe
        candidate.games[index].installDirectory = directory
        candidate.games[index].managedLaunch = launch
        candidate.games[index].launchURL = nil
        candidate.games[index].detectedByScan = nil
        if candidate.steamAccount == nil, let session = try SessionStore.read(root: root) {
            candidate.steamAccount = SteamAccount(steamID: session.steamID, connectedAt: Date())
        }
        try commit(candidate)
    }

    func openStoreURL(_ value: String, fallback: String?) {
        guard let url = URL(string: value), ["steam", "com.epicgames.launcher"].contains(url.scheme ?? "") else {
            error = "Collegamento allo store non valido."; return
        }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            if let fallback, let web = URL(string: fallback) { NSWorkspace.shared.open(web) }
            error = "Il client dello store non è disponibile. Installa Steam o Epic Games Launcher per completare l'operazione."
            return
        }
        if !NSWorkspace.shared.open(url) { error = "Il client dello store non ha accettato il collegamento." }
    }

    func visibleGames(installedOnly: Bool) -> [Game] {
        data.games.filter { game in
            let visible = game.catalogOwner == nil || game.catalogOwner == data.steamAccount?.steamID || game.isInstalled
            return visible && (!installedOnly || game.isInstalled)
        }
    }

    func remove(_ game: Game) {
        guard !running.contains(game.id), !downloads.jobs.contains(where: { $0.game.id == game.id && [.active, .queued, .paused].contains($0.state) }) else { return }
        var candidate = data
        candidate.games.removeAll { $0.id == game.id }
        do { try commit(candidate) } catch { self.error = error.localizedDescription }
    }

    func openDataFolder() { NSWorkspace.shared.open(root) }
    func openLog(_ game: Game) {
        guard FileManager.default.fileExists(atPath: log(for: game).path) else {
            error = "Non ci sono ancora log per questo gioco."
            return
        }
        NSWorkspace.shared.open(log(for: game))
    }
}
