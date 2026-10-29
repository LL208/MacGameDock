import AppKit
import SwiftUI

struct GamePreference: Codable {
    var favorite = false
    var hidden = false
    var collection = ""
    var lastPlayed: Date?
    var lastLaunched: Date?
    var confirmedWorking = false
}
struct DeckPreferences: Codable {
    var theme = "Sistema"
    var resumeDownloads = false
    var pauseWhilePlaying = false
    var largeInterface = false
    var onboardingComplete = false
    var storageRoot: String? = nil
    var bandwidthLimitKBPS: Int? = nil
    var bigPicture: Bool? = nil
    var swapControllerConfirmBack: Bool? = nil
}
@MainActor
final class GameExperience: ObservableObject {
    @Published private(set) var games: [String: GamePreference] = [:]
    @Published private(set) var preferences = DeckPreferences()
    @Published private(set) var error: String?
    private let file: URL
    private var writable = true
    private struct Document: Codable { let games: [String: GamePreference]; let preferences: DeckPreferences }
    init(root: URL) {
        file = root.appendingPathComponent("experience.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { let doc = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file)); games = doc.games; preferences = doc.preferences }
            catch { writable = false; self.error = "Preferenze non leggibili: il file originale è conservato." }
        }
    }
    func game(_ game: Game) -> GamePreference { games[game.identity] ?? GamePreference() }
    var collections: [String] { Array(Set(games.values.map(\.collection).filter { !$0.isEmpty })).sorted() }
    func update(_ game: Game, _ change: (inout GamePreference) -> Void) {
        guard writable else { return }
        var updated = games; var value = self.game(game); change(&value); updated[game.identity] = value
        save(games: updated, preferences: preferences)
    }
    func settings(_ change: (inout DeckPreferences) -> Void) {
        guard writable else { return }
        var value = preferences; change(&value); save(games: games, preferences: value)
    }
    private func save(games: [String: GamePreference], preferences: DeckPreferences) {
        do { try JSONEncoder().encode(Document(games: games, preferences: preferences)).write(to: file, options: .atomic); self.games = games; self.preferences = preferences }
        catch { self.error = "Impossibile salvare le preferenze: " + error.localizedDescription }
    }
    func compatibility(_ game: Game) -> String {
        let value = self.game(game)
        if value.confirmedWorking { return "Funzionamento confermato da te" }
        if value.lastLaunched != nil { return "Avviato su questo Mac" }
        return game.isNative ? "Versione Mac · da provare" : "Windows · da provare su questo Mac"
    }
}

struct DeckSettingsView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @EnvironmentObject var library: Library
    @EnvironmentObject var experience: GameExperience
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(L10n.text("Impostazioni")).font(.largeTitle.bold())
                GroupBox(L10n.text("Lingua")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(L10n.text("Lingua"), selection: Binding(get: { appLanguage.preference }, set: { appLanguage.select($0) })) {
                            ForEach(InterfaceLanguage.allCases, id: \.rawValue) { language in
                                Text(language.title).tag(language)
                            }
                        }
                        Text(L10n.text("La lingua cambia subito. Le lingue disponibili sono italiano e inglese; per le altre viene usato l’inglese.")).font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }
                HStack {
                    Text(L10n.text("Interfaccia")).font(.headline)
                    Spacer()
                    Button(L10n.text("PC · mouse e tastiera")) { experience.settings { $0.bigPicture = false } }
                    Button(L10n.text("Big Picture · controller")) { experience.settings { $0.bigPicture = true } }
                }
                ArtworkSettingsView()
                GroupBox(L10n.text("Aspetto e accessibilità")) {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker(L10n.text("Aspetto"), selection: Binding(get: { experience.preferences.theme }, set: { value in experience.settings { $0.theme = value } })) {
                            Text(L10n.text("Sistema")).tag("Sistema"); Text(L10n.text("Scuro")).tag("Scuro"); Text(L10n.text("Chiaro")).tag("Chiaro")
                        }
                        Toggle(L10n.text("Interfaccia più grande"), isOn: Binding(get: { experience.preferences.largeInterface }, set: { value in experience.settings { $0.largeInterface = value } }))
                    }.padding(12)
                }
                GroupBox(L10n.text("Download")) {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker(L10n.text("Limite download giochi Steam"), selection: Binding(get: { experience.preferences.bandwidthLimitKBPS ?? 0 }, set: { value in experience.settings { $0.bandwidthLimitKBPS = value == 0 ? nil : value } })) {
                            Text(L10n.text("Senza limite")).tag(0); Text(L10n.text("1 MiB/s")).tag(1024); Text(L10n.text("5 MiB/s")).tag(5120); Text(L10n.text("10 MiB/s")).tag(10240); Text(L10n.text("25 MiB/s")).tag(25600)
                        }
                        Text(L10n.text("Il limite si applica ai blocchi dei giochi Steam dal prossimo avvio o ripresa del download. I pacchetti del motore e i salvataggi cloud hanno trasferimenti separati.")).font(.caption).foregroundStyle(.secondary)
                        Toggle(L10n.text("Riprendi i download in pausa all’apertura"), isOn: Binding(get: { experience.preferences.resumeDownloads }, set: { value in experience.settings { $0.resumeDownloads = value } }))
                        Toggle(L10n.text("Metti in pausa i download mentre giochi"), isOn: Binding(get: { experience.preferences.pauseWhilePlaying }, set: { value in experience.settings { $0.pauseWhilePlaying = value } }))
                        Text(L10n.text("La pausa conserva i file. Se è in corso l’installazione di un componente, viene prima completato quel passaggio.")).font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }
                GroupBox(L10n.text("Spazio e installazioni")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text(experience.preferences.storageRoot ?? "Cartella dati di MacGameDeck"))
                        if let free = GameStorage.available(at: URL(fileURLWithPath: experience.preferences.storageRoot ?? library.root.path)) { Text(L10n.text("Spazio libero: " + ByteCountFormatter.string(fromByteCount: free, countStyle: .file))).foregroundStyle(.secondary) }
                        HStack {
                            Button(L10n.text("Scegli cartella o disco esterno…")) { library.chooseStorage() }
                            Button(L10n.text("Usa cartella predefinita")) { experience.settings { $0.storageRoot = nil } }
                        }
                        Text(L10n.text("La scelta si applica ai nuovi download. Dalla pagina di un gioco puoi trasferire una copia già installata.")).font(.caption).foregroundStyle(.secondary)
                        Button(L10n.text("Apri copie delle disinstallazioni")) { NSWorkspace.shared.open(library.root.appendingPathComponent("Uninstalled")) }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox(L10n.text("Dati e assistenza")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Button(L10n.text("Apri cartella dati")) { library.openDataFolder() }
                        Button(L10n.text("Apri backup dei salvataggi")) { NSWorkspace.shared.open(library.root.appendingPathComponent("Cloud/Backups")) }
                        Text(L10n.text("I backup dei salvataggi e i container sono separati dalla rimozione di una voce dalla libreria.")).font(.caption).foregroundStyle(.secondary)
                        Text(L10n.text("MacGameDeck 0.10.0 · Anteprima di sviluppo")).font(.caption)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = experience.error { Text(L10n.text(error)).foregroundStyle(.orange) }
            }
        }
    }
}

struct GamePageView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let gameID: UUID
    @EnvironmentObject var library: Library
    @EnvironmentObject var experience: GameExperience
    @EnvironmentObject var activity: PlayActivity
    @EnvironmentObject var social: SteamSocial
    @EnvironmentObject var achievements: AchievementMonitor
    @EnvironmentObject var queue: DownloadQueue
    @EnvironmentObject var steam: ManagedSteam
    @Environment(\.dismiss) private var dismiss
    @StateObject private var detail = GameDetailModel()
    @State private var community = false
    @State private var communityTab = "Trofei"
    @State private var collection = ""
    @State private var uninstall = false
    @State private var versions = false
    private var game: Game? { library.data.games.first { $0.id == gameID } }
    var body: some View {
        Group {
            if let game {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .top, spacing: 22) {
                            GameArtwork(game: game).frame(width: 200, height: 120)
                            VStack(alignment: .leading, spacing: 10) {
                                Text(game.title).font(.largeTitle.bold()).textSelection(.enabled)
                                Text(L10n.text(game.store.rawValue + " · " + experience.compatibility(game))).foregroundStyle(.secondary)
                                HStack {
                                    Button(L10n.text(experience.game(game).favorite ? "Preferito" : "Aggiungi ai preferiti"), systemImage: experience.game(game).favorite ? "star.fill" : "star") { experience.update(game) { $0.favorite.toggle() } }
                                    Spacer(); Button(L10n.text("Chiudi")) { dismiss() }.keyboardShortcut(.cancelAction)
                                }
                            }
                        }
                        HStack {
                            let active = library.running.contains(game.id)
                            let preparing = library.preparingLaunch.contains(game.id)
                            let pending = queue.pending.contains { $0.game.id == game.id }
                            Button(L10n.text(active ? "Torna al gioco" : (pending ? "Download in gestione" : (game.isInstalled ? "Gioca" : "Installa"))), systemImage: "play.fill") {
                                if active { library.activateGame(game) } else { Task { await detail.releaseForLaunch(library: library); if !Task.isCancelled { library.launch(game) } } }
                            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(preparing || pending || detail.releasing || library.maintenance.contains(game.id))
                            if preparing { ProgressView().controlSize(.small); Text(L10n.text(library.launchStages[game.id] ?? "Preparazione…")).font(.callout); Button(L10n.text("Annulla")) { library.cancelLaunch(game) } }
                        }
                        if let job = queue.pending.first(where: { $0.game.id == game.id }) {
                            GroupBox(L10n.text("Download · " + job.state.label)) {
                                VStack(alignment: .leading, spacing: 10) {
                                    if job.state == .active, steam.activeGame == game.id { ProgressView(value: steam.progress); Text(L10n.text(steam.message)).font(.caption) }
                                    if let error = job.error { Text(L10n.text(error)).font(.caption).foregroundStyle(.orange) }
                                    HStack {
                                        if [.active, .queued].contains(job.state) { Button(L10n.text("Pausa")) { queue.pause(job.id) } }
                                        if [.paused, .failed].contains(job.state) { Button(L10n.text("Riprendi")) { queue.resume(job.id) } }
                                        Button(L10n.text("Annulla download"), role: .destructive) { queue.cancel(job.id) }
                                    }
                                }.padding(10)
                            }
                        }
                        if let status = library.gameStatus[game.id] { Label(L10n.text(status), systemImage: "info.circle").font(.callout).textSelection(.enabled) }
                        GameOverviewView(detail: detail)
                        HStack {
                            Button(L10n.text(detail.expandedDescription ? "Riduci descrizione" : "Leggi descrizione completa")) { detail.expandedDescription.toggle() }
                            Spacer()
                            Button(L10n.text("Aggiorna dettagli")) { detail.load(game, library: library) }
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            GameTrophySummary(detail: detail)
                            ForEach(detail.preview) { SteamAchievementRow(achievement: $0) }
                            HStack {
                                Button(L10n.text("Visualizza tutti i trofei")) { communityTab = "Trofei"; community = true }
                                Button(L10n.text("Riprova aggiornamento")) { detail.load(game, library: library) }.disabled(detail.trophiesLoading)
                            }.disabled(game.steamAppID == nil)
                        }.padding(20).background(.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 16))
                        GroupBox(L10n.text("Attività e Steam")) {
                            VStack(alignment: .leading, spacing: 12) {
                                if let status = library.cloudStatuses[game.id] { Label(L10n.text(status), systemImage: "icloud").font(.callout) }
                                Text(L10n.text(activity.label(game)))
                                if let minutes = game.steamMinutes { Text(L10n.text(String(format: "%.1f ore confermate su Steam", Double(minutes) / 60))) }
                                if let date = library.steamConfirmed[game.id] { Text(L10n.text("Ultima lettura Steam: " + date.formatted(date: .abbreviated, time: .shortened))).font(.caption).foregroundStyle(.secondary) }
                                Text(L10n.text(social.connected ? "Connessione Steam attiva" : "Steam non collegato: la conferma online non è disponibile")).font(.caption)
                                if let status = achievements.status[game.id] { Text(L10n.text(status)).font(.caption) }
                                let pending = achievements.pendingCount(game, owner: library.data.steamAccount?.steamID)
                                if pending > 0 { Label(L10n.text("\(pending) trofei ottenuti in attesa di conferma Steam"), systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange) }
                                Button(L10n.text(library.refreshingStats.contains(game.id) ? "Aggiornamento Steam…" : "Aggiorna ore e trofei")) { Task { await library.refreshSteamActivity(game) } }.disabled(game.steamAppID == nil || library.refreshingStats.contains(game.id))
                                HStack {
                                    Button(L10n.text("Trofei")) { communityTab = "Trofei"; community = true }
                                    Button(L10n.text("Salvataggi")) { communityTab = "Cloud"; community = true }
                                    Button(L10n.text("Sincronizza ora")) { Task { await library.syncCloud(game) } }.disabled(library.isBusy(game))
                                    Button(L10n.text("Workshop e mod")) { communityTab = "Workshop"; community = true }
                                }.disabled(game.steamAppID == nil)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        DisclosureGroup("Organizza la libreria") {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack { TextField(L10n.text("Raccolta, ad esempio Da giocare"), text: $collection); Button(L10n.text("Salva raccolta")) { experience.update(game) { $0.collection = collection.trimmingCharacters(in: .whitespacesAndNewlines) } } }
                                Toggle(L10n.text("Ho verificato che il gioco funziona"), isOn: Binding(get: { experience.game(game).confirmedWorking }, set: { value in experience.update(game) { $0.confirmedWorking = value } }))
                                Toggle(L10n.text("Nascondi dalla libreria"), isOn: Binding(get: { experience.game(game).hidden }, set: { value in experience.update(game) { $0.hidden = value } }))
                            }.padding(12)
                        }
                        DisclosureGroup("Installazione e opzioni avanzate") {
                            VStack(alignment: .leading, spacing: 12) {
                                if game.isInstalled {
                                    Button(L10n.text("Mostra file")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.installDirectory ?? game.executablePath)]) }
                                    Button(L10n.text("Verifica file e ripara componenti")) { library.repair(game) }.disabled(library.isBusy(game))
                                    Button(L10n.text("Trasferisci su un altro disco…")) { library.moveInstallation(game) }.disabled(library.isBusy(game) || !library.canUninstall(game))
                                    Button(L10n.text("Disinstalla…"), role: .destructive) { uninstall = true }.disabled(library.isBusy(game) || !library.canUninstall(game))
                                    Text(L10n.text("La disinstallazione è disponibile per le copie scaricate da MacGameDeck. Crea prima un backup dei file del gioco e conserva il container Windows.")).font(.caption).foregroundStyle(.secondary)
                                }
                                if game.steamAppID != nil { Button(L10n.text("Versioni e requisiti")) { versions = true } }
                                if !game.isNative { Button(L10n.text("Apri log del gioco")) { library.openLog(game) }; Button(L10n.text(achievements.isDisabled(game) ? "Attiva integrazione trofei" : "Ripristina Steam API originale")) { library.restoreSteamAPI(game) }.disabled(library.isBusy(game)) }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(28)
                }.onAppear { collection = experience.game(game).collection }
                .task(id: game.identity + (library.data.steamAccount?.steamID ?? "guest") + appLanguage.code) { detail.load(game, library: library) }
                .onDisappear { detail.cancel() }
                .onReceive(achievements.$snapshots) { values in if let id = game.steamAppID, let snapshot = values[id] { detail.accept(snapshot) } }
                .confirmationDialog(L10n.text("Disinstallare \(game.title)?"), isPresented: $uninstall, titleVisibility: .visible) {
                    Button(L10n.text("Crea backup e disinstalla"), role: .destructive) { library.uninstall(game) }
                    Button(L10n.text("Annulla"), role: .cancel) {}
                } message: { Text(L10n.text("I file vengono spostati nel backup locale, senza essere eliminati definitivamente. Il gioco resterà nella libreria e potrà essere reinstallato. Il backup continuerà a occupare spazio fino alla sua eliminazione manuale.")) }
                .sheet(isPresented: $community) { GameCommunityView(game: game, initialTab: communityTab) }
                .sheet(isPresented: $versions) { GameDetailsView(game: game) }
            } else { Text(L10n.text("Gioco non più presente nella libreria.")).padding() }
        }.frame(minWidth: 820, minHeight: 680)
    }
}
