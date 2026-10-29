import AppKit
import SwiftUI

enum DeckPage: Equatable {
    case home, library, downloads, account, controllers, settings, logs
    case game(UUID), install(UUID), trophies(UUID), cloud(UUID), workshop(UUID), mods(UUID)
    var key: String { String(describing: self) }
    static let sections: [DeckPage] = [.home, .library, .downloads, .account, .controllers, .settings, .logs]
    var title: String {
        switch self {
        case .home: return "Continua a giocare"
        case .library: return "Libreria"
        case .downloads: return "Download"
        case .account: return "Account Steam"
        case .controllers: return "Controller"
        case .settings: return "Impostazioni"
        case .logs: return "Log e assistenza"
        case .game: return "Il tuo gioco"
        case .install: return "Installa il gioco"
        case .trophies: return "Trofei"
        case .cloud: return "Salvataggi Steam Cloud"
        case .workshop: return "Workshop"
        case .mods: return "Mod installate"
        }
    }
    var gameID: UUID? {
        switch self { case .game(let id), .install(let id), .trophies(let id), .cloud(let id), .workshop(let id), .mods(let id): return id; default: return nil }
    }
}
struct DeckAction: Identifiable {
    let id: String
    let title: String
    var detail = ""
    var symbol = "chevron.right"
    var enabled = true
    var game: Game?
    var achievement: SteamAchievement?
    let run: () -> Void
}
struct DeckKeyboard {
    let title: String
    var text: String
    var selected = 0
    var secure = false
    var lowercase = false
    let submit: (String) -> Void
    static let keys = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789àèéìòù-_'./:").map(String.init) + ["Spazio", "⇧", "⌫", "Cancella", "Conferma", "Annulla"]
    static let columns = 10
}
struct DeckFolderPicker {
    enum Purpose { case folder, game }
    let title: String
    var current: URL
    let purpose: Purpose
    let select: (URL) -> Void
}
@MainActor
final class BigPictureModel: ObservableObject {
    @Published var page: DeckPage = .home
    @Published var selected: [String: String] = [:]
    @Published var pageNumber = 0
    @Published var search = ""
    @Published var store = "Tutti"
    @Published var installedOnly = false
    @Published var favoritesOnly = false
    @Published var hidden = false
    @Published var collection = "Tutte"
    @Published var sort = "Titolo"
    @Published var keyboard: DeckKeyboard?
    @Published var picker: DeckFolderPicker?
    @Published var confirmation: String?
    var confirmAction: (() -> Void)?
    @Published var status = ""
    @Published var loading = false
    @Published var trophies: [SteamAchievement] = []
    @Published var saves: [SteamCloudInventory.File] = []
    @Published var workshop: [SteamWorkshopItem] = []
    @Published var downloadedMod: URL?
    @Published var insights: GameInsights?
    @Published var workshopQuery = ""
    @Published var trophyFilter = "Tutti"
    @Published var logPage = 0
    @Published var logText = ""
    private var history: [(DeckPage, Int)] = []
    private var loader: Task<Void, Never>?
    private var ownsSteam = false
    private var request = UUID()
    var onCancelSteam: (() -> Void)?
    func navigate(_ page: DeckPage, replacing: Bool = false) {
        cancelLoading()
        if !replacing { history.append((self.page, pageNumber)) }
        self.page = page; pageNumber = 0; status = ""; trophies = []; saves = []; workshop = []; insights = nil; downloadedMod = nil
    }
    func back() {
        if keyboard != nil { keyboard = nil; return }
        if picker != nil { picker = nil; return }
        if confirmation != nil { confirmation = nil; confirmAction = nil; return }
        cancelLoading()
        let previous = history.popLast(); page = previous?.0 ?? .home; pageNumber = previous?.1 ?? 0
        status = ""; trophies = []; saves = []; workshop = []; insights = nil
    }
    func section(_ step: Int) {
        let index = DeckPage.sections.firstIndex(of: page) ?? 0
        navigate(DeckPage.sections[(index + step + DeckPage.sections.count) % DeckPage.sections.count], replacing: true)
    }
    func ask(_ text: String, run: @escaping () -> Void) { confirmation = text; confirmAction = run; selected["dialog"] = "cancel" }
    func cancelLoading() {
        request = UUID(); loader?.cancel(); loader = nil
        if ownsSteam { onCancelSteam?() }; ownsSteam = false; loading = false
    }
    func load(library: Library) {
        switch page { case .install, .trophies, .cloud, .workshop: break; default: return }
        guard let id = page.gameID, let game = library.data.games.first(where: { $0.id == id }) else { return }
        cancelLoading(); let token = UUID(); request = token
        let target = page; let pageIndex = pageNumber; let query = workshopQuery
        loading = true; status = "Caricamento…"
        loader = Task {
            defer { if request == token { loading = false; ownsSteam = false } }
            do {
                if case .install = target {
                    if let appID = game.steamAppID { let result = try await GameInsights.fetch(appID: appID); if request == token { insights = result; status = "Scegli la versione da installare" } }
                    return
                }
                guard let owner = library.data.steamAccount?.steamID else { throw DockError.message("Collega Steam dalla sezione Account per caricare questi dati.") }
                let deadline = ProcessInfo.processInfo.systemUptime + 90
                while library.managedSteam.busy || library.managedSteam.preparing || library.signingIn {
                    if request == token { status = "Attendo che termini l’operazione Steam in corso…" }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw DockError.message("Steam è ancora occupato. Puoi riprovare con Aggiorna.") }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                try Task.checkCancellation(); guard request == token else { return }
                ownsSteam = true
                switch target {
                case .trophies:
                    let result = try await library.managedSteam.achievements(game, expected: owner)
                    guard request == token, library.data.steamAccount?.steamID == owner else { return }; trophies = result.achievements; status = "Trofei letti da Steam"
                case .cloud:
                    let result = try await library.managedSteam.cloudInventory(game, expected: owner)
                    guard request == token, library.data.steamAccount?.steamID == owner else { return }; saves = result.liveFiles; status = "\(saves.count) salvataggi nel cloud"
                case .workshop:
                    let result = try await library.managedSteam.workshop(game, expected: owner, search: query, page: pageIndex + 1)
                    guard request == token, library.data.steamAccount?.steamID == owner else { return }; workshop = result.items; status = "Pagina \(result.page) · \(result.total) mod"
                default: status = ""
                }
            } catch is CancellationError {} catch { if request == token { status = error.localizedDescription } }
        }
    }
    func downloadMod(_ item: SteamWorkshopItem, game: Game, library: Library) {
        guard !loading, !library.running.contains(game.id), !library.isBusy(game) else { status = "Chiudi il gioco prima di installare una mod."; return }
        cancelLoading(); let token = UUID(); request = token; loading = true; downloadedMod = nil
        loader = Task {
            defer { if request == token { loading = false; ownsSteam = false } }
            do {
                let id = try WorkshopInput.itemID(item.id)
                var query = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
                query.httpMethod = "POST"; query.timeoutInterval = 30; query.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                query.httpBody = Data("itemcount=1&publishedfileids%5B0%5D=\(id)".utf8)
                let (bytes, response) = try await URLSession.shared.data(for: query)
                guard (response as? HTTPURLResponse)?.statusCode == 200, bytes.count <= 4_000_000 else { throw DockError.message("Il Workshop non ha risposto correttamente.") }
                _ = try WorkshopInput.validate(bytes, appID: game.steamAppID ?? 0, itemID: id)
                try Task.checkCancellation()
                guard let owner = library.data.steamAccount?.steamID, !library.managedSteam.busy, !library.managedSteam.preparing, !library.signingIn else { throw DockError.message("Attendi l’operazione Steam in corso e riprova.") }
                let directory = library.root.appendingPathComponent("Workshop/\(game.steamAppID ?? 0)/\(id)/\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                ownsSteam = true; status = "Scarico \(item.title)…"
                _ = try await library.managedSteam.run(["-app", String(game.steamAppID ?? 0), "-pubfile", id, "-dir", directory.path, "-validate"], expected: owner)
                try Task.checkCancellation()
                guard request == token, library.data.steamAccount?.steamID == owner else { return }
                guard !(try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty else { throw DockError.message("La mod non contiene file scaricati.") }
                downloadedMod = directory; status = "Mod scaricata. Scegli la cartella prevista dall’autore per installarla."
            } catch is CancellationError {} catch { if request == token { status = error.localizedDescription } }
        }
    }
    func installMod(_ source: URL, in target: URL, game: Game, library: Library) {
        guard !library.isBusy(game) else { status = "Chiudi il gioco prima di modificare le mod."; return }
        do {
            let src = source.resolvingSymlinksInPath().path, dst = target.resolvingSymlinksInPath().path
            guard src != dst, !dst.hasPrefix(src + "/") else { throw DockError.message("Scegli una cartella diversa dal download.") }
            try SteamCloudRestore.rejectSymlinks(target)
            guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { throw DockError.message("Download non leggibile.") }
            for case let file as URL in enumerator { if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw DockError.message("La mod contiene collegamenti simbolici non supportati.") } }
            let destination = target.appendingPathComponent("MacGameDeck-Mod-\(UUID().uuidString.prefix(8))")
            try FileManager.default.copyItem(at: source, to: destination)
            do { let itemID = source.deletingLastPathComponent().lastPathComponent; try library.mods.register(game: game, itemID: itemID, title: workshop.first(where: { $0.id == itemID })?.title ?? "Mod " + itemID, destination: destination) }
            catch { try? FileManager.default.removeItem(at: destination); throw error }
            status = "Mod registrata. La sua attivazione dipende dal formato e dal loader richiesto dal gioco."
        } catch { status = error.localizedDescription }
    }
}
