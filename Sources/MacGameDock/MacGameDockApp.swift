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
            DockView().environmentObject(library).environmentObject(library.managedSteam).environmentObject(library.downloads).environmentObject(library.activity).environmentObject(library.social).environmentObject(library.achievements)
                .frame(minWidth: 940, minHeight: 650)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Aggiungi gioco…") { library.importGame(store: .local) }
                    .keyboardShortcut("o")
            }
        }
    }
}

struct DockView: View {
    @EnvironmentObject var library: Library
    @State private var section = "Libreria"
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
            (section == "Libreria" || $0.store.rawValue == section) &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) && (!familyOnly || $0.isFamilyShared)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                Label("MacGameDeck", systemImage: "gamecontroller.fill")
                    .font(.title3.bold()).padding(.top, 20)
                VStack(spacing: 8) {
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
                }
                Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    Text(library.machine.chip).font(.subheadline.bold())
                    Text("\(library.machine.memoryGB) GB · \(library.machine.architecture)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Anteprima di sviluppo · 0.9.7").font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(20).frame(width: 210)
                .background(Color(red: 0.07, green: 0.08, blue: 0.12))
            Divider()
            VStack(alignment: .leading, spacing: 24) {
                if section == "Il tuo Mac" { machineView }
                else if section == "Controller" { ControllersView() }
                else if section == "Log" { LogsView() }
                else if section == "Download" { DownloadsView() }
                else if section == "Account Steam" { SteamAccountView() }
                else { libraryView }
            }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(red: 0.10, green: 0.11, blue: 0.16))
        }
        .safeAreaInset(edge: .bottom) { VStack(spacing: 0) { OwnedRuntimeStatus(engine: library.engine); SteamOperationView() } }
        .sheet(item: $library.installSelection) { game in
            GameDetailsView(game: game).environmentObject(library)
        }
        .sheet(item: $community) { game in GameCommunityView(game: game).environmentObject(library).environmentObject(library.managedSteam).environmentObject(library.social).environmentObject(library.achievements) }
        .onReceive(social.$profile) { value in if value != nil { library.achievements.flush() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in activity.checkpoint(); library.social.stop() }
        .tint(.mint)
         .task {
            if ProcessInfo.processInfo.arguments.contains("--verify-windows-runtime") {
                library.prepareEngine()
                return
            }
            await library.scanInstalledGames()
            if let owner = library.data.steamAccount?.steamID { library.social.start(owner: owner) }
            if library.data.steamAccount?.steamID == library.managedSteam.savedAccountID, library.managedSteam.hasSavedSession { library.syncSteam() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await library.scanInstalledGames() }
        }
        .alert("Operazione non completata", isPresented: Binding(
            get: { library.error != nil }, set: { if !$0 { library.error = nil } }
        )) {
            if let game = library.cloudLaunchFailure { Button("Avvia con salvataggi locali") { library.launchWithLocalSaves(game) } }
            Button("Apri log") { section = "Log"; library.error = nil }
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
                if title != "Log" && title != "Controller" && title != "Il tuo Mac" && title != "Account Steam" && title != "Download" {
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
                    Text("I tuoi giochi, un solo punto di partenza.").foregroundStyle(.secondary)
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
                Toggle("Famiglia", isOn: $familyOnly).toggleStyle(.checkbox)
                Spacer()
                if library.scanning { ProgressView().controlSize(.small) }
                Button { Task { await library.scanInstalledGames() } } label: {
                    Label("Rileva giochi", systemImage: "arrow.clockwise")
                }.disabled(library.scanning)
                Button("Collega Steam") { section = "Account Steam" }
            }
            if !library.scanSummary.isEmpty {
                Text(library.scanSummary).font(.caption).foregroundStyle(.secondary)
            }
            TextField("Cerca nella libreria", text: $search).textFieldStyle(.roundedBorder)
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
            Text(game.title).font(.title3.bold()).lineLimit(2)
                .help(game.executablePath)
            Text("\(game.store.rawValue) · \(game.isInstalled ? "Installato" : "Da installare")")
                .font(.caption).foregroundStyle(.secondary)
            Label(storeManaged ? "Compatibilità da verificare" : (game.isNative ? "Avvio nativo" : "Profilo sperimentale · Wine"),
                  systemImage: storeManaged ? "questionmark.circle" : (game.isNative ? "desktopcomputer" : "flask"))
                .font(.caption).foregroundStyle(game.isNative ? Color.mint : Color.orange)
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
            HStack {
                Button { if pending != nil { section = "Download" } else { library.launch(game) } } label: {
                    Label(restoring ? "Preparazione avvio…" : pending?.state.label ?? (active ? "In esecuzione" : (game.steamAppID != nil ? (game.isInstalled ? "Gioca" : "Installa") : (storeManaged ? "Avvia nello store" : "Gioca"))),
                          systemImage: active ? "hourglass" : (game.isInstalled ? "play.fill" : "arrow.down.circle"))
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(active || restoring)
                Menu {
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
