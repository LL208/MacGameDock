import AppKit
import SwiftUI
enum WorkshopInput {
    static func itemID(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: String
        if value.allSatisfy({ $0.isASCII && $0.isNumber }) { id = value }
        else {
            guard let url = URLComponents(string: value), url.scheme == "https", url.host == "steamcommunity.com",
                  url.path == "/sharedfiles/filedetails/" || url.path == "/sharedfiles/filedetails",
                  let parameter = url.queryItems?.first(where: { $0.name == "id" })?.value else { throw DockError.message("Inserisci l'ID numerico o il link Steam della mod.") }
            id = parameter
        }
        guard let number = UInt64(id), number > 0, id.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw DockError.message("ID Workshop non valido.") }
        return String(number)
    }
    static func validate(_ json: Data, appID: Int, itemID: String) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let response = root["response"] as? [String: Any], let details = response["publishedfiledetails"] as? [[String: Any]], details.count == 1,
              let item = details.first, (item["result"] as? Int) == 1,
              String(describing: item["publishedfileid"] ?? "") == itemID,
              (item["consumer_app_id"] as? Int) == appID,
              (item["file_type"] as? Int) == 0 else { throw DockError.message("Elemento non disponibile, non scaricabile o appartenente a un altro gioco. Le collezioni non sono supportate.") }
        if let filename = item["filename"] as? String, !filename.isEmpty {
            guard !filename.hasPrefix("/"), !filename.contains("\\"), !filename.contains(":"), !filename.split(separator: "/").contains("..") else { throw DockError.message("Il nome del file della mod non è sicuro.") }
        }
        return item["title"] as? String ?? "Mod \(itemID)"
    }
}

struct GameCommunityView: View {
    let game: Game
    var initialTab = "Workshop"
    @EnvironmentObject var library: Library
    @EnvironmentObject var steam: ManagedSteam
    @EnvironmentObject var social: SteamSocial
    @EnvironmentObject var monitor: AchievementMonitor
    @EnvironmentObject var mods: WorkshopLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var tab: String
    init(game: Game, initialTab: String = "Workshop") {
        self.game = game; self.initialTab = initialTab
        _tab = State(initialValue: initialTab)
    }
    @State private var inventory: SteamCloudInventory?
    @State private var checkingCloud = false
    @State private var resolvingCloud = false
    @State private var cloudMessage = ""
    @State private var player: SteamPlayerSnapshot?
    @State private var playerMessage = ""
    @State private var achievementData: SteamAchievementSnapshot?
    @State private var achievementFilter = "Tutti"
    @State private var workshopItems: [SteamWorkshopItem] = []
    @State private var workshopSearch = ""
    @State private var workshopPage = 0
    @State private var workshopTotal = 0
    @State private var loadingWorkshop = false
    @State private var workshopMessage = ""
    @State private var localSaves: [String: URL] = [:]
    @State private var input = ""
    @State private var downloading = false
    @State private var ownsSteamOperation = false
    @State private var task: Task<Void, Never>?
    @State private var downloaded: URL?
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(game.title).font(.title2.bold()); Spacer(); Button("Chiudi") { dismiss() } }
            Picker("Sezione", selection: $tab) { Text("Workshop e mod").tag("Workshop"); Text("Trofei Steam").tag("Trofei"); Text("Steam Cloud").tag("Cloud") }.pickerStyle(.segmented)
            if let id = game.steamAppID {
                if tab == "Workshop" {
                    if !mods.mods(for: game).isEmpty {
                        DisclosureGroup("Mod installate (\(mods.mods(for: game).count))") {
                            ForEach(mods.mods(for: game)) { mod in
                                HStack {
                                    Text(mod.title).lineLimit(1)
                                    Text(mod.enabled ? (FileManager.default.fileExists(atPath: mods.folder(mod).path) ? "File presenti nella cartella mod" : "Cartella spostata o rimossa") : "Disattivata").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Mostra file") { NSWorkspace.shared.open(mods.folder(mod)) }
                                    Button(mod.enabled ? "Disattiva" : "Riattiva") {
                                        do { try mods.toggle(mod); message = mod.enabled ? "Mod spostata fuori dalla cartella del gioco." : "Mod ripristinata nella cartella scelta." }
                                        catch { message = error.localizedDescription }
                                    }.disabled(library.isBusy(game))
                                }.padding(.vertical, 5)
                            }
                            Text("La presenza dei file non garantisce che il gioco abbia caricato la mod. Loader, dipendenze e ordine di caricamento restano specifici del gioco.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let error = mods.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    HStack {
                        TextField("Cerca mod nel Workshop", text: $workshopSearch).textFieldStyle(.roundedBorder).onSubmit { Task { await loadWorkshop(reset: true) } }
                        Button("Cerca", systemImage: "magnifyingglass") { Task { await loadWorkshop(reset: true) } }.disabled(loadingWorkshop)
                    }
                    if !workshopMessage.isEmpty { Text(workshopMessage).font(.caption).foregroundStyle(.secondary) }
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230))], spacing: 16) {
                            ForEach(workshopItems) { item in
                                VStack(alignment: .leading, spacing: 10) {
                                    AsyncImage(url: item.previewURL) { image in image.resizable().scaledToFill() } placeholder: { Color.indigo.opacity(0.25).overlay(Image(systemName: "puzzlepiece.extension")) }.frame(height: 120).clipped().cornerRadius(10)
                                    Text(item.title).font(.headline).lineLimit(2)
                                    Text(item.description ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    HStack {
                                        Label("\(item.subscriptions)", systemImage: "person.2").font(.caption2).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("Scarica", systemImage: "arrow.down.circle") { input = item.id; download(id) }.disabled(downloading || steam.busy || library.running.contains(game.id))
                                    }
                                }.padding(14).background(Color.white.opacity(0.04)).cornerRadius(14)
                            }
                        }
                        if workshopItems.count < workshopTotal { Button("Carica altre mod") { Task { await loadWorkshop(reset: false) } }.disabled(loadingWorkshop) }
                        if loadingWorkshop { ProgressView("Caricamento mod…").padding() }
                        if workshopItems.isEmpty && !loadingWorkshop { ContentUnavailableViewCompat(title: "Nessuna mod trovata", icon: "puzzlepiece.extension", detail: "Il gioco potrebbe non avere un Workshop oppure la ricerca non ha restituito risultati.") }
                    }
                    HStack {
                        TextField("Oppure incolla un link o ID della mod", text: $input).textFieldStyle(.roundedBorder)
                        Button("Scarica mod") { download(id) }.disabled(downloading || steam.busy || library.running.contains(game.id))
                        if downloading { Button("Annulla") { task?.cancel(); if ownsSteamOperation { steam.cancel() } } }
                    }
                    if let folder = downloaded { HStack { Button("Mostra download") { NSWorkspace.shared.open(folder) }; Button("Installa in cartella mod…") { installMod(folder) }.disabled(library.running.contains(game.id)) } }
                    if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
                } else if tab == "Cloud" {
                    Text("I salvataggi Auto-Cloud supportati vengono confrontati prima dell’avvio: la copia più recente ha priorità. I file locali sostituiti sono conservati in un backup. Alla chiusura i salvataggi Auto-Cloud modificati vengono inviati a Steam, con confronto delle copie e verifica dal server. I file Steam API senza percorso dichiarato non sono ancora supportati.").foregroundStyle(.secondary)
                    Button(checkingCloud ? "Caricamento…" : "Aggiorna elenco") { checkCloud() }
                        .disabled(checkingCloud || steam.busy || steam.preparing || library.signingIn || library.syncingSteam || library.running.contains(game.id))
                    if let status = library.cloudStatuses[game.id] { Text(status).font(.callout).textSelection(.enabled) }
                    HStack {
                        Button("Sincronizza ora") { Task { await library.syncCloud(game) } }.disabled(library.isBusy(game))
                        Button("Risolvi un conflitto…") { resolvingCloud = true }.disabled(library.isBusy(game))
                        Button("Apri backup") { NSWorkspace.shared.open(library.root.appendingPathComponent("Cloud/Backups")) }
                    }
                    if !cloudMessage.isEmpty { Text(cloudMessage).font(.caption).textSelection(.enabled) }
                    if let inventory {
                        Text("\(inventory.liveFiles.count) file nel cloud").font(.headline)
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(Array(inventory.liveFiles.enumerated()), id: \.offset) { entry in
                                    HStack(spacing: 14) {
                                        Image(systemName: "doc.fill").font(.title2).foregroundStyle(.mint).frame(width: 35)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(entry.element.name).font(.headline).textSelection(.enabled)
                                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(entry.element.size), countStyle: .file)) · \(Date(timeIntervalSince1970: TimeInterval(entry.element.timestamp)).formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if let path = localSaves[entry.element.name] {
                                            Label(FileManager.default.fileExists(atPath: path.path) ? "Anche su questo Mac" : "Nel cloud", systemImage: "icloud").font(.caption).foregroundStyle(.secondary)
                                            Button("Mostra locale") { NSWorkspace.shared.activateFileViewerSelecting([path]) }.disabled(!FileManager.default.fileExists(atPath: path.path))
                                        } else { Text("Steam API").font(.caption).foregroundStyle(.secondary) }
                                    }.padding(14).background(Color.white.opacity(0.04)).cornerRadius(12)
                                }
                            }
                        }
                    }
                    Spacer()
                } else {
                    if let player {
                        HStack {
                            if let minutes = player.minutes { Label(String(format: "%.1f ore su Steam", Double(minutes) / 60), systemImage: "clock") }
                            if let unlocked = player.unlocked, let total = player.total { Label("\(unlocked) / \(total) trofei su Steam", systemImage: "trophy") }
                        }.font(.headline)
                    }
                    if !playerMessage.isEmpty { Text(playerMessage).font(.caption).foregroundStyle(.secondary) }
                    Text("Dati dell’account letti da Steam. Le ore locali sono conteggiate separatamente. I nuovi sblocchi dei giochi Windows compatibili vengono rilevati durante la partita e confermati da Steam.").font(.caption).foregroundStyle(.secondary)
                    if let snapshot = achievementData {
                        HStack {
                            ProgressView(value: Double(snapshot.achievements.filter(\.unlocked).count), total: Double(max(1, snapshot.achievements.count)))
                            Picker("Mostra", selection: $achievementFilter) { Text("Tutti").tag("Tutti"); Text("Ottenuti").tag("Ottenuti"); Text("Da ottenere").tag("Da ottenere") }.pickerStyle(.segmented).frame(width: 300)
                        }
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(snapshot.achievements.filter { achievementFilter == "Tutti" || (achievementFilter == "Ottenuti" ? $0.unlocked : !$0.unlocked) }) { achievement in
                                    SteamAchievementRow(achievement: achievement)
                                }
                            }
                        }
                        if snapshot.achievements.isEmpty { ContentUnavailableViewCompat(title: "Nessun trofeo disponibile", icon: "trophy", detail: "Steam non ha restituito trofei per questo gioco.") }
                    } else { Spacer() }

                }
            }
        }.padding(24).frame(minWidth: 850, minHeight: 640)
        .confirmationDialog("Quale copia vuoi conservare?", isPresented: $resolvingCloud, titleVisibility: .visible) {
            Button("Usa i salvataggi di questo Mac su Steam") { library.resolveCloudConflict(game, keepLocal: true) }
            Button("Usa i salvataggi Steam su questo Mac") { library.resolveCloudConflict(game, keepLocal: false) }
            Button("Annulla", role: .cancel) {}
        } message: { Text("Prima di sostituire i file, MacGameDeck conserva le copie precedenti nei backup. La scelta riguarda i salvataggi Auto-Cloud supportati di questo gioco.") }
        .task(id: tab + (library.data.steamAccount?.steamID ?? "")) {
            guard library.data.steamAccount != nil else { return }
            do {
                while steam.busy || steam.preparing || library.signingIn || library.syncingSteam { try await Task.sleep(nanoseconds: 200_000_000) }
                try Task.checkCancellation()
                if tab == "Cloud" { await loadCloud() }
                else if tab == "Trofei" { await loadPlayer() }
                else { await loadWorkshop(reset: true) }
            } catch {}
        }
        .onReceive(monitor.$snapshots) { snapshots in
            if let id = game.steamAppID, let snapshot = snapshots[id], snapshot.steamID == library.data.steamAccount?.steamID { achievementData = snapshot }
        }
        .onDisappear { if downloading { task?.cancel(); if ownsSteamOperation { steam.cancel() } } }
    }
    private func checkCloud() { Task { await loadCloud() } }
    @MainActor private func loadCloud() async {
        guard !checkingCloud else { return }
        guard let account = library.data.steamAccount?.steamID else { cloudMessage = "Collega l'account Steam per visualizzare il cloud."; return }
        checkingCloud = true; inventory = nil; cloudMessage = "Caricamento dei salvataggi da Steam…"
        defer { checkingCloud = false }
        do {
            let response = try await steam.cloudInventory(game, expected: account)
            guard library.data.steamAccount?.steamID == account else { return }
            inventory = response; localSaves = [:]
            for file in response.liveFiles {
                let prefix = response.prefixes.isEmpty ? "" : response.prefixes[file.prefixIndex]
                let name = prefix + (prefix.isEmpty || prefix.hasSuffix("/") || prefix.hasSuffix("%") ? "" : "/") + file.name
                localSaves[file.name] = try? SteamCloudRestore.destination(name, game: game, inventory: response)
            }
            cloudMessage = inventory?.liveFiles.isEmpty == true ? "Nessun salvataggio presente nel cloud di questo account." : "Elenco aggiornato da Steam."
        } catch { cloudMessage = error.localizedDescription }
    }
    @MainActor private func loadPlayer() async {
        guard let account = library.data.steamAccount?.steamID else { return }
        player = nil; achievementData = nil; playerMessage = "Caricamento di ore e trofei dell’account Steam…"
        do {
            let snapshot = try await steam.playerSnapshot(game, expected: account)
            guard library.data.steamAccount?.steamID == account else { return }
            try library.updateSteamSnapshot(snapshot)
            player = snapshot
            if let id = game.steamAppID {
                achievementData = social.connected ? try await social.achievements(id) : try await steam.achievements(game, expected: account)
            }
            playerMessage = snapshot.minutes == nil && snapshot.unlocked == nil ? "Steam non ha restituito statistiche per questo gioco; il dato non viene mostrato come zero." : "Dati aggiornati da Steam."
        } catch { playerMessage = error.localizedDescription }
    }
    @MainActor private func loadWorkshop(reset: Bool) async {
        guard !loadingWorkshop, let owner = library.data.steamAccount?.steamID else { return }
        loadingWorkshop = true; defer { loadingWorkshop = false }
        let next = reset ? 1 : workshopPage + 1
        do {
            while steam.busy || steam.preparing { try await Task.sleep(nanoseconds: 200_000_000) }
            let page = try await steam.workshop(game, expected: owner, search: workshopSearch, page: next)
            guard library.data.steamAccount?.steamID == owner else { return }
            if reset { workshopItems = [] }
            let known = Set(workshopItems.map(\.id)); workshopItems.append(contentsOf: page.items.filter { !known.contains($0.id) })
            workshopPage = page.page; workshopTotal = page.total; workshopMessage = "\(page.total) mod disponibili"
        } catch { workshopMessage = error.localizedDescription }
    }
    private func download(_ appID: Int) {
        downloading = true; downloaded = nil; message = "Verifica della mod…"
        task = Task { @MainActor in
            defer { downloading = false; ownsSteamOperation = false; task = nil }
            do {
                let id = try WorkshopInput.itemID(input)
                var request = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
                request.httpMethod = "POST"; request.timeoutInterval = 30
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data("itemcount=1&publishedfileids%5B0%5D=\(id)".utf8)
                let (bytes, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, bytes.count <= 4_000_000 else { throw DockError.message("Il Workshop non ha risposto correttamente.") }
                let title = try WorkshopInput.validate(bytes, appID: appID, itemID: id)
                try Task.checkCancellation()
                guard !steam.busy, !library.signingIn, !library.syncingSteam else { throw DockError.message("Attendi l'operazione Steam in corso.") }
                let directory = library.root.appendingPathComponent("Workshop/\(appID)/\(id)/\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                message = "Download: \(title)…"
                ownsSteamOperation = true
                _ = try await steam.run(["-app", String(appID), "-pubfile", id, "-dir", directory.path, "-validate"], expected: library.data.steamAccount?.steamID)
                ownsSteamOperation = false
                try Task.checkCancellation()
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                guard !files.isEmpty else { throw DockError.message("Il motore non ha scaricato contenuti per questa mod.") }
                downloaded = directory; message = "\(title) scaricata. Per attivarla, segui le istruzioni dell'autore e seleziona la cartella mod del gioco. Nessun file del gioco è stato sovrascritto."
            } catch is CancellationError { message = "Download annullato." }
            catch { message = error.localizedDescription }
        }
    }
    private func installMod(_ source: URL) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.title = "Scegli la cartella mod indicata dall'autore"
        panel.message = "Verrà creata una nuova sottocartella con i file scaricati. I file esistenti non saranno sovrascritti. Il gioco potrebbe richiedere altri passaggi per attivare la mod."
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            let src = source.resolvingSymlinksInPath().standardizedFileURL.path
            let dst = target.resolvingSymlinksInPath().standardizedFileURL.path
            guard dst != src, !dst.hasPrefix(src + "/") else { throw DockError.message("Scegli una cartella diversa dal download.") }
            guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { throw DockError.message("Download non leggibile.") }
            for case let file as URL in enumerator {
                if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw DockError.message("La mod contiene collegamenti simbolici: installazione automatica non consentita.") }
            }
            let destination = target.appendingPathComponent("MacGameDeck-Mod-\(source.deletingLastPathComponent().lastPathComponent)-\(UUID().uuidString.prefix(8))")
            try FileManager.default.copyItem(at: source, to: destination)
            do {
                let itemID = source.deletingLastPathComponent().lastPathComponent
                try mods.register(game: game, itemID: itemID, title: workshopItems.first(where: { $0.id == itemID })?.title ?? "Mod " + itemID, destination: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            message = "File copiati in \(destination.path). Segui le istruzioni della mod per l'attivazione."
        } catch { message = error.localizedDescription }
    }
}

struct ContentUnavailableViewCompat: View {
    let title: String
    let icon: String
    let detail: String
    var body: some View { VStack(spacing: 12) { Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary); Text(title).font(.title3.bold()); Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center) }.padding(30).frame(maxWidth: .infinity) }
}
struct SteamAchievementRow: View {
    let achievement: SteamAchievement
    var body: some View {
        HStack(spacing: 16) {
            AsyncImage(url: achievement.imageURL) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: achievement.unlocked ? "trophy.fill" : "lock.fill").font(.title).foregroundStyle(achievement.unlocked ? Color.yellow : Color.secondary) }.frame(width: 55, height: 55).cornerRadius(9)
            VStack(alignment: .leading, spacing: 5) {
                Text(achievement.displayTitle).font(.headline)
                Text(achievement.displayDescription).font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if achievement.unlocked { VStack(alignment: .trailing) { Label("Ottenuto", systemImage: "checkmark.circle.fill").foregroundStyle(.mint); Text(Date(timeIntervalSince1970: Double(achievement.unlockTime)).formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary) }.font(.caption) }
        }.padding(14).background(Color.white.opacity(achievement.unlocked ? 0.065 : 0.03)).cornerRadius(12).opacity(achievement.unlocked ? 1 : 0.8)
    }
}
