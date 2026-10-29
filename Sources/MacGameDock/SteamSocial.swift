import Foundation

@MainActor
final class SteamSocial: ObservableObject {
    @Published private(set) var profile: SteamPersonaProfile?
    @Published private(set) var connecting = false
    @Published private(set) var changingPresence = false
    @Published var status = "" { didSet { if status != oldValue { AppDiagnostics(root: root).write("Steam", status) } } }
    private let root: URL
    private let engine: ManagedSteam
    private var directory: URL?
    private var owner: String?
    private var runner: Task<Void, Never>?
    private var timer: Timer?
    private var initializedPresence = false
    private var playingRevision: Int64 = 0
    private var games: [Int: Int32] = [:]
    private var preferred: SteamPersona = .offline
    var connected: Bool { profile != nil && runner != nil }
    init(root: URL, helperProvider: (() throws -> URL)? = nil) { self.root = root; engine = ManagedSteam(root: root, helperProvider: helperProvider) }
    func start(owner: String) {
        guard self.owner != owner || runner == nil else { return }
        stop()
        guard let saved = try? SessionStore.read(root: root), saved.steamID == owner else { status = "Collega la sessione Steam per attivare il profilo."; return }
        self.owner = owner; connecting = true; initializedPresence = false
        struct Preference: Decodable { let steamID: String; let state: SteamPersona }
        if let bytes = try? Data(contentsOf: root.appendingPathComponent("Account/presence.json")), let preference = try? JSONDecoder().decode(Preference.self, from: bytes), preference.steamID == owner { preferred = preference.state }
        else { preferred = .offline }
        let folder = root.appendingPathComponent("Social/\(UUID().uuidString)")
        directory = folder
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { status = error.localizedDescription; connecting = false; return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        runner = Task { [weak self] in
            guard let self else { return }
            do {
                while self.engine.busy { try await Task.sleep(nanoseconds: 100_000_000) }
                try Task.checkCancellation()
                _ = try await self.engine.run(["-deck-service", folder.path, "-deck-parentpid", String(ProcessInfo.processInfo.processIdentifier)], expected: owner, loginID: 1296516166) }
            catch is CancellationError {}
            catch { self.status = "Connessione Steam: " + error.localizedDescription }
            if self.directory == folder {
                self.connecting = false; self.profile = nil; self.timer?.invalidate(); self.timer = nil; self.runner = nil
            }
            try? FileManager.default.removeItem(at: folder)
        }
    }
    private func poll() {
        guard let directory, let owner else { return }
        if engine.qr != nil { status = "La sessione Steam richiede un nuovo accesso. Ricollega l’account."; engine.cancel(); return }
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("result-profile.json")), bytes.count <= 65536,
              let value = try? JSONDecoder().decode(SteamPersonaProfile.self, from: bytes), value.steamID == owner else { return }
        profile = value; connecting = false
        if !initializedPresence { initializedPresence = true; setPresence(preferred); updatePlaying() }
    }
    func stop() {
        if let directory { try? Data().write(to: directory.appendingPathComponent("stop"), options: .atomic) }
        runner?.cancel(); engine.cancel(); runner = nil; timer?.invalidate(); timer = nil
        profile = nil; directory = nil; connecting = false; initializedPresence = false; games = [:]; owner = nil
    }
    private struct Reply: Decodable { let ok: Bool; let error: String?; let snapshot: SteamAchievementSnapshot? }
    private func send(_ values: [String: Any]) async throws -> Reply {
        guard let directory, let owner, connected else { throw DockError.message("La connessione Steam in background non è pronta.") }
        let id = UUID().uuidString
        var command = values; command["steamID"] = owner; command["language"] = AppLanguage.shared.steamLanguage
        let file = directory.appendingPathComponent("command-\(id).json"), result = directory.appendingPathComponent("result-\(id).json")
        try JSONSerialization.data(withJSONObject: command).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: result); try? FileManager.default.removeItem(at: file) }
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            guard self.owner == owner, self.directory == directory, runner != nil else { throw DockError.message("Sessione Steam interrotta.") }
            if let bytes = try? Data(contentsOf: result), bytes.count <= 16_000_000 {
                let reply = try JSONDecoder().decode(Reply.self, from: bytes)
                guard reply.ok else { throw DockError.message(Self.diagnostic(reply.error ?? "service_error")) }
                return reply
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw DockError.message("Steam non ha risposto in tempo. L’operazione può essere riprovata.")
    }
    static func diagnostic(_ code: String) -> String {
        switch code {
        case "playing_elsewhere": return "Steam segnala una partita su un altro dispositivo. La sessione non viene sostituita."
        case "stats_rejected", "stats_unconfirmed": return "Steam non ha confermato lo sblocco. L’evento resta in attesa."
        case "wrong_account": return "La risposta Steam appartiene a un altro account."
        default: return "Il servizio Steam non ha completato l’operazione."
        }
    }
    func setPresence(_ persona: SteamPersona) {
        guard !changingPresence, connected, let owner else { return }
        changingPresence = true
        Task {
            defer { changingPresence = false }
            do {
                _ = try await send(["kind": "presence", "state": persona.rawValue])
                struct Preference: Encodable { let steamID: String; let state: SteamPersona }
                try JSONEncoder().encode(Preference(steamID: owner, state: persona)).write(to: root.appendingPathComponent("Account/presence.json"), options: .atomic)
                preferred = persona; status = ""
            } catch { status = error.localizedDescription }
        }
    }
    func achievements(_ appID: Int) async throws -> SteamAchievementSnapshot {
        guard let owner else { throw DockError.message("Account Steam non collegato.") }
        let reply = try await send(["kind": "achievements", "appID": appID])
        guard let snapshot = reply.snapshot else { throw DockError.message("Steam non ha restituito lo schema dei trofei.") }
        try snapshot.validate(owner: owner, appID: appID); return snapshot
    }
    func unlock(_ appID: Int, names: [String]) async throws -> SteamAchievementSnapshot {
        guard let owner else { throw DockError.message("Account Steam non collegato.") }
        let reply = try await send(["kind": "unlock", "appID": appID, "names": names])
        guard let snapshot = reply.snapshot else { throw DockError.message("Conferma Steam mancante.") }
        try snapshot.validate(owner: owner, appID: appID); return snapshot
    }
    func gameStarted(_ appID: Int, processID: Int32) { games[appID] = processID; updatePlaying() }
    func gameStopped(_ appID: Int) { games.removeValue(forKey: appID); updatePlaying() }
    private func updatePlaying() {
        playingRevision += 1; let revision = playingRevision
        let current = games.map { ["appID": $0.key, "processID": Int($0.value)] }
        guard connected else { return }
        Task { do { _ = try await send(["kind": "playing", "games": current, "revision": revision]) } catch { status = error.localizedDescription } }
    }
}
