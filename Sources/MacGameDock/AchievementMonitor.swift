import AppKit
import SwiftUI

struct AchievementEvent: Codable, Equatable {
    let owner: String
    let appID: Int
    let name: String
    let earnedTime: UInt32
}
enum AchievementCapture {
    static func newlyEarned(bytes: Data, baseline: Set<String>, snapshot: SteamAchievementSnapshot, startedAt: Date, now: Date = Date()) throws -> [AchievementEvent] {
        guard bytes.count <= 8_000_000, let data = try JSONSerialization.jsonObject(with: bytes) as? [String: [String: Any]] else { throw DockError.message("Registro dei trofei non leggibile.") }
        return snapshot.achievements.compactMap { achievement in
            guard !baseline.contains(achievement.name), let value = data[achievement.name], value["earned"] as? Bool == true,
                  let timestamp = value["earned_time"] as? NSNumber, timestamp.doubleValue >= startedAt.timeIntervalSince1970 - 2,
                  timestamp.doubleValue <= now.timeIntervalSince1970 + 5, timestamp.doubleValue > 0, timestamp.doubleValue <= Double(UInt32.max) else { return nil }
            return AchievementEvent(owner: snapshot.steamID, appID: snapshot.appID, name: achievement.name, earnedTime: timestamp.uint32Value)
        }
    }
    static func unsyncedStored(bytes: Data, snapshot: SteamAchievementSnapshot, now: Date = Date()) throws -> [AchievementEvent] {
        let alreadyRemote = Set(snapshot.achievements.filter(\.unlocked).map(\.name))
        return try newlyEarned(bytes: bytes, baseline: alreadyRemote, snapshot: snapshot, startedAt: Date(timeIntervalSince1970: 1), now: now)
    }
    static func baseline(_ file: URL, snapshot: SteamAchievementSnapshot) -> Set<String> {
        var names = Set(snapshot.achievements.filter(\.unlocked).map(\.name))
        if let bytes = try? Data(contentsOf: file), bytes.count <= 8_000_000, let data = try? JSONSerialization.jsonObject(with: bytes) as? [String: [String: Any]] {
            for (name, value) in data where value["earned"] as? Bool == true { names.insert(name) }
        }
        return names
    }
}
@MainActor
final class AchievementNotifier {
    private var panel: NSPanel?
    private var queued: [(String, SteamAchievement)] = []
    private var presenting = false
    private let onPresented: (String, Bool) -> Void
    init(onPresented: @escaping (String, Bool) -> Void = { _, _ in }) { self.onPresented = onPresented }
    func show(game: String, achievement: SteamAchievement) { queued.append((game, achievement)); presentNext() }
    private func presentNext() {
        guard !presenting, !queued.isEmpty else { return }
        presenting = true
        let (game, achievement) = queued.removeFirst()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSPanel(contentRect: NSRect(x: screen.maxX - 380, y: screen.minY + 25, width: 350, height: 110), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .statusBar; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true; window.ignoresMouseEvents = true; window.hidesOnDeactivate = false
        window.contentView = NSHostingView(rootView: HStack(spacing: 13) {
            AsyncImage(url: achievement.imageURL) { image in image.resizable() } placeholder: { Image(systemName: "trophy.fill").font(.largeTitle).foregroundStyle(.yellow) }.frame(width: 48, height: 48).cornerRadius(8)
            VStack(alignment: .leading, spacing: 5) { Text("Trofeo ottenuto").font(.caption).foregroundStyle(.mint); Text(achievement.displayTitle).font(.headline).lineLimit(2); Text(game).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
        }.padding(17).frame(width: 350, height: 110).background(Color(red: 0.09, green: 0.11, blue: 0.15)).cornerRadius(14).preferredColorScheme(.dark))
        panel = window; window.orderFrontRegardless()
        onPresented(achievement.name, window.isVisible && window.isOnActiveSpace)
        Task { try? await Task.sleep(nanoseconds: 5_000_000_000); window.orderOut(nil); self.panel = nil; self.presenting = false; self.presentNext() }
    }
}
@MainActor
final class AchievementMonitor: ObservableObject {
    @Published private(set) var snapshots: [Int: SteamAchievementSnapshot] = [:]
    @Published private(set) var status: [UUID: String] = [:]
    private struct Session { let game: Game; let setup: SteamBridgeSetup; let startedAt: Date; var baseline: Set<String> }
    private var sessions: [UUID: Session] = [:]
    private var prepared: [UUID: SteamBridgeSetup] = [:]
    private var nextRetry = 0.0
    private var preparedBaselines: [UUID: Set<String>] = [:]
    private var disabled: Set<Int> = []
    @Published private(set) var pending: [AchievementEvent] = []
    private var timer: Timer?
    private var flushing = false
    private let root: URL
    private let social: SteamSocial
    private lazy var notifier = AchievementNotifier(onPresented: { [weak self] name, visible in
        self?.diagnostics.write("Trofei", visible ? "Popup mostrato nello spazio attivo: " + name : "Popup creato ma non visibile nello spazio attivo: " + name)
    })
    private let notification: ((String, SteamAchievement) -> Void)?
    private lazy var diagnostics = AppDiagnostics(root: root)
    private let onSnapshot: (SteamAchievementSnapshot) -> Void
    private var journal: URL { root.appendingPathComponent("SteamBridge/events.json") }
    init(root: URL, social: SteamSocial, onSnapshot: @escaping (SteamAchievementSnapshot) -> Void, notification: ((String, SteamAchievement) -> Void)? = nil) {
        self.root = root; self.social = social; self.onSnapshot = onSnapshot; self.notification = notification
        if let bytes = try? Data(contentsOf: root.appendingPathComponent("SteamBridge/disabled.json")), let values = try? JSONDecoder().decode([Int].self, from: bytes) { disabled = Set(values) }
        if let bytes = try? Data(contentsOf: root.appendingPathComponent("SteamBridge/events.json")), bytes.count < 8_000_000, let events = try? JSONDecoder().decode([AchievementEvent].self, from: bytes) { pending = events }
    }
    func prepare(_ game: Game, snapshot: SteamAchievementSnapshot, resources: URL? = nil) throws {
        if let appID = game.steamAppID, disabled.contains(appID) { status[game.id] = "Steam API originale"; return }
        let hadBridge = (try? SteamBridgeInstaller.receiptURL(game)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        prepared[game.id] = try SteamBridgeInstaller.install(game, snapshot: snapshot, root: root, resources: resources)
        if let setup = prepared[game.id] {
            if hadBridge, let bytes = try? Data(contentsOf: setup.eventFile), let stored = try? AchievementCapture.unsyncedStored(bytes: bytes, snapshot: snapshot) {
                for event in stored where !pending.contains(where: { $0.owner == event.owner && $0.appID == event.appID && $0.name == event.name }) { pending.append(event) }
                if !stored.isEmpty { saveJournal() }
            }
            preparedBaselines[game.id] = AchievementCapture.baseline(setup.eventFile, snapshot: setup.snapshot)
        }
        snapshots[snapshot.appID] = snapshot
        let cache = root.appendingPathComponent("SteamBridge/Schemas/\(snapshot.steamID)/\(snapshot.appID).json")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(snapshot).write(to: cache, options: .atomic)
        status[game.id] = prepared[game.id] == nil ? "Steam API del gioco non supportata" : (snapshot.achievements.isEmpty ? "Steamworks locale attivo · trofei non disponibili" : "Trofei in gioco pronti")
        diagnostics.write("Trofei", status[game.id] ?? "", game: game)
    }
    func prepareCached(_ game: Game, owner: String) {
        guard let appID = game.steamAppID else { return }
        let file = root.appendingPathComponent("SteamBridge/Schemas/\(owner)/\(appID).json")
        if let bytes = try? Data(contentsOf: file), bytes.count <= 8_000_000, let snapshot = try? JSONDecoder().decode(SteamAchievementSnapshot.self, from: bytes), (try? snapshot.validate(owner: owner, appID: appID)) != nil { try? prepare(game, snapshot: snapshot) }
        else {
            // Basic Steamworks remains local even when statistics are unavailable. No synthetic unlocks.
            try? prepare(game, snapshot: SteamAchievementSnapshot(steamID: owner, appID: appID, achievements: [], stats: []))
        }
    }
    func start(_ game: Game, processID: Int32) {
        if let appID = game.steamAppID { social.gameStarted(appID, processID: processID) }
        guard let setup = prepared[game.id] else { return }
        diagnostics.write("Trofei", "Monitor attivo: attendo nuovi eventi del gioco", game: game)
        sessions[game.id] = Session(game: game, setup: setup, startedAt: Date(), baseline: preparedBaselines[game.id] ?? Set(setup.snapshot.achievements.filter(\.unlocked).map(\.name)))
        if timer == nil { timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } } }
    }
    func wineEnvironment(for game: Game) -> [String: String] {
        guard let setup = prepared[game.id] else { return [:] }
        return ["GseSavePath": setup.wineSavePath, "WINEDLLOVERRIDES": "steam_api,steam_api64=n,b"]
    }
    func stop(_ game: Game) {
        tick(); sessions.removeValue(forKey: game.id)
        if let appID = game.steamAppID { social.gameStopped(appID) }
        if sessions.isEmpty { timer?.invalidate(); timer = nil }
        flush()
    }
    func hasLocalBridge(_ game: Game) -> Bool { prepared[game.id] != nil }
    func isDisabled(_ game: Game) -> Bool { game.steamAppID.map { disabled.contains($0) } ?? true }
    func enable(_ game: Game) throws {
        if let appID = game.steamAppID { disabled.remove(appID) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("SteamBridge"), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(disabled)).write(to: root.appendingPathComponent("SteamBridge/disabled.json"), options: .atomic)
        status[game.id] = "Trofei in gioco attivi al prossimo avvio"
    }
    func disable(_ game: Game) throws {
        guard sessions[game.id] == nil else { throw DockError.message("Chiudi il gioco prima di ripristinare Steam API.") }
        try SteamBridgeInstaller.restore(game, root: root)
        if let appID = game.steamAppID {
            disabled.insert(appID)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("SteamBridge"), withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(disabled)).write(to: root.appendingPathComponent("SteamBridge/disabled.json"), options: .atomic)
        }
        prepared.removeValue(forKey: game.id); status[game.id] = "Avvio diretto con Steam API originale"
    }
    private func saveJournal() {
        do { try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); try JSONEncoder().encode(pending).write(to: journal, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path) }
        catch { for id in sessions.keys { status[id] = "Impossibile conservare gli eventi dei trofei: " + error.localizedDescription } }
    }
    func poll() { tick() }
    private func notify(game: String, achievement: SteamAchievement) {
        if let notification { notification(game, achievement) } else { notifier.show(game: game, achievement: achievement) }
    }
    func testNotification() {
        let demo = SteamAchievement(name: "LOCAL_NOTIFICATION_TEST", title: "Notifica di prova", description: "Nessuno sblocco Steam", icon: nil, iconGray: nil, hidden: false, unlocked: true, unlockTime: 0, statID: 0, bit: 0)
        notify(game: "MacGameDeck · solo test locale", achievement: demo)
        diagnostics.write("Trofei", "Popup di prova richiesto. Nessun evento registrato o inviato a Steam.")
    }
    private func tick() {
        for id in Array(sessions.keys) {
            guard var session = sessions[id], let bytes = try? Data(contentsOf: session.setup.eventFile),
                  let events = try? AchievementCapture.newlyEarned(bytes: bytes, baseline: session.baseline, snapshot: session.setup.snapshot, startedAt: session.startedAt) else { continue }
            for event in events {
                session.baseline.insert(event.name)
                if !pending.contains(where: { $0.owner == event.owner && $0.appID == event.appID && $0.name == event.name }) { pending.append(event) }
                if var achievement = session.setup.snapshot.achievements.first(where: { $0.name == event.name }) { achievement.unlocked = true; achievement.unlockTime = event.earnedTime; notify(game: session.game.title, achievement: achievement) }
                diagnostics.write("Trofei", "Evento rilevato: \(event.name). Notifica richiesta; conferma Steam in attesa.", game: session.game)
                status[id] = "Sblocco rilevato · conferma Steam in attesa"
            }
            sessions[id] = session
            if !events.isEmpty { saveJournal() }
        }
        flush()
    }
    func pendingCount(_ game: Game, owner: String?) -> Int {
        guard let owner, let appID = game.steamAppID else { return 0 }
        return pending.filter { $0.owner == owner && $0.appID == appID }.count
    }
    func flush() {
        guard !flushing, ProcessInfo.processInfo.systemUptime >= nextRetry, social.connected, let owner = social.profile?.steamID, let first = pending.first(where: { $0.owner == owner }) else { return }
        flushing = true
        let batch = pending.filter { $0.owner == owner && $0.appID == first.appID }
        Task {
            defer { flushing = false }
            do {
                let snapshot = try await social.unlock(first.appID, names: Array(Set(batch.map(\.name))))
                guard snapshot.steamID == owner, snapshot.appID == first.appID else { return }
                let confirmed = Set(snapshot.achievements.filter(\.unlocked).map(\.name))
                pending.removeAll { $0.owner == owner && $0.appID == first.appID && confirmed.contains($0.name) }
                diagnostics.write("Trofei", "Steam ha confermato \(batch.filter { confirmed.contains($0.name) }.count) eventi del gioco \(first.appID).")
                saveJournal(); snapshots[first.appID] = snapshot; onSnapshot(snapshot)
                for (id, session) in sessions where session.setup.appID == first.appID { status[id] = "Trofei aggiornati su Steam" }
            } catch { diagnostics.write("Trofei", "Invio non confermato, nuovo tentativo previsto: " + error.localizedDescription); nextRetry = ProcessInfo.processInfo.systemUptime + 30; for (id, session) in sessions where session.setup.appID == first.appID { status[id] = error.localizedDescription } }
        }
    }
}
