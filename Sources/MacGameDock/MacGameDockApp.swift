import AppKit
import SwiftUI

final class MacGameDeckDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct MacGameDockApp: App {
    @NSApplicationDelegateAdaptor(MacGameDeckDelegate.self) private var appDelegate
    @StateObject private var library = Library()
    var body: some Scene {
        WindowGroup {
            DeckRootView().environmentObject(library).environmentObject(library.managedSteam).environmentObject(library.downloads).environmentObject(library.activity).environmentObject(library.social).environmentObject(library.achievements).environmentObject(library.experience).environmentObject(library.mods).environmentObject(library.artwork)
                .frame(minWidth: 940, minHeight: 650)

        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Interfaccia") {
                Button("Alterna modalità PC / Big Picture") { library.experience.settings { $0.bigPicture = !($0.bigPicture != false) } }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("Aggiungi gioco…") { library.importGame(store: .local) }
                    .keyboardShortcut("o")
            }
        }
    }
}

struct DockView: View {
    @EnvironmentObject var library: Library
    @State private var section = "Continua a giocare"
    @State private var selectedGame: Game?
    @State private var sort = "Titolo"
    @State private var collection = "Tutte"
    @State private var showHidden = false
    @State private var completedDownload: Game?
    @State private var seenCompletions: Set<UUID> = []
    @EnvironmentObject var experience: GameExperience
    @State private var search = ""
    @State private var importStore: GameStore = .steam
    @State private var removing: Game?
    @State private var community: Game?
    @EnvironmentObject var activity: PlayActivity
    @State private var installedOnly = false
    @State private var familyOnly = false
    @EnvironmentObject var social: SteamSocial
    @EnvironmentObject var achievements: AchievementMonitor
    @EnvironmentObject var queue: DownloadQueue

    private var filtered: [Game] {
        library.visibleGames(installedOnly: installedOnly).filter {
            (["Libreria", "Continua a giocare", "Preferiti"].contains(section) || $0.store.rawValue == section) &&
            (section != "Preferiti" || experience.game($0).favorite) &&
            (section != "Continua a giocare" || $0.isInstalled || experience.game($0).lastPlayed != nil) &&
            (showHidden || !experience.game($0).hidden) &&
            (collection == "Tutte" || experience.game($0).collection == collection) &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) && (!familyOnly || $0.isFamilyShared)
        }.sorted {
            if section == "Continua a giocare" || sort == "Ultima partita" {
                let a = experience.game($0).lastPlayed ?? .distantPast, b = experience.game($1).lastPlayed ?? .distantPast
                if a != b { return a > b }
            } else if sort == "Ore su Steam", $0.steamMinutes != $1.steamMinutes { return ($0.steamMinutes ?? -1) > ($1.steamMinutes ?? -1) }
            else if sort == "Aggiunti di recente", $0.addedAt != $1.addedAt { return $0.addedAt > $1.addedAt }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                Label("MacGameDeck", systemImage: "gamecontroller.fill")
                    .font(.title3.bold()).padding(.top, 20)
                VStack(spacing: 8) {
                    navigation("Continua a giocare", icon: "clock.fill")
                    navigation("Preferiti", icon: "star.fill")
                    navigation("Libreria", icon: "square.grid.2x2.fill")
                    ForEach(GameStore.allCases) { store in
                        navigation(store.rawValue, icon: "shippingbox")
                    }
                    Divider().padding(.vertical, 8)
                    navigation("Download", icon: "arrow.down.circle.fill")
                    navigation("Account Steam", icon: "person.crop.circle")
                    navigation("Controller", icon: "gamecontroller")
                    navigation("Log", icon: "doc.text.magnifyingglass")
                    navigation("Il tuo Mac", icon: "desktopcomputer")
                    navigation("Impostazioni", icon: "gearshape.fill")
                    Button("Modalità controller", systemImage: "tv") { experience.settings { $0.bigPicture = true } }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    Text(library.machine.chip).font(.subheadline.bold())
                    Text("\(library.machine.memoryGB) GB · \(library.machine.architecture)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Anteprima di sviluppo · 0.13.0").font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(20).frame(width: 210)
                .background(Color.primary.opacity(0.035))
            Divider()
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Spacer()
                    Button("Big Picture", systemImage: "tv") { experience.settings { $0.bigPicture = true } }
                        .help("Passa a Big Picture · ⌘⇧B")
                }
                if section == "Impostazioni" { DeckSettingsView() }
                else if section == "Il tuo Mac" { machineView }
                else if section == "Controller" { ControllersView() }
                else if section == "Log" { LogsView() }
                else if section == "Download" { DownloadsView() }
                else if section == "Account Steam" { SteamAccountView() }
                else { libraryView }
            }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .preferredColorScheme(experience.preferences.theme == "Scuro" ? .dark : (experience.preferences.theme == "Chiaro" ? .light : nil))
        .font(experience.preferences.largeInterface ? .title3 : .body)
        .sheet(item: $selectedGame) { game in GamePageView(gameID: game.id) }
        .onReceive(queue.$jobs) { jobs in
            let completed = jobs.filter { $0.state == .completed && ($0.finishedAt ?? .distantPast) > Date().addingTimeInterval(-120) && !seenCompletions.contains($0.id) }
            for job in completed { seenCompletions.insert(job.id); completedDownload = library.data.games.first { $0.id == job.game.id } }
        }
        .safeAreaInset(edge: .bottom) { VStack(spacing: 0) {
            if let game = completedDownload {
                HStack { Label(game.title + " è pronto", systemImage: "checkmark.circle.fill").foregroundStyle(.mint); Spacer(); Button("Gioca") { completedDownload = nil; library.launch(game) }; Button("Chiudi") { completedDownload = nil } }.padding(12)
            }
            OwnedRuntimeStatus(engine: library.engine); SteamOperationView() } }
        .sheet(item: $library.installSelection) { game in
            GameDetailsView(game: game).environmentObject(library)
        }
        .sheet(item: $community) { game in GameCommunityView(game: game).environmentObject(library).environmentObject(library.managedSteam).environmentObject(library.social).environmentObject(library.achievements) }
        .onChange(of: section) { _ in familyOnly = false; collection = "Tutte" }
        .tint(.mint)
        .alert(library.cloudLaunchFailure == nil ? "Impossibile completare l’operazione" : "Salvataggi Steam Cloud non disponibili", isPresented: Binding(
            get: { library.error != nil }, set: { if !$0 { library.error = nil } }
        )) {
            if let game = library.cloudLaunchFailure { Button("Riprova") { library.error = nil; library.cloudLaunchFailure = nil; library.launch(game) }; Button("Gioca con i salvataggi locali") { library.launchWithLocalSaves(game) } }
            Button("Apri log") { section = "Log"; library.error = nil; library.cloudLaunchFailure = nil }
            Button("OK") { library.error = nil; library.cloudLaunchFailure = nil }
        } message: { Text(library.error ?? "") }
        .sheet(isPresented: Binding(
            get: { library.notice != nil }, set: { if !$0 { library.notice = nil } }
        )) {
            VStack(spacing: 20) {
                Text(library.notice ?? "").frame(maxWidth: 360)
                Button("OK") { library.notice = nil }
            }.padding(32)
        }
        .confirmationDialog("Rimuovere il gioco dalla libreria?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            Button("Rimuovi", role: .destructive) {
                if let game = removing { library.remove(game) }
                removing = nil
            }
            Button("Annulla", role: .cancel) { removing = nil }
        } message: { Text("I file del gioco, i salvataggi e l'ambiente Wine saranno conservati.") }
    }

    private func navigation(_ title: String, icon: String) -> some View {
        Button { section = title } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if !["Log", "Controller", "Il tuo Mac", "Account Steam", "Download", "Impostazioni", "Continua a giocare", "Preferiti"].contains(title) {
                    Text("\(library.visibleGames(installedOnly: false).filter { title == "Libreria" || $0.store.rawValue == title }.count)")
                        .foregroundStyle(.secondary).font(.caption)
                }
            }.padding(11).contentShape(Rectangle())
                .background(section == title ? Color.mint.opacity(0.13) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    private var libraryView: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(section).font(.largeTitle.bold())
                    Text(section == "Continua a giocare" ? "I giochi recenti sono sempre a portata di mano." : "I tuoi giochi, un solo punto di partenza.").foregroundStyle(.secondary)
                }
                Spacer()
                if section == "Steam" {
                    SteamProfileHeader()
                } else {
                    Picker("Store", selection: $importStore) { ForEach(GameStore.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 160)
                    Button { library.importGame(store: importStore) } label: { Label("Aggiungi gioco", systemImage: "plus") }.buttonStyle(.borderedProminent)
                }

            }
            HStack {
                Picker("Mostra", selection: $installedOnly) {
                    Text("Tutti").tag(false)
                    Text("Installati").tag(true)
                }.pickerStyle(.segmented).frame(width: 220)
                if section == "Steam" || section == "Libreria" { Toggle("Famiglia", isOn: $familyOnly).toggleStyle(.checkbox) }
                Spacer()
                if library.scanning { ProgressView().controlSize(.small) }
                Button { Task { await library.scanInstalledGames() } } label: {
                    Label("Rileva giochi", systemImage: "arrow.clockwise")
                }.disabled(library.scanning)
                Button(library.data.steamAccount == nil ? "Collega Steam" : "Account Steam") { section = "Account Steam" }
            }
            if !library.scanSummary.isEmpty {
                Text(library.scanSummary).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Cerca nella libreria", text: $search).textFieldStyle(.roundedBorder).accessibilityLabel("Cerca un gioco")
                Picker("Ordina", selection: $sort) { Text("Titolo").tag("Titolo"); Text("Ultima partita").tag("Ultima partita"); Text("Ore su Steam").tag("Ore su Steam"); Text("Aggiunti di recente").tag("Aggiunti di recente") }.frame(width: 200)
                Menu {
                    Picker("Raccolta", selection: $collection) { Text("Tutte").tag("Tutte"); ForEach(experience.collections, id: \.self) { Text($0).tag($0) } }
                    Toggle("Mostra giochi nascosti", isOn: $showHidden)
                } label: { Label("Filtri", systemImage: "line.3.horizontal.decrease.circle") }
            }
            if !experience.preferences.onboardingComplete {
                GroupBox("Benvenuto in MacGameDeck") {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("1. Collega Steam o rileva i giochi già installati.  2. Scegli un gioco.  3. Premi Gioca: i componenti Windows si preparano automaticamente.")
                            Text("Dalla pagina del gioco puoi controllare salvataggi, trofei e compatibilità.").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Ho capito") { experience.settings { $0.onboardingComplete = true } }
                    }.padding(10)
                }
            }
            if filtered.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "gamecontroller").font(.system(size: 54)).foregroundStyle(.mint)
                    Text(library.data.games.isEmpty ? "Il primo gioco ti aspetta" : "Nessun gioco trovato")
                        .font(.title2.bold())
                    Text("Rileva i giochi locali o collega Steam per vedere il catalogo dell'account.")
                        .foregroundStyle(.secondary)
                    if library.data.games.isEmpty {
                        Button("Collega Steam") { section = "Account Steam" }
                            .buttonStyle(.bordered)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 18)], spacing: 18) {
                        ForEach(filtered) { game in gameCard(game) }
                    }.padding(.bottom, 10)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func gameCard(_ game: Game) -> some View {
        let active = library.running.contains(game.id)
        let restoring = library.preparingLaunch.contains(game.id)
        let pending = queue.jobs.last(where: { $0.game.id == game.id && [.queued, .active, .paused].contains($0.state) })
        let storeManaged = game.launchURL != nil || game.steamAppID != nil
        return VStack(alignment: .leading, spacing: 14) {
            ZStack {
                LinearGradient(colors: [.mint.opacity(0.3), .indigo.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: game.isNative ? "apple.logo" : "gamecontroller.fill")
                    .font(.system(size: 44)).foregroundStyle(.white.opacity(0.9))
                if let id = game.steamAppID {
                    AsyncImage(url: URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/header.jpg")) { image in
                        image.resizable().scaledToFill()
                    } placeholder: { Color.clear }
                }
            }.frame(height: 120).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(alignment: .top) {
                Button { selectedGame = game } label: { Text(game.title).font(.title3.bold()).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                Button { experience.update(game) { $0.favorite.toggle() } } label: { Image(systemName: experience.game(game).favorite ? "star.fill" : "star").foregroundStyle(experience.game(game).favorite ? Color.yellow : Color.secondary) }.buttonStyle(.plain).accessibilityLabel("Preferito: " + game.title)
            }
                .help(game.executablePath)
            Text("\(game.store.rawValue) · \(game.isInstalled ? "Installato" : "Da installare")")
                .font(.caption).foregroundStyle(.secondary)
            Label(experience.compatibility(game), systemImage: experience.game(game).confirmedWorking ? "checkmark.circle" : "questionmark.circle")
                .font(.caption).foregroundStyle(experience.game(game).confirmedWorking ? Color.mint : Color.secondary)
            if let minutes = game.steamMinutes {
                Text(String(format: "%.1f ore su Steam", Double(minutes) / 60)).font(.caption).foregroundStyle(.secondary)
            }
            if let unlocked = game.steamAchievementsUnlocked, let total = game.steamAchievementsTotal {
                Label("\(unlocked) / \(total) trofei su Steam", systemImage: "trophy").font(.caption).foregroundStyle(.secondary)
            }
            Text(activity.label(game)).font(.caption).foregroundStyle(.secondary)
                .help("Tempo locale dei processi monitorati da MacGameDeck, senza sincronizzazione con Steam.")
            if let status = achievements.status[game.id] { Text(status).font(.caption2).foregroundStyle(.secondary) }
            if let error = activity.storageError { Text(error).font(.caption).foregroundStyle(.orange) }
            if game.isFamilyShared { Label("Famiglia Steam", systemImage: "person.2.fill").font(.caption).foregroundStyle(.mint) }
            if let stage = library.launchStages[game.id] { Text(stage).font(.caption).foregroundStyle(.mint) }
            if let status = library.gameStatus[game.id] { Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
            HStack {
                Button { if pending != nil { section = "Download" } else if active { library.activateGame(game) } else { library.launch(game) } } label: {
                    Label(restoring ? "Preparazione avvio…" : pending?.state.label ?? (active ? "Torna al gioco" : (game.steamAppID != nil ? (game.isInstalled ? "Gioca" : "Installa") : (storeManaged ? "Avvia nello store" : "Gioca"))),
                          systemImage: active ? "hourglass" : (game.isInstalled ? "play.fill" : "arrow.down.circle"))
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(restoring || library.maintenance.contains(game.id))
                Menu {
                    Button("Apri pagina gioco") { selectedGame = game }
                    Button(experience.game(game).hidden ? "Mostra nella libreria" : "Nascondi dalla libreria") { experience.update(game) { $0.hidden.toggle() } }
                    if game.steamAppID != nil {
                        Button("Workshop, cloud e trofei") { community = game }
                        if !game.isNative { Button(achievements.isDisabled(game) ? "Attiva trofei in gioco" : "Ripristina Steam API originale") { library.restoreSteamAPI(game) }.disabled(active || restoring) }
                        Button("Versioni e statistiche stimate") { library.installSelection = game }
                    }
                    if game.isInstalled {
                        Button("Mostra file") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.installDirectory ?? game.executablePath)])
                        }
                    }
                    if !game.isNative { Button("Apri log") { section = "Log" } }
                    Button("Rimuovi dalla libreria", role: .destructive) { removing = game }.disabled(active || restoring)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: 24)
            }
        }.padding(16).background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var machineView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Il tuo Mac").font(.largeTitle.bold())
                Text("Hardware rilevato automaticamente").foregroundStyle(.secondary)
                GroupBox("Rilevamento dei giochi") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Steam: manifest e librerie esterne. Epic: manifest locali .item. GOG: app con identificativo GOG e manifest goggame nelle cartelle aggiunte.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Aggiungi cartella…") { library.addScanRoot() }
                            Button("Rileva ora") { Task { await library.scanInstalledGames() } }.disabled(library.scanning)
                        }
                        ForEach(library.data.extraScanRoots ?? [], id: \.self) { path in
                            HStack {
                                Text(path).font(.caption).textSelection(.enabled)
                                Spacer()
                                Button("Rimuovi") { library.removeScanRoot(path) }
                            }
                        }
                        if !library.scanWarnings.isEmpty {
                            DisclosureGroup("\(library.scanWarnings.count) avvisi della scansione") {
                                ForEach(Array(library.scanWarnings.enumerated()), id: \.offset) { item in
                                    Text(item.element).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        detail("Processore", library.machine.chip)
                        detail("Memoria", "\(library.machine.memoryGB) GB")
                        detail("GPU", library.machine.gpu)
                        detail("Sistema", library.machine.macOS)
                        Text(library.machine.guidance).font(.callout).foregroundStyle(.secondary)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Runtime Windows") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Motore Windows autonomo").font(.headline)
                        Text("Wine e DXMT vengono scaricati, verificati e preparati automaticamente. Steam e CrossOver non devono essere installati.").foregroundStyle(.secondary)
                        OwnedRuntimeStatus(engine: library.engine)
                        Button("Prepara e verifica motore") { library.prepareEngine() }.buttonStyle(.borderedProminent)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Configurazione iniziale") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Ambiente Wine separato per ogni gioco", systemImage: "shippingbox")
                        Label("Cartella di lavoro impostata sul percorso del gioco", systemImage: "folder")
                        Label("Output del processo salvato su file", systemImage: "doc.text")
                        Text("Il backend grafico viene scelto automaticamente. Risoluzione e qualità restano quelle del gioco; le stime non sono benchmark o garanzie di compatibilità.")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Apri cartella dati e log") { library.openDataFolder() }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer()
        }
    }
}
