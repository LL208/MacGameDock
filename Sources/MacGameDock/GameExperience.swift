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
    @EnvironmentObject var library: Library
    @EnvironmentObject var experience: GameExperience
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Impostazioni").font(.largeTitle.bold())
                HStack {
                    Text("Interfaccia").font(.headline)
                    Spacer()
                    Button("PC · mouse e tastiera") { experience.settings { $0.bigPicture = false } }
                    Button("Big Picture · controller") { experience.settings { $0.bigPicture = true } }
                }
                ArtworkSettingsView()
                GroupBox("Aspetto e accessibilità") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Aspetto", selection: Binding(get: { experience.preferences.theme }, set: { value in experience.settings { $0.theme = value } })) {
                            Text("Sistema").tag("Sistema"); Text("Scuro").tag("Scuro"); Text("Chiaro").tag("Chiaro")
                        }
                        Toggle("Interfaccia più grande", isOn: Binding(get: { experience.preferences.largeInterface }, set: { value in experience.settings { $0.largeInterface = value } }))
                    }.padding(12)
                }
                GroupBox("Download") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Limite download giochi Steam", selection: Binding(get: { experience.preferences.bandwidthLimitKBPS ?? 0 }, set: { value in experience.settings { $0.bandwidthLimitKBPS = value == 0 ? nil : value } })) {
                            Text("Senza limite").tag(0); Text("1 MiB/s").tag(1024); Text("5 MiB/s").tag(5120); Text("10 MiB/s").tag(10240); Text("25 MiB/s").tag(25600)
                        }
                        Text("Il limite si applica ai blocchi dei giochi Steam dal prossimo avvio o ripresa del download. I pacchetti del motore e i salvataggi cloud hanno trasferimenti separati.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Riprendi i download in pausa all’apertura", isOn: Binding(get: { experience.preferences.resumeDownloads }, set: { value in experience.settings { $0.resumeDownloads = value } }))
                        Toggle("Metti in pausa i download mentre giochi", isOn: Binding(get: { experience.preferences.pauseWhilePlaying }, set: { value in experience.settings { $0.pauseWhilePlaying = value } }))
                        Text("La pausa conserva i file. Se è in corso l’installazione di un componente, viene prima completato quel passaggio.").font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }
                GroupBox("Spazio e installazioni") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(experience.preferences.storageRoot ?? "Cartella dati di MacGameDeck")
                        if let free = GameStorage.available(at: URL(fileURLWithPath: experience.preferences.storageRoot ?? library.root.path)) { Text("Spazio libero: " + ByteCountFormatter.string(fromByteCount: free, countStyle: .file)).foregroundStyle(.secondary) }
                        HStack {
                            Button("Scegli cartella o disco esterno…") { library.chooseStorage() }
                            Button("Usa cartella predefinita") { experience.settings { $0.storageRoot = nil } }
                        }
                        Text("La scelta si applica ai nuovi download. Dalla pagina di un gioco puoi trasferire una copia già installata.").font(.caption).foregroundStyle(.secondary)
                        Button("Apri copie delle disinstallazioni") { NSWorkspace.shared.open(library.root.appendingPathComponent("Uninstalled")) }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Dati e assistenza") {
                    VStack(alignment: .leading, spacing: 12) {
                        Button("Apri cartella dati") { library.openDataFolder() }
                        Button("Apri backup dei salvataggi") { NSWorkspace.shared.open(library.root.appendingPathComponent("Cloud/Backups")) }
                        Text("I backup dei salvataggi e i container sono separati dalla rimozione di una voce dalla libreria.").font(.caption).foregroundStyle(.secondary)
                        Text("MacGameDeck 0.10.0 · Anteprima di sviluppo").font(.caption)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = experience.error { Text(error).foregroundStyle(.orange) }
            }
        }
    }
}

struct GamePageView: View {
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
                                Text(game.store.rawValue + " · " + experience.compatibility(game)).foregroundStyle(.secondary)
                                HStack {
                                    Button(experience.game(game).favorite ? "Preferito" : "Aggiungi ai preferiti", systemImage: experience.game(game).favorite ? "star.fill" : "star") { experience.update(game) { $0.favorite.toggle() } }
                                    Spacer(); Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
                                }
                            }
                        }
                        HStack {
                            let active = library.running.contains(game.id)
                            let preparing = library.preparingLaunch.contains(game.id)
                            let pending = queue.pending.contains { $0.game.id == game.id }
                            Button(active ? "Torna al gioco" : (pending ? "Download in gestione" : (game.isInstalled ? "Gioca" : "Installa")), systemImage: "play.fill") {
                                if active { library.activateGame(game) } else { Task { await detail.releaseForLaunch(library: library); if !Task.isCancelled { library.launch(game) } } }
                            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(preparing || pending || detail.releasing || library.maintenance.contains(game.id))
                            if preparing { ProgressView().controlSize(.small); Text(library.launchStages[game.id] ?? "Preparazione…").font(.callout); Button("Annulla") { library.cancelLaunch(game) } }
                        }
                        if let job = queue.pending.first(where: { $0.game.id == game.id }) {
                            GroupBox("Download · " + job.state.label) {
                                VStack(alignment: .leading, spacing: 10) {
                                    if job.state == .active, steam.activeGame == game.id { ProgressView(value: steam.progress); Text(steam.message).font(.caption) }
                                    if let error = job.error { Text(error).font(.caption).foregroundStyle(.orange) }
                                    HStack {
                                        if [.active, .queued].contains(job.state) { Button("Pausa") { queue.pause(job.id) } }
                                        if [.paused, .failed].contains(job.state) { Button("Riprendi") { queue.resume(job.id) } }
                                        Button("Annulla download", role: .destructive) { queue.cancel(job.id) }
                                    }
                                }.padding(10)
                            }
                        }
                        if let status = library.gameStatus[game.id] { Label(status, systemImage: "info.circle").font(.callout).textSelection(.enabled) }
                        GameOverviewView(detail: detail)
                        HStack {
                            Button(detail.expandedDescription ? "Riduci descrizione" : "Leggi descrizione completa") { detail.expandedDescription.toggle() }
                            Spacer()
                            Button("Aggiorna dettagli") { detail.load(game, library: library) }
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            GameTrophySummary(detail: detail)
                            ForEach(detail.preview) { SteamAchievementRow(achievement: $0) }
                            HStack {
                                Button("Visualizza tutti i trofei") { communityTab = "Trofei"; community = true }
                                Button("Riprova aggiornamento") { detail.load(game, library: library) }.disabled(detail.trophiesLoading)
                            }.disabled(game.steamAppID == nil)
                        }.padding(20).background(.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 16))
                        GroupBox("Attività e Steam") {
                            VStack(alignment: .leading, spacing: 12) {
                                if let status = library.cloudStatuses[game.id] { Label(status, systemImage: "icloud").font(.callout) }
                                Text(activity.label(game))
                                if let minutes = game.steamMinutes { Text(String(format: "%.1f ore confermate su Steam", Double(minutes) / 60)) }
                                if let date = library.steamConfirmed[game.id] { Text("Ultima lettura Steam: " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                                Text(social.connected ? "Connessione Steam attiva" : "Steam non collegato: la conferma online non è disponibile").font(.caption)
                                if let status = achievements.status[game.id] { Text(status).font(.caption) }
                                let pending = achievements.pendingCount(game, owner: library.data.steamAccount?.steamID)
                                if pending > 0 { Label("\(pending) trofei ottenuti in attesa di conferma Steam", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange) }
                                Button(library.refreshingStats.contains(game.id) ? "Aggiornamento Steam…" : "Aggiorna ore e trofei") { Task { await library.refreshSteamActivity(game) } }.disabled(game.steamAppID == nil || library.refreshingStats.contains(game.id))
                                HStack {
                                    Button("Trofei") { communityTab = "Trofei"; community = true }
                                    Button("Salvataggi") { communityTab = "Cloud"; community = true }
                                    Button("Sincronizza ora") { Task { await library.syncCloud(game) } }.disabled(library.isBusy(game))
                                    Button("Workshop e mod") { communityTab = "Workshop"; community = true }
                                }.disabled(game.steamAppID == nil)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        DisclosureGroup("Organizza la libreria") {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack { TextField("Raccolta, ad esempio Da giocare", text: $collection); Button("Salva raccolta") { experience.update(game) { $0.collection = collection.trimmingCharacters(in: .whitespacesAndNewlines) } } }
                                Toggle("Ho verificato che il gioco funziona", isOn: Binding(get: { experience.game(game).confirmedWorking }, set: { value in experience.update(game) { $0.confirmedWorking = value } }))
                                Toggle("Nascondi dalla libreria", isOn: Binding(get: { experience.game(game).hidden }, set: { value in experience.update(game) { $0.hidden = value } }))
                            }.padding(12)
                        }
                        DisclosureGroup("Installazione e opzioni avanzate") {
                            VStack(alignment: .leading, spacing: 12) {
                                if game.isInstalled {
                                    Button("Mostra file") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.installDirectory ?? game.executablePath)]) }
                                    Button("Verifica file e ripara componenti") { library.repair(game) }.disabled(library.isBusy(game))
                                    Button("Trasferisci su un altro disco…") { library.moveInstallation(game) }.disabled(library.isBusy(game) || !library.canUninstall(game))
                                    Button("Disinstalla…", role: .destructive) { uninstall = true }.disabled(library.isBusy(game) || !library.canUninstall(game))
                                    Text("La disinstallazione è disponibile per le copie scaricate da MacGameDeck. Crea prima un backup dei file del gioco e conserva il container Windows.").font(.caption).foregroundStyle(.secondary)
                                }
                                if game.steamAppID != nil { Button("Versioni e requisiti") { versions = true } }
                                if !game.isNative { Button("Apri log del gioco") { library.openLog(game) }; Button(achievements.isDisabled(game) ? "Attiva integrazione trofei" : "Ripristina Steam API originale") { library.restoreSteamAPI(game) }.disabled(library.isBusy(game)) }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(28)
                }.onAppear { collection = experience.game(game).collection }
                .task(id: game.identity + (library.data.steamAccount?.steamID ?? "guest")) { detail.load(game, library: library) }
                .onDisappear { detail.cancel() }
                .onReceive(achievements.$snapshots) { values in if let id = game.steamAppID, let snapshot = values[id] { detail.accept(snapshot) } }
                .confirmationDialog("Disinstallare \(game.title)?", isPresented: $uninstall, titleVisibility: .visible) {
                    Button("Crea backup e disinstalla", role: .destructive) { library.uninstall(game) }
                    Button("Annulla", role: .cancel) {}
                } message: { Text("I file vengono spostati nel backup locale, senza essere eliminati definitivamente. Il gioco resterà nella libreria e potrà essere reinstallato. Il backup continuerà a occupare spazio fino alla sua eliminazione manuale.") }
                .sheet(isPresented: $community) { GameCommunityView(game: game, initialTab: communityTab) }
                .sheet(isPresented: $versions) { GameDetailsView(game: game) }
            } else { Text("Gioco non più presente nella libreria.").padding() }
        }.frame(minWidth: 820, minHeight: 680)
    }
}
