import Foundation
import Combine
import CryptoKit

struct CurrentPlayers: Equatable {
    let count: Int
    let date: Date
    static func decode(_ bytes: Data, date: Date = Date()) throws -> CurrentPlayers {
        guard let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let response = json["response"] as? [String: Any], response["result"] as? Int == 1,
              let count = response["player_count"] as? Int, count >= 0 else { throw DockError.message("Numero di giocatori non disponibile.") }
        return CurrentPlayers(count: count, date: date)
    }
    static func fetch(_ appID: Int) async throws -> CurrentPlayers {
        let url = URL(string: "https://api.steampowered.com/ISteamUserStats/GetNumberOfCurrentPlayers/v1/?appid=\(appID)")!
        var request = URLRequest(url: url); request.timeoutInterval = 15
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, bytes.count < 100_000 else { throw DockError.message("Numero di giocatori non disponibile.") }
        return try decode(bytes)
    }
}
@MainActor
final class GameDetailModel: ObservableObject {
    @Published private(set) var insights: GameInsights?
    @Published private(set) var players: CurrentPlayers?
    @Published private(set) var trophies: [SteamAchievement] = []
    @Published private(set) var metadataLoading = false
    @Published private(set) var trophiesLoading = false
    @Published private(set) var trophiesLoaded = false
    @Published private(set) var metadataStatus = ""
    @Published private(set) var playersStatus = ""
    @Published private(set) var trophyStatus = ""
    @Published var expandedDescription = false
    @Published private(set) var releasing = false
    private var helperOperation: UUID?
    private(set) var gameID: UUID?
    private(set) var owner: String?
    private var appID: Int?
    private var token = UUID()
    private var tasks: [Task<Void, Never>] = []
    private var cancelHelper: (() -> Void)?
    private let metadata: (Int) async throws -> GameInsights
    private let playerCount: (Int) async throws -> CurrentPlayers
    init(metadata: @escaping (Int) async throws -> GameInsights = { try await GameInsights.fetch(appID: $0, language: "italian") }, playerCount: @escaping (Int) async throws -> CurrentPlayers = { try await CurrentPlayers.fetch($0) }) {
        self.metadata = metadata; self.playerCount = playerCount
    }
    func cancel() {
        token = UUID(); tasks.forEach { $0.cancel() }; tasks = []
        cancelHelper?(); cancelHelper = nil; helperOperation = nil; metadataLoading = false; trophiesLoading = false
    }
    func releaseForLaunch(library: Library) async {
        let operation = helperOperation
        cancel(); releasing = true; defer { releasing = false }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while let operation, library.managedSteam.activeOperationID == operation, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
        }
    }
    func load(_ game: Game, library: Library) {
        let owner = library.data.steamAccount?.steamID, operation = UUID()
        load(game: game, owner: owner, root: library.root, cached: game.steamAppID.flatMap { library.achievements.snapshots[$0] }) {
            guard let owner else { throw DockError.message("Collega Steam per visualizzare i tuoi trofei.") }
            let deadline = ProcessInfo.processInfo.systemUptime + 45
            while library.managedSteam.busy || library.managedSteam.preparing || library.signingIn {
                try Task.checkCancellation()
                if library.social.connected && library.social.profile?.steamID == owner { break }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw DockError.message("Steam è occupato. I trofei si possono aggiornare tra poco.") }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            try Task.checkCancellation()
            guard library.data.steamAccount?.steamID == owner else { throw CancellationError() }
            if library.social.connected && library.social.profile?.steamID == owner { return try await library.social.achievements(game.steamAppID!) }
            guard library.managedSteam.hasSavedSession, library.managedSteam.savedAccountID == owner else { throw DockError.message("Accedi a Steam dalla sezione Account per caricare i trofei.") }
            return try await library.managedSteam.achievements(game, expected: owner, operationID: operation)
        }
        helperOperation = operation
        cancelHelper = { library.managedSteam.cancel(operationID: operation) }
    }
    // Injectable readers keep metadata, player count and account-scoped trophies independent.
    func load(game: Game, owner: String?, root: URL, cached: SteamAchievementSnapshot? = nil, trophies read: @escaping () async throws -> SteamAchievementSnapshot) {
        cancel(); let generation = UUID(); token = generation
        self.owner = owner; gameID = game.id; appID = game.steamAppID
        insights = nil; players = nil; trophies = []; trophiesLoaded = false; expandedDescription = false
        metadataStatus = ""; playersStatus = ""; trophyStatus = ""
        guard let appID else {
            metadataStatus = "Descrizione e modalità non disponibili per questo store."
            playersStatus = "Non disponibile"; trophyStatus = "Trofei Steam non disponibili per questo gioco."; return
        }
        let cacheOwner = owner.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() } ?? "guest"
        let cache = root.appendingPathComponent("GameDetails/\(appID).json")
        if let bytes = try? Data(contentsOf: cache), bytes.count < 1_000_000 { insights = try? JSONDecoder().decode(GameInsights.self, from: bytes) }
        metadataLoading = true
        tasks.append(Task {
            defer { if token == generation { metadataLoading = false } }
            do {
                let value = try await metadata(appID); try Task.checkCancellation(); guard token == generation else { return }
                insights = value; metadataStatus = "Informazioni dello store Steam"
                try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let bytes = try? JSONEncoder().encode(value) { try? bytes.write(to: cache, options: .atomic) }
            } catch { if token == generation && !Task.isCancelled { metadataStatus = insights == nil ? "Descrizione non disponibile. Puoi riprovare con Aggiorna." : "Informazioni salvate sul Mac · aggiornamento non disponibile" } }
        })
        playersStatus = "Caricamento…"
        tasks.append(Task {
            do { let value = try await playerCount(appID); try Task.checkCancellation(); if token == generation { players = value; playersStatus = "Steam · lettura " + value.date.formatted(date: .omitted, time: .shortened) } }
            catch { if token == generation && !Task.isCancelled { playersStatus = "Dato Steam non disponibile" } }
        })
        guard let owner else { trophyStatus = "Collega Steam per visualizzare i tuoi trofei."; return }
        if let cached, (try? cached.validate(owner: owner, appID: appID)) != nil { trophies = cached.achievements; trophiesLoaded = true; trophyStatus = "Ultima lettura disponibile · aggiornamento…" }
        else {
            let file = root.appendingPathComponent("GameDetails/Trophies/\(cacheOwner)/\(appID).json")
            if let bytes = try? Data(contentsOf: file), bytes.count < 8_000_000, let saved = try? JSONDecoder().decode(SteamAchievementSnapshot.self, from: bytes), (try? saved.validate(owner: owner, appID: appID)) != nil { trophies = saved.achievements; trophiesLoaded = true; trophyStatus = "Ultima lettura disponibile · aggiornamento…" }
        }
        trophiesLoading = true
        tasks.append(Task {
            defer { if token == generation { trophiesLoading = false } }
            do {
                let result = try await read(); try Task.checkCancellation(); try result.validate(owner: owner, appID: appID)
                guard token == generation, self.owner == owner else { return }
                trophies = result.achievements; trophiesLoaded = true; trophyStatus = trophies.isEmpty ? "Questo gioco non espone trofei Steam." : "Trofei aggiornati da Steam"
                let file = root.appendingPathComponent("GameDetails/Trophies/\(cacheOwner)/\(appID).json")
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let bytes = try? JSONEncoder().encode(result) { try? bytes.write(to: file, options: .atomic) }
            } catch { if token == generation && !Task.isCancelled { trophyStatus = trophiesLoaded ? "Ultima lettura disponibile · Steam non ha completato l’aggiornamento" : error.localizedDescription } }
        })
    }
    func accept(_ snapshot: SteamAchievementSnapshot) {
        guard let owner, let appID, (try? snapshot.validate(owner: owner, appID: appID)) != nil else { return }
        trophies = snapshot.achievements; trophiesLoaded = true; trophyStatus = "Trofei aggiornati da Steam"
    }
    var unlocked: Int { trophies.filter(\.unlocked).count }
    var preview: [SteamAchievement] { Array(trophies.sorted { if $0.unlocked != $1.unlocked { return $0.unlocked }; return $0.unlockTime > $1.unlockTime }.prefix(6)) }
}
