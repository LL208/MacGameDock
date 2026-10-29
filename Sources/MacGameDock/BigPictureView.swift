import AppKit
import GameController
import SwiftUI

struct BigPictureView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @StateObject private var detail = GameDetailModel()
    @State private var advancedGame = false
    @ObservedObject var model: BigPictureModel
    @EnvironmentObject var artwork: ArtworkStore
    @State private var viewport: CGFloat = 1400
    @EnvironmentObject var library: Library
    @EnvironmentObject var experience: GameExperience
    @EnvironmentObject var queue: DownloadQueue
    @EnvironmentObject var steam: ManagedSteam
    @EnvironmentObject var social: SteamSocial
    @EnvironmentObject var activity: PlayActivity
    @EnvironmentObject var achievements: AchievementMonitor
    @EnvironmentObject var mods: WorkshopLibrary
    @EnvironmentObject var controller: DeckControllerInput
    private let pageSize = 24
    private var game: Game? { model.page.gameID.flatMap { id in library.data.games.first { $0.id == id } } }
    private var dialog: Bool { library.error != nil || library.notice != nil || model.confirmation != nil }
    private var focusKey: String { dialog ? "dialog" : (model.picker == nil ? model.page.key : "folder") }
    private var columns: Int {
        if dialog || model.picker != nil { return 1 }
        switch model.page { case .home, .library: return viewport >= 1500 ? 6 : (viewport >= 1050 ? 4 : 3); case .workshop: return 4; case .game, .settings, .controllers, .account, .install: return 2; default: return 1 }
    }
    private var games: [Game] {
        library.visibleGames(installedOnly: model.installedOnly).filter { game in
            (model.page != .home || game.isInstalled || experience.game(game).lastPlayed != nil) &&
            (model.hidden || !experience.game(game).hidden) && (model.store == "Tutti" || game.store.rawValue == model.store) &&
            (!model.favoritesOnly || experience.game(game).favorite) && (model.collection == "Tutte" || experience.game(game).collection == model.collection) &&
            (model.search.isEmpty || game.title.localizedCaseInsensitiveContains(model.search))
        }.sorted { a, b in
            if model.page == .home || model.sort == "Recenti" { let x = experience.game(a).lastPlayed ?? .distantPast, y = experience.game(b).lastPlayed ?? .distantPast; if x != y { return x > y } }
            if model.sort == "Ore Steam", a.steamMinutes != b.steamMinutes { return (a.steamMinutes ?? -1) > (b.steamMinutes ?? -1) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
    private var actions: [DeckAction] {
        if let error = library.error {
            var result: [DeckAction] = []
            if let failed = library.cloudLaunchFailure {
                result.append(action("retry", "Riprova", "arrow.clockwise") { library.error = nil; library.cloudLaunchFailure = nil; library.launch(failed) })
                result.append(action("local", "Gioca con i salvataggi locali", "play") { library.launchWithLocalSaves(failed) })
            }
            result.append(action("dismiss", "Chiudi", "xmark") { library.error = nil; library.cloudLaunchFailure = nil })
            result.append(action("logs", "Leggi la diagnosi", "doc.text") { library.error = nil; library.cloudLaunchFailure = nil; model.navigate(.logs); loadLog() })
            _ = error; return result
        }
        if library.notice != nil { return [action("dismiss", "Ho capito", "checkmark") { library.notice = nil }] }
        if model.confirmation != nil { return [action("cancel", "Annulla", "arrow.uturn.backward") { model.confirmation = nil; model.confirmAction = nil }, action("accept", "Conferma", "checkmark") { let run = model.confirmAction; model.confirmAction = nil; model.confirmation = nil; run?() }] }
        if let picker = model.picker { return folderActions(picker) }
        switch model.page {
        case .home, .library: return libraryActions
        case .game: return detailActions
        case .install: return installActions
        case .downloads: return downloadActions
        case .account: return accountActions
        case .controllers: return controllerActions
        case .settings: return settingActions
        case .logs: return logActions
        case .trophies: return trophyActions
        case .cloud: return cloudActions
        case .workshop: return workshopActions
        case .mods: return modActions
        }
    }
    private func action(_ id: String, _ title: String, _ symbol: String = "chevron.right", detail: String = "", enabled: Bool = true, run: @escaping () -> Void) -> DeckAction {
        DeckAction(id: id, title: L10n.text(title), detail: L10n.text(detail), symbol: symbol, enabled: enabled, run: run)
    }
    private var browsingLibrary: Bool { (model.page == .home || model.page == .library) && !dialog && model.picker == nil }
    private var navigationActions: [DeckAction] {
        DeckPage.sections.map { page in action("section-" + page.key, page == .home ? "Home" : page.title) { navigate(page) } }
    }
    private let filterColumns = 4
    private var filterActions: [DeckAction] {
        [action("search", "Cerca un gioco", "magnifyingglass", detail: model.search) { showSearch() },
         action("installed", model.installedOnly ? "Solo installati" : "Tutti i giochi", "internaldrive") { model.installedOnly.toggle(); model.pageNumber = 0 },
         action("favorites", model.favoritesOnly ? "Solo preferiti" : "Tutti i preferiti e altri", "star") { model.favoritesOnly.toggle(); model.pageNumber = 0 },
         action("store", "Store: " + model.store, "shippingbox") { cycle(&model.store, ["Tutti"] + GameStore.allCases.map(\.rawValue)); model.pageNumber = 0 },
         action("sort", "Ordine: " + model.sort, "arrow.up.arrow.down") { cycle(&model.sort, ["Titolo", "Recenti", "Ore Steam"]) },
         action("collection", "Raccolta: " + model.collection, "square.stack") { cycle(&model.collection, ["Tutte"] + experience.collections); model.pageNumber = 0 },
         action("hidden", model.hidden ? "Nascosti visibili" : "Nascosti esclusi", "eye") { model.hidden.toggle(); model.pageNumber = 0 },
         action("import", "Aggiungi gioco locale", "plus") { chooseFolder("Scegli un gioco .app o .exe", purpose: .game) { library.importGame(at: $0, store: .local) } }]
    }
    private var libraryGameActions: [DeckAction] {
        games.dropFirst(min(model.pageNumber * pageSize, games.count)).prefix(pageSize).map { item in
            DeckAction(id: item.id.uuidString, title: item.title, detail: item.isInstalled ? experience.compatibility(item) : "Da installare", game: item) { model.navigate(.game(item.id)) }
        }
    }
    private var libraryPagination: [DeckAction] {
        [action("previous", "Pagina precedente", "chevron.left", enabled: model.pageNumber > 0) { model.pageNumber = max(0, model.pageNumber - 1) },
         action("next", "Pagina successiva", "chevron.right", enabled: (model.pageNumber + 1) * pageSize < games.count) { model.pageNumber += 1 }]
    }
    private var libraryActions: [DeckAction] { navigationActions + filterActions + libraryGameActions + libraryPagination }
    private var gameActions: [DeckAction] {
        guard let game else { return [backAction] }
        let busy = library.isBusy(game) || detail.releasing
        var result: [DeckAction] = [
            action("play", library.running.contains(game.id) ? "Torna al gioco" : (game.isInstalled ? "Gioca" : "Installa"), "play.fill", detail: library.launchStages[game.id] ?? "", enabled: library.running.contains(game.id) || !busy) {
                if library.running.contains(game.id) { library.activateGame(game) }
                else if game.isInstalled { Task { await detail.releaseForLaunch(library: library); if !Task.isCancelled { library.launch(game) } } } else { navigate(.install(game.id)) }
            },
            action("favorite", experience.game(game).favorite ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti", "star") { experience.update(game) { $0.favorite.toggle() } },
            action("trophies", "Trofei", "trophy", enabled: game.steamAppID != nil) { navigate(.trophies(game.id)) },
            action("cloud", "Salvataggi", "icloud", enabled: game.steamAppID != nil) { navigate(.cloud(game.id)) },
            action("workshop", "Workshop", "puzzlepiece.extension", enabled: game.steamAppID != nil) { navigate(.workshop(game.id)) },
            action("mods", "Mod installate", "shippingbox") { model.navigate(.mods(game.id)) },
            action("stats", "Aggiorna ore e trofei", "arrow.clockwise", enabled: game.steamAppID != nil && !library.refreshingStats.contains(game.id)) { Task { await library.refreshSteamActivity(game) } },
            action("collection", "Raccolta: " + (experience.game(game).collection.isEmpty ? "nessuna" : experience.game(game).collection), "square.stack") { model.keyboard = DeckKeyboard(title: "Nome della raccolta", text: experience.game(game).collection) { name in experience.update(game) { $0.collection = name.trimmingCharacters(in: .whitespacesAndNewlines) } } },
            action("compatibility", experience.game(game).confirmedWorking ? "Funzionamento confermato" : "Conferma che funziona", "checkmark.seal") { experience.update(game) { $0.confirmedWorking.toggle() } },
            action("hide", experience.game(game).hidden ? "Mostra nella libreria" : "Nascondi dalla libreria", "eye.slash") { experience.update(game) { $0.hidden.toggle() } }
        ]
        if library.preparingLaunch.contains(game.id) { result.insert(action("cancel-launch", "Annulla preparazione", "xmark") { library.cancelLaunch(game) }, at: 1) }
        if game.steamAppID != nil { result.append(action("versions", "Versioni e requisiti", "desktopcomputer") { navigate(.install(game.id)) }) }
        if game.isInstalled {
            result.append(action("repair", "Verifica e ripara", "wrench", enabled: !busy && game.steamAppID != nil) { model.ask("Verificare i file e recuperare i componenti mancanti?") { library.repair(game) } })
            result.append(action("move", "Trasferisci su un altro disco", "externaldrive", enabled: !busy && library.canUninstall(game)) { chooseFolder("Scegli il disco di destinazione") { library.moveInstallation(game, to: $0) } })
            result.append(action("uninstall", "Disinstalla con backup", "archivebox", enabled: !busy && library.canUninstall(game)) { model.ask("Disinstallare \(game.title)? File e salvataggi vengono conservati nei backup; non viene liberato spazio finché non li rimuovi manualmente.") { library.uninstall(game, revealBackup: false) } })
        }
        if !game.isNative { result.append(action("bridge", achievements.isDisabled(game) ? "Attiva integrazione trofei" : "Ripristina Steam API originale", "arrow.uturn.backward", enabled: !busy) { model.ask("Cambiare l’integrazione Steam API di questo gioco? Gli originali vengono conservati.") { library.restoreSteamAPI(game) } }) }
        result.append(action("remove", "Rimuovi dalla libreria", "minus.circle", enabled: !busy) { model.ask("Rimuovere la voce dalla libreria? I file e i salvataggi restano conservati.") { library.remove(game); model.back() } })
        result.append(backAction); return result
    }
    private var isGameDetail: Bool { if case .game = model.page { return !dialog && model.picker == nil }; return false }
    private var primaryGameActions: [DeckAction] { gameActions.filter { ["play", "favorite", "cancel-launch"].contains($0.id) } }
    private var detailInformationActions: [DeckAction] {
        [action("description", detail.expandedDescription ? "Riduci descrizione" : "Leggi descrizione completa", "text.alignleft") { detail.expandedDescription.toggle() },
         action("refresh-detail", "Aggiorna dettagli", "arrow.clockwise", enabled: !detail.trophiesLoading && !detail.metadataLoading) { if let game { detail.load(game, library: library) } }]
    }
    private var detailTrophyActions: [DeckAction] {
        var items = detail.preview.map { trophy in
            DeckAction(id: "detail-trophy-" + trophy.id, title: trophy.displayTitle, detail: trophy.displayDescription, symbol: trophy.unlocked ? "trophy.fill" : "lock", achievement: trophy) { model.status = trophy.displayTitle + " · " + trophy.displayDescription }
        }
        items.append(action("all-trophies", "Visualizza tutti i trofei", "trophy", enabled: game?.steamAppID != nil) {
            guard let game else { return }; model.navigate(.trophies(game.id))
            if detail.trophiesLoaded { model.trophies = detail.trophies; model.status = detail.trophyStatus } else { model.load(library: library) }
        })
        return items
    }
    private var communityGameActions: [DeckAction] { gameActions.filter { ["cloud", "workshop", "mods"].contains($0.id) } }
    private var advancedGameActions: [DeckAction] {
        var values = [action("advanced-game", advancedGame ? "Nascondi gestione del gioco" : "Gestisci gioco e installazione", "slider.horizontal.3") { advancedGame.toggle() }]
        if advancedGame { values += gameActions.filter { !["play", "favorite", "cancel-launch", "trophies", "cloud", "workshop", "mods"].contains($0.id) } }
        return values
    }
    private var detailActions: [DeckAction] { primaryGameActions + detailInformationActions + detailTrophyActions + communityGameActions + advancedGameActions }
    @ViewBuilder private var gameDetailContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            detailActionGrid(primaryGameActions)
            GameOverviewView(detail: detail)
            detailActionGrid(detailInformationActions)
            VStack(alignment: .leading, spacing: 16) {
                GameTrophySummary(detail: detail)
                detailActionGrid(detailTrophyActions)
            }.padding(18).background(.black.opacity(0.2)).clipShape(RoundedRectangle(cornerRadius: 16))
            Text(L10n.text("Salvataggi e contenuti")).font(.title2.bold())
            detailActionGrid(communityGameActions)
            detailActionGrid(advancedGameActions)
        }.padding(8)
    }
    private func detailActionGrid(_ values: [DeckAction]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) { ForEach(values) { item in tile(item).id(item.id) } }
    }
    private var installActions: [DeckAction] {
        guard let game else { return [backAction] }
        var result: [DeckAction] = []
        let mac = model.insights?.macAvailable ?? (game.platforms?.contains("macos") == true)
        let windows = model.insights?.windowsAvailable ?? (game.platforms?.contains("windows") != false)
        if mac { result.append(action("mac", "Installa versione Mac", "apple.logo", detail: "Può richiedere Rosetta o servizi Steamworks non supportati", enabled: !library.isBusy(game)) { library.installSteam(game, platform: .macOS); model.navigate(.downloads) }) }
        if windows { result.append(action("windows", "Installa versione Windows", "gamecontroller", detail: "Componenti e container preparati automaticamente", enabled: !library.isBusy(game)) { library.installSteam(game, platform: .windows); model.navigate(.downloads) }) }
        result.append(action("storage", "Scegli disco o cartella", "externaldrive", enabled: game.storageContainer == nil) { chooseFolder("Dove installare i nuovi giochi?") { url in experience.settings { $0.storageRoot = url.path } } })
        result.append(action("refresh", "Rileggi versioni e requisiti", "arrow.clockwise", enabled: !model.loading) { model.load(library: library) })
        result.append(backAction); return result
    }
    private var downloadActions: [DeckAction] {
        var result = [action("pause-all", "Pausa tutto", "pause") { queue.pauseAll() }, action("resume-all", "Riprendi coda", "play") { queue.resumeAll() }]
        for job in queue.jobs.sorted(by: { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }) {
            let title = job.game.title + " · " + job.state.label
            if [.active, .queued].contains(job.state) { result.append(action("pause-\(job.id)", "Pausa: " + title, "pause", detail: job.state == .active ? steam.message : "") { queue.pause(job.id) }) }
            if [.paused, .failed, .cancelled].contains(job.state) { result.append(action("resume-\(job.id)", "Riprendi: " + title, "play", detail: job.error ?? "") { queue.resume(job.id) }) }
            if [.queued, .active, .paused, .failed].contains(job.state) { result.append(action("cancel-\(job.id)", "Annulla: " + job.game.title, "xmark") { model.ask("Annullare il download? I file parziali saranno conservati.") { queue.cancel(job.id) } }) }
            if job.state == .queued { result.append(action("first-\(job.id)", "Scarica prima: " + job.game.title, "arrow.up") { queue.prioritize(job.id) }) }
            if queue.canRemove(job.id) { result.append(action("remove-\(job.id)", "Rimuovi dalla lista: " + title, "minus.circle") { queue.remove(job.id) }) }
            if job.state == .completed, let installed = library.data.games.first(where: { $0.id == job.game.id }) { result.append(action("play-\(job.id)", "Apri: " + job.game.title, "gamecontroller") { model.navigate(.game(installed.id)) }) }
        }
        result.append(action("clear", "Svuota cronologia", "list.bullet", enabled: !queue.history.isEmpty) { model.ask("Rimuovere le voci concluse dalla cronologia? I giochi non vengono disinstallati.") { queue.clearHistory() } })
        return result
    }
    private var accountActions: [DeckAction] {
        var result: [DeckAction] = []
        if library.data.steamAccount == nil { result.append(action("login", "Accedi con QR Steam", "qrcode", enabled: !steam.busy && !library.signingIn) { library.connectSteam() }) }
        else {
            result.append(action("sync", "Aggiorna libreria Steam", "arrow.clockwise", enabled: !steam.busy && !library.signingIn) { library.syncSteam() })
            result.append(action("connect", "Connetti Steam in background", "network", enabled: !social.connected) { if let owner = library.data.steamAccount?.steamID { social.start(owner: owner) } })
            for state in SteamPersona.allCases { result.append(action("persona-\(state.rawValue)", state.label, social.profile?.persona == state ? "checkmark.circle.fill" : "circle", enabled: social.connected && !social.changingPresence) { social.setPresence(state) }) }
            result.append(action("relogin", "Ricollega con QR", "qrcode", enabled: !steam.busy) { model.ask("Rinnovare l’accesso Steam con un nuovo QR?") { library.reconnectSteam() } })
            result.append(action("disconnect", "Scollega Steam", "person.crop.circle.badge.xmark", enabled: !steam.busy) { model.ask("Scollegare Steam? I giochi installati restano conservati.") { library.disconnectSteam() } })
        }
        if steam.busy { result.append(action("cancel-login", "Annulla operazione Steam", "xmark") { library.cancelSteamLogin() }) }
        return result
    }
    private var controllerSwapAction: DeckAction {
        action("swap-buttons", "Inverti Conferma e Indietro: " + yes(experience.preferences.swapControllerConfirmBack == true), "arrow.left.arrow.right", detail: "Si applica ai comandi dell’app; i comandi dentro il gioco restano invariati") { experience.settings { $0.swapControllerConfirmBack = !($0.swapControllerConfirmBack ?? false) } }
    }
    private var controllerActions: [DeckAction] {
        [controllerSwapAction, action("discovery", "Cerca controller wireless", "antenna.radiowaves.left.and.right") { GCController.startWirelessControllerDiscovery(completionHandler: nil); model.status = "Ricerca avviata. Metti il controller in modalità abbinamento." }, action("help", "Mostra i comandi", "gamecontroller") { model.status = controllerHelp }, backAction]
    }
    private var artworkActions: [DeckAction] {
        [action("grid-key", artwork.configured ? "Cambia chiave SteamGridDB" : "Collega SteamGridDB", "photo.stack", detail: artwork.message) {
            model.keyboard = DeckKeyboard(title: "Chiave API SteamGridDB · personale", text: "", secure: true) { artwork.configure($0); model.status = artwork.message }
        }, action("grid-refresh", "Aggiorna copertine e sfondi", "arrow.clockwise") { artwork.refresh(); model.status = artwork.message },
         action("grid-remove", "Scollega SteamGridDB", "link", enabled: artwork.configured) { model.ask("Rimuovere la chiave SteamGridDB da questo Mac? Le immagini già in cache restano disponibili.") { artwork.configure("") } }]
    }
    private var settingActions: [DeckAction] {
        [action("language", "Lingua", "globe", detail: appLanguage.preference.title) { appLanguage.cycle() },
         controllerSwapAction, action("theme", "Tema desktop: " + experience.preferences.theme, "circle.lefthalf.filled") { let values = ["Sistema", "Scuro", "Chiaro"]; var value = experience.preferences.theme; cycle(&value, values); experience.settings { $0.theme = value } },
         action("resume", "Ripresa automatica: " + yes(experience.preferences.resumeDownloads), "play") { experience.settings { $0.resumeDownloads.toggle() } },
         action("pause", "Pausa download mentre giochi: " + yes(experience.preferences.pauseWhilePlaying), "pause") { experience.settings { $0.pauseWhilePlaying.toggle() } },
         action("bandwidth", "Limite banda: " + bandwidth, "speedometer") { let values = [0, 1024, 5120, 10240, 25600]; let old = experience.preferences.bandwidthLimitKBPS ?? 0; let value = values[((values.firstIndex(of: old) ?? 0) + 1) % values.count]; experience.settings { $0.bandwidthLimitKBPS = value == 0 ? nil : value } },
         action("storage", "Disco dei nuovi giochi", "externaldrive", detail: experience.preferences.storageRoot ?? "Cartella dati di MacGameDeck") { chooseFolder("Scegli dove installare i nuovi giochi") { url in experience.settings { $0.storageRoot = url.path } } },
         action("default-storage", "Usa disco predefinito", "internaldrive") { experience.settings { $0.storageRoot = nil } },
         action("scan", "Rileva giochi installati", "arrow.clockwise", enabled: !library.scanning) { Task { await library.scanInstalledGames() } },
         action("scan-folder", "Aggiungi cartella da rilevare", "folder.badge.plus") { chooseFolder("Scegli una libreria Steam o una cartella giochi") { library.addScanRoot(at: $0) } },
         action("engine", "Prepara e verifica motore", "wrench", enabled: !library.engine.busy && !steam.busy && !steam.preparing) { library.prepareEngine() },
         action("cancel-engine", "Annulla preparazione del motore", "xmark", enabled: library.engine.busy) { library.engine.cancel() },
         action("desktop", "Passa alla modalità desktop", "desktopcomputer") { experience.settings { $0.bigPicture = false } }]
        + artworkActions
        + (library.data.extraScanRoots ?? []).map { path in action("scan-remove-" + path, "Rimuovi cartella di rilevamento", "minus.circle", detail: path) { model.ask("Rimuovere questa cartella dal rilevamento automatico? I file saranno conservati.") { library.removeScanRoot(path) } } }
    }
    private var logActions: [DeckAction] {
        var result = [action("refresh", "Aggiorna log dell’app", "arrow.clockwise") { model.logPage = 0; loadLog() }, action("earlier", "Righe precedenti", "chevron.up", enabled: model.logPage > 0) { model.logPage -= 1 }, action("later", "Righe successive", "chevron.down") { model.logPage += 1 }]
        for item in library.data.games where FileManager.default.fileExists(atPath: library.log(for: item).path) { result.append(action(item.id.uuidString, "Log: " + item.title, "doc.text") { loadLog(library.log(for: item)) }) }
        result.append(action("export", "Esporta il log visualizzato…", "square.and.arrow.up") {
            chooseFolder("Scegli dove esportare il log") { folder in
                do { let text = model.logText.isEmpty ? try AppDiagnostics.tail(library.diagnostics.file) : model.logText; let file = folder.appendingPathComponent("MacGameDeck-Log-" + UUID().uuidString + ".txt"); try AppDiagnostics.redact(text).write(to: file, atomically: true, encoding: .utf8); model.status = "Log esportato in " + file.path }
                catch { model.status = error.localizedDescription }
            }
        })
        result.append(action("engine-log", "Log del motore Windows", "doc.text") { loadLog(library.root.appendingPathComponent("Logs/engine-check.log")) })
        return result
    }
    private var trophyActions: [DeckAction] {
        var result = [action("refresh", "Aggiorna trofei", "arrow.clockwise", enabled: !model.loading) { model.load(library: library) }, action("filter", "Mostra: " + model.trophyFilter, "line.3.horizontal.decrease") { cycle(&model.trophyFilter, ["Tutti", "Ottenuti", "Da ottenere"]); model.pageNumber = 0 }]
        let values = model.trophies.filter { model.trophyFilter == "Tutti" || (model.trophyFilter == "Ottenuti" ? $0.unlocked : !$0.unlocked) }
        for trophy in values.dropFirst(model.pageNumber * pageSize).prefix(pageSize) { result.append(action(trophy.id, trophy.displayTitle, trophy.unlocked ? "trophy.fill" : "lock", detail: trophy.displayDescription) { model.status = trophy.displayTitle + "\n" + trophy.displayDescription + (trophy.unlocked ? "\nOttenuto: " + Date(timeIntervalSince1970: Double(trophy.unlockTime)).formatted() : "") }) }
        result += pagination(count: values.count); return result
    }
    private var cloudActions: [DeckAction] {
        guard let game else { return [backAction] }
        var result = [action("refresh", "Aggiorna elenco", "arrow.clockwise", enabled: !model.loading) { model.load(library: library) }, action("sync", "Sincronizza ora", "arrow.triangle.2.circlepath", enabled: !library.isBusy(game)) { Task { await library.syncCloud(game) } }, action("local", "Risolvi: usa la copia Mac", "internaldrive", enabled: !library.isBusy(game)) { model.ask("Inviare a Steam la copia di questo Mac? Le precedenti copie cloud verranno conservate nel backup.") { library.resolveCloudConflict(game, keepLocal: true) } }, action("remote", "Risolvi: usa la copia Steam", "icloud", enabled: !library.isBusy(game)) { model.ask("Ripristinare i salvataggi Steam su questo Mac? Le copie locali precedenti verranno conservate nel backup.") { library.resolveCloudConflict(game, keepLocal: false) } }]
        for (index, save) in model.saves.enumerated() { result.append(action("save-\(index)", save.name, "doc", detail: ByteCountFormatter.string(fromByteCount: Int64(save.size), countStyle: .file)) { model.status = save.name + "\n" + Date(timeIntervalSince1970: Double(save.timestamp)).formatted() + " · " + ByteCountFormatter.string(fromByteCount: Int64(save.size), countStyle: .file) }) }
        return result
    }
    private var workshopActions: [DeckAction] {
        guard let game else { return [backAction] }
        var result = [action("search", "Cerca mod", "magnifyingglass", detail: model.workshopQuery) { showSearch() }, action("refresh", "Aggiorna Workshop", "arrow.clockwise", enabled: !model.loading) { model.load(library: library) }, action("mods", "Mod installate", "shippingbox") { model.navigate(.mods(game.id)) }]
        if let source = model.downloadedMod { result.insert(action("install-mod", "Installa la mod scaricata…", "plus", enabled: !library.isBusy(game)) { chooseFolder("Cartella mod richiesta dall’autore") { target in model.installMod(source, in: target, game: game, library: library) } }, at: 0) }
        for item in model.workshop { result.append(action(item.id, item.title, "puzzlepiece.extension", detail: "Scarica mod · \(item.subscriptions) iscritti", enabled: !model.loading && !library.isBusy(game)) { model.ask("Scaricare \(item.title)? Potrai poi scegliere la cartella richiesta dalla mod.") { model.downloadMod(item, game: game, library: library) } }) }
        result.append(action("previous", "Pagina precedente", "chevron.left", enabled: model.pageNumber > 0 && !model.loading) { model.pageNumber -= 1; model.load(library: library) })
        result.append(action("next", "Pagina successiva", "chevron.right", enabled: !model.workshop.isEmpty && !model.loading) { model.pageNumber += 1; model.load(library: library) }); return result
    }
    private var modActions: [DeckAction] {
        guard let game else { return [backAction] }
        var result: [DeckAction] = []
        for mod in mods.mods(for: game) { result.append(action(mod.id.uuidString, (mod.enabled ? "Disattiva: " : "Riattiva: ") + mod.title, "puzzlepiece.extension", enabled: !library.isBusy(game)) { do { try mods.toggle(mod); model.status = "Mod aggiornata" } catch { model.status = error.localizedDescription } }) }
        result.append(action("workshop", "Apri Workshop", "shippingbox") { navigate(.workshop(game.id)) }); return result
    }
    private var backAction: DeckAction { action("back", "Indietro", "arrow.uturn.backward") { model.back() } }
    private var bandwidth: String { experience.preferences.bandwidthLimitKBPS.map { "\($0 / 1024) MiB/s" } ?? "senza limite" }
    private func yes(_ value: Bool) -> String { value ? "sì" : "no" }
    private func cycle(_ value: inout String, _ choices: [String]) { guard !choices.isEmpty else { return }; value = choices[((choices.firstIndex(of: value) ?? -1) + 1) % choices.count] }
    private func pagination(count: Int) -> [DeckAction] {
        [action("previous", "Pagina precedente", "chevron.left", enabled: model.pageNumber > 0) { model.pageNumber -= 1 }, action("next", "Pagina successiva", "chevron.right", enabled: (model.pageNumber + 1) * pageSize < count) { model.pageNumber += 1 }]
    }
    private func navigate(_ page: DeckPage) { model.navigate(page); model.load(library: library) }
    private func showSearch() {
        if case .workshop = model.page { model.keyboard = DeckKeyboard(title: "Cerca nel Workshop", text: model.workshopQuery) { model.workshopQuery = $0; model.pageNumber = 0; model.load(library: library) } }
        else { model.keyboard = DeckKeyboard(title: "Cerca nella libreria", text: model.search) { model.search = $0; model.pageNumber = 0; if model.page != .library && model.page != .home { model.navigate(.library) } } }
    }
    private func chooseFolder(_ title: String, purpose: DeckFolderPicker.Purpose = .folder, select: @escaping (URL) -> Void) { model.selected["folder"] = nil; model.picker = DeckFolderPicker(title: title, current: FileManager.default.homeDirectoryForCurrentUser, purpose: purpose, select: select) }
    private func folderActions(_ picker: DeckFolderPicker) -> [DeckAction] {
        var result: [DeckAction] = []
        if picker.purpose == .folder { result.append(action("use", "Usa questa cartella", "checkmark.circle", detail: picker.current.path) { model.picker = nil; picker.select(picker.current) }) }
        result += [action("up", "Cartella superiore", "arrow.up") { model.picker?.current.deleteLastPathComponent(); model.selected["folder"] = nil }, action("home", "Cartella personale", "house") { model.picker?.current = FileManager.default.homeDirectoryForCurrentUser; model.selected["folder"] = nil }, action("volumes", "Dischi e SSD collegati", "externaldrive") { model.picker?.current = URL(fileURLWithPath: "/Volumes"); model.selected["folder"] = nil }, action("cancel", "Annulla scelta", "xmark") { model.picker = nil }]
        let entries = (try? FileManager.default.contentsOfDirectory(at: picker.current, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for file in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let app = file.pathExtension.lowercased() == "app", executable = file.pathExtension.lowercased() == "exe"
            let folder = (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            guard folder || (picker.purpose == .game && executable) else { continue }
            let selectGame = picker.purpose == .game && (app || executable)
            result.append(action(file.path, file.lastPathComponent, selectGame ? "gamecontroller" : "folder") {
                if selectGame { model.picker = nil; picker.select(file) } else { model.picker?.current = file; model.selected["folder"] = nil }
            })
        }
        return result
    }
    private func loadLog(_ url: URL? = nil) {
        model.logPage = 0
        do { model.logText = try AppDiagnostics.tail(url ?? library.diagnostics.file) }
        catch { model.logText = "Nessun log disponibile per questa voce." }
    }
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.035, green: 0.055, blue: 0.10), Color(red: 0.07, green: 0.11, blue: 0.19)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            if let featured, model.keyboard == nil, model.picker == nil, !dialog {
                DeckArtwork(game: featured, kind: .hero).ignoresSafeArea().opacity(0.35)
                LinearGradient(colors: [.black.opacity(0.12), Color(red: 0.035, green: 0.055, blue: 0.10).opacity(0.98)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            }
            VStack(alignment: .leading, spacing: 18) {
                header
                sectionBar
                if let keyboard = model.keyboard { keyboardView(keyboard) }
                else {
                    context
                    ScrollViewReader { proxy in
                        ScrollView {
                            if browsingLibrary {
                                VStack(alignment: .leading, spacing: 22) {
                                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: filterColumns), spacing: 12) {
                                        ForEach(filterActions) { item in tile(item).id(item.id) }
                                    }.id("library-top")
                                    Divider().overlay(.white.opacity(0.12))
                                    featuredSummary
                                    if libraryGameActions.isEmpty { Text(L10n.text("Nessun gioco corrisponde ai filtri selezionati.")).foregroundStyle(.secondary).padding(.vertical, 24) }
                                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: columns), spacing: 18) {
                                        ForEach(libraryGameActions) { item in tile(item).id(item.id) }
                                    }
                                    HStack(spacing: 18) { ForEach(libraryPagination) { item in tile(item).id(item.id) } }
                                }.padding(8)
                            } else if isGameDetail { gameDetailContent } else {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: columns), spacing: 18) {
                                    ForEach(actions) { item in tile(item).id(item.id) }
                                }.padding(8)
                            }
                        }
                        .onChange(of: model.selected[focusKey]) { id in if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(browsingLibrary && (navigationActions + filterActions).contains(where: { $0.id == id }) ? "library-top" : id, anchor: browsingLibrary && filterActions.contains(where: { $0.id == id }) ? .top : .center) } } }
                    }
                }
                footer
            }.padding(30)
        }
        .background(GeometryReader { proxy in Color.clear.onAppear { viewport = proxy.size.width }.onChange(of: proxy.size.width) { viewport = $0 } })
        .foregroundStyle(.white)
        .onAppear { reconcileFocus(); model.load(library: library); if isGameDetail, let game { detail.load(game, library: library) } }
        .onDisappear { detail.cancel() }
        .onChange(of: actions.map(\.id)) { _ in reconcileFocus() }
        .onChange(of: model.page) { _ in
            reconcileFocus(); advancedGame = false
            if model.page == .logs { loadLog() }
            if isGameDetail, let game { detail.load(game, library: library) }
            else { detail.cancel() }
        }
        .onChange(of: appLanguage.code) { _ in if isGameDetail, let game { detail.load(game, library: library) } }
        .onChange(of: library.data.steamAccount?.steamID) { _ in if isGameDetail, let game { detail.load(game, library: library) } }
        .onReceive(controller.commands) { handle($0) }
        .onReceive(library.$installSelection) { selected in if let selected { library.installSelection = nil; navigate(.install(selected.id)) } }
        .onReceive(achievements.$snapshots) { snapshots in
            if let id = game?.steamAppID, let snapshot = snapshots[id] { detail.accept(snapshot) }
            if case .trophies = model.page, let game, let id = game.steamAppID, let snapshot = snapshots[id], snapshot.steamID == library.data.steamAccount?.steamID { model.trophies = snapshot.achievements }
        }
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.text("MacGameDeck")).font(.system(size: 17, weight: .semibold)).foregroundStyle(.mint)
                Text(L10n.text(model.picker?.title ?? model.keyboard?.title ?? model.page.title)).font(.system(size: 34, weight: .bold)).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 14) {
                    Button { experience.settings { $0.bigPicture = false } } label: { Label(L10n.text("Modalità PC"), systemImage: "desktopcomputer") }
                        .buttonStyle(.bordered).help(L10n.text("Passa a mouse e tastiera · ⌘⇧B"))
                    Label(L10n.text(controller.controllerName + (controller.battery.map { " · \($0)%" } ?? "")), systemImage: "gamecontroller.fill").font(.system(size: 14))
                }
                Text(L10n.text("\(controller.label(.previousSection)) / \(controller.label(.nextSection))  Sezioni     \(controller.label(.previousPage)) / \(controller.label(.nextPage))  Pagine")).font(.system(size: 14)).foregroundStyle(.white.opacity(0.65))
            }
        }
    }
    @ViewBuilder private var context: some View {
        if dialog {
            Text(L10n.text(library.error ?? library.notice ?? model.confirmation ?? "")).font(.system(size: 21)).lineLimit(8).textSelection(.enabled)
        } else if let picker = model.picker {
            Text(L10n.text(picker.current.path)).font(.system(size: 18)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
            Text(L10n.text("Scegli una cartella con \(controller.label(.confirm)). \(controller.label(.back)) annulla. I dischi esterni sono in Dischi e SSD collegati.")).font(.system(size: 16))
        } else {
            if let game {
                HStack(spacing: 22) {
                    GameArtwork(game: game).frame(width: 180, height: 100)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(game.title).font(.system(size: 27, weight: .semibold)).lineLimit(2)
                        Text(L10n.text(experience.compatibility(game))).font(.system(size: 17)).foregroundStyle(.mint)
                        HStack {
                            Text(L10n.text(activity.label(game)))
                            if let minutes = game.steamMinutes { Text(L10n.text(String(format: "· %.1f ore Steam", Double(minutes) / 60))) }
                            if isGameDetail, detail.trophiesLoaded { Text(L10n.text("· \(detail.unlocked)/\(detail.trophies.count) trofei")) }
                            else if !isGameDetail, let count = game.steamAchievementsUnlocked, let total = game.steamAchievementsTotal { Text(L10n.text("· \(count)/\(total) trofei")) }
                        }.font(.system(size: 16)).foregroundStyle(.white.opacity(0.7))
                        if let stage = library.launchStages[game.id] { Text(L10n.text(stage)).foregroundStyle(.mint) }
                        if let status = library.cloudStatuses[game.id] { Text(L10n.text(status)).font(.system(size: 15)).lineLimit(2) }
                        if let status = library.gameStatus[game.id] { Text(L10n.text(status)).font(.system(size: 15)).lineLimit(2) }
                        let pending = achievements.pendingCount(game, owner: library.data.steamAccount?.steamID)
                        if pending > 0 { Text(L10n.text("\(pending) trofei in attesa di conferma Steam")).font(.system(size: 15)).foregroundStyle(.orange) }
                    }
                }
            }
            if model.page == .home || model.page == .library {
                Text(L10n.text("\(games.count) giochi · Pagina \(model.pageNumber + 1) · \(controller.label(.favorite)) aggiunge il gioco selezionato ai preferiti")).font(.system(size: 16)).foregroundStyle(.white.opacity(0.65))
            }
            if case .install = model.page {
                Text(L10n.text("Destinazione: " + (game?.storageContainer ?? experience.preferences.storageRoot ?? "Cartella dati MacGameDeck"))).font(.system(size: 16)).lineLimit(2)
                if game != nil, let insights = model.insights {
                    Text(L10n.text("RAM minima pubblicata: " + (insights.minimumRAM(for: .windows).map { "\($0) GB" } ?? "non disponibile") + " · " + library.machine.chip + " · \(library.machine.memoryGB) GB RAM")).font(.system(size: 16)).foregroundStyle(.white.opacity(0.7))
                }
            }
            if model.page == .downloads {
                Text(L10n.text("\(queue.pending.count) in gestione · \(queue.history.count) nella cronologia")).font(.system(size: 18))
                if let active = queue.pending.first(where: { $0.state == .active }) {
                    HStack(spacing: 20) {
                        GameArtwork(game: active.game).frame(width: 180, height: 90)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.text(active.game.title)).font(.system(size: 22, weight: .semibold))
                            ProgressView(value: steam.progress).tint(.mint)
                            Text(L10n.text(steam.message)).font(.system(size: 16)).lineLimit(2)
                        }
                    }
                }
                if let error = queue.storageError { Text(L10n.text(error)).foregroundStyle(.orange) }
            }
            if model.page == .account {
                Text(L10n.text(social.profile?.name ?? (library.data.steamAccount == nil ? "Collega il tuo account per usare la libreria Steam" : "Account Steam collegato"))).font(.system(size: 22, weight: .semibold))
                if let qr = steam.qr { HStack(spacing: 24) { Image(nsImage: qr).interpolation(.none).resizable().frame(width: 200, height: 200).padding(10).background(.white).cornerRadius(12); Text(L10n.text("Scansiona il QR con Steam Guard sul telefono. La sessione viene ricordata: non servirà ripetere il login a ogni download.")).font(.system(size: 20)).frame(maxWidth: 500) } }
                if !library.steamMessage.isEmpty { Text(L10n.text(library.steamMessage)).font(.system(size: 16)).lineLimit(2) }
            }
            if model.page == .controllers {
                Text(L10n.text(controller.readings)).font(.system(size: 17, design: .monospaced)).foregroundStyle(.mint)
                Text(L10n.text(controllerHelp)).font(.system(size: 20)).lineSpacing(8)
                Text(L10n.text("Le finestre di abbinamento e i permessi di macOS restano gestiti dal sistema. Il layout segue i comandi logici del controller.")).font(.system(size: 15)).foregroundStyle(.white.opacity(0.65))
            }
            if model.page == .logs {
                let lines = model.logText.components(separatedBy: .newlines)
                Text(lines.dropFirst(min(model.logPage * 8, max(0, lines.count - 1))).prefix(8).joined(separator: "\n")).font(.system(size: 14, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).lineLimit(10).padding(14).background(.white.opacity(0.035)).cornerRadius(10)
            }
            if !model.status.isEmpty { Text(L10n.text(model.status)).font(.system(size: 18)).foregroundStyle(.white.opacity(0.8)).lineLimit(5) }
            if model.loading { ProgressView(L10n.text("Caricamento · " + controller.label(.back) + " per tornare indietro")).tint(.mint) }
        }
    }
    private var featured: Game? {
        game ?? actions.first(where: { $0.id == model.selected[focusKey] })?.game ?? games.first
    }
    private var sectionBar: some View {
        HStack(spacing: 8) {
            ForEach(Array(DeckPage.sections.enumerated()), id: \.offset) { _, page in
                Button { navigate(page) } label: {
                    Text(L10n.text(page == .home ? "Home" : page.title)).font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(model.page == page ? Color.mint.opacity(0.22) : Color.white.opacity(0.04))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(browsingLibrary && model.selected[focusKey] == "section-" + page.key ? Color.mint : .clear, lineWidth: 3))
                }.buttonStyle(.plain).focusable(false)
            }
            Spacer(minLength: 0)
        }
        .accessibilityLabel(L10n.text("Sezioni · usa i dorsali per cambiare"))
    }
    @ViewBuilder private var featuredSummary: some View {
        if let featured {
            VStack(alignment: .leading, spacing: 8) {
                if let logo = artwork.image(featured, kind: .logo) {
                    Image(nsImage: logo).resizable().scaledToFit().frame(width: min(viewport * 0.3, 360), height: 56, alignment: .leading).accessibilityLabel(L10n.text(featured.title))
                } else { Text(featured.title).font(.system(size: viewport >= 1500 ? 40 : 29, weight: .bold)).lineLimit(1) }
                HStack(spacing: 18) {
                    Label(L10n.text(featured.isInstalled ? "Pronto nella libreria" : "Disponibile da installare"), systemImage: featured.isInstalled ? "checkmark.circle" : "arrow.down.circle")
                    Text(L10n.text(featured.store.rawValue))
                    if let minutes = featured.steamMinutes { Text(L10n.text(String(format: "%.1f ore Steam", Double(minutes) / 60))) }
                }.font(.system(size: 15)).foregroundStyle(.white.opacity(0.75))
                if let asset = artwork.asset(featured, kind: .hero), asset.source == "SteamGridDB" {
                    Text(L10n.text("Artwork: " + asset.author + " · SteamGridDB")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
            }.padding(.vertical, 6)
                .task(id: featured.identity + String(artwork.revision)) { await artwork.ensure(featured, kind: .logo) }
        }
    }
    private func tile(_ item: DeckAction) -> some View {
        let focused = (model.selected[focusKey] ?? actions.first?.id) == item.id
        return Button {
            model.selected[focusKey] = item.id
            if item.enabled { item.run() }
        } label: {
            Group {
                if let game = item.game {
                    VStack(alignment: .leading, spacing: 10) {
                        DeckArtwork(game: game, kind: .cover).aspectRatio(2.0 / 3.0, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(alignment: .topTrailing) {
                                if experience.game(game).favorite { Image(systemName: "star.fill").foregroundStyle(.yellow).padding(10).background(.black.opacity(0.6)).clipShape(Circle()).padding(8) }
                            }
                        Text(item.title).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                        Text(L10n.text(item.detail)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        if let asset = artwork.asset(game, kind: .cover), asset.source == "SteamGridDB" { Text(L10n.text(asset.author + " · SteamGridDB")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1) }
                    }.padding(10)
                } else {
                    HStack(alignment: .center, spacing: 14) {
                        if let achievement = item.achievement {
                            AsyncImage(url: achievement.imageURL) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: item.symbol).foregroundStyle(achievement.unlocked ? .yellow : .secondary) }.frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 7))
                        } else { Image(systemName: item.symbol).font(.system(size: 21, weight: .medium)).foregroundStyle(focused ? .mint : .white.opacity(0.65)).frame(width: 26) }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                            if !item.detail.isEmpty { Text(L10n.text(item.detail)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(2) }
                            if !item.enabled { Text(L10n.text("Non disponibile ora")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)) }
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, minHeight: 54, alignment: .leading).padding(16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(focused ? Color.mint.opacity(0.15) : Color.black.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(focused ? Color.mint : Color.white.opacity(0.07), lineWidth: focused ? 3 : 1))
            .shadow(color: focused ? .mint.opacity(0.18) : .clear, radius: 15)
            .opacity(item.enabled ? 1 : 0.5)
            .scaleEffect(focused ? 1.02 : 1)
        }
        .buttonStyle(.plain).focusable(false)
        .accessibilityLabel(L10n.text(item.title + (focused ? ", selezionato" : "")))
        .accessibilityHint(L10n.text(item.enabled ? controller.label(.confirm) + " per confermare" : "Azione non disponibile"))
        .onHover { inside in if inside { model.selected[focusKey] = item.id } }
    }
    private var controllerHelp: String {
        "Croce/levetta: seleziona · \(controller.label(.confirm)): conferma · \(controller.label(.back)): indietro · \(controller.label(.search)): cerca · \(controller.label(.favorite)): preferito\n\(controller.label(.previousSection))/\(controller.label(.nextSection)): sezioni · \(controller.label(.previousPage))/\(controller.label(.nextPage)): pagine\n\(controller.label(.menu)): Home. Dal gioco, tienilo per 1,2 secondi per tornare qui."
    }
    private func commandHint(_ command: DeckCommand, _ title: String) -> some View {
        Label(L10n.text(title), systemImage: controller.glyph(command).symbol).labelStyle(.titleAndIcon)
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if library.engine.busy { ProgressView(value: library.engine.progress).tint(.mint); Text(L10n.text(library.engine.message)).font(.system(size: 15)).lineLimit(2) }
            if steam.busy || steam.preparing { HStack { ProgressView().controlSize(.small); Text(L10n.text(steam.message)).font(.system(size: 15)).lineLimit(2) } }
            HStack(spacing: 22) {
                commandHint(.confirm, "Conferma").foregroundStyle(.mint)
                commandHint(.back, "Indietro")
                commandHint(.search, "Cerca")
                commandHint(.menu, "Home")
                commandHint(.interfaceMode, "Modalità PC")
                Spacer()
                Text(L10n.text("0.15.0 · ⌘⇧B Modalità PC")).foregroundStyle(.white.opacity(0.45))
            }.font(.system(size: 16, weight: .medium))
            if !controller.connected { Text(L10n.text("Collega un controller. Puoi anche usare frecce, Invio, Esc, Tab e X/Y per provare la navigazione.")).font(.system(size: 14)).foregroundStyle(.orange) }
        }.padding(.top, 8)
    }
    private func keyboardView(_ keyboard: DeckKeyboard) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(L10n.text(keyboard.text.isEmpty ? "Scrivi usando la tastiera a schermo" : (keyboard.secure ? String(repeating: "•", count: keyboard.text.count) : keyboard.text) + " ▌")).font(.system(size: 28)).lineLimit(2).frame(maxWidth: .infinity, minHeight: 70, alignment: .leading).padding(18).background(.white.opacity(0.08)).cornerRadius(12)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: DeckKeyboard.columns), spacing: 12) {
                ForEach(Array(DeckKeyboard.keys.enumerated()), id: \.offset) { index, key in
                    Button { model.keyboard?.selected = index; typeKey(key) } label: {
                        Text(L10n.text(keyboard.lowercase && key.count == 1 ? key.lowercased() : key)).font(.system(size: key.count > 3 ? 14 : 24, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 48).padding(5).background(keyboard.selected == index ? Color.mint.opacity(0.3) : Color.white.opacity(0.06)).overlay(RoundedRectangle(cornerRadius: 9).stroke(keyboard.selected == index ? Color.mint : Color.clear, lineWidth: 3)).cornerRadius(9)
                    }.buttonStyle(.plain).focusable(false)
                }
            }
            Text(L10n.text("Croce o levetta: seleziona · \(controller.label(.confirm)): scrivi · \(controller.label(.search)): cancella · \(controller.label(.menu)): conferma · \(controller.label(.back)): annulla")).font(.system(size: 17)).foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 0)
        }
    }
    private func typeKey(_ key: String) {
        guard let keyboard = model.keyboard else { return }
        switch key {
        case "⇧": model.keyboard?.lowercase.toggle()
        case "Annulla": model.keyboard = nil
        case "Conferma": model.keyboard = nil; keyboard.submit(keyboard.text)
        case "⌫": if !keyboard.text.isEmpty { model.keyboard?.text.removeLast() }
        case "Cancella": model.keyboard?.text = ""
        case "Spazio": if keyboard.text.count < 200 { model.keyboard?.text += " " }
        default: if keyboard.text.count < 200 { model.keyboard?.text += (keyboard.lowercase ? key.lowercased() : key) }
        }
    }
    private func reconcileFocus() {
        let ids = actions.map(\.id)
        if let current = model.selected[focusKey], ids.contains(current) { return }
        model.selected[focusKey] = browsingLibrary ? filterActions.first?.id : ids.first
    }
    private func handle(_ command: DeckCommand) {
        guard !controller.sessionMenuVisible, !controller.navigationSuspended else { return }
        if model.keyboard != nil {
            switch command {
            case .back: model.keyboard = nil
            case .confirm: if let index = model.keyboard?.selected { typeKey(DeckKeyboard.keys[index]) }
            case .erase, .search: typeKey("⌫")
            case .menu: typeKey("Conferma")
            case .up, .down, .left, .right: if let index = model.keyboard?.selected { model.keyboard?.selected = DeckFocusNavigation.move(command, current: index, count: DeckKeyboard.keys.count, columns: DeckKeyboard.columns) }
            default: break
            }; return
        }
        if command == .home { return } // Root activates the existing window and preserves this page.
        if command == .back {
            if library.error != nil { library.error = nil; library.cloudLaunchFailure = nil }
            else if library.notice != nil { library.notice = nil }
            else { model.back(); model.load(library: library) }
            return
        }
        if dialog {
            if command == .confirm { activateSelected() }
            else if [.up, .down, .left, .right].contains(command) { moveFocus(command) }
            return
        }
        if model.picker != nil {
            if command == .confirm { activateSelected() }
            else if [.up, .down, .left, .right].contains(command) { moveFocus(command) }
            return
        }
        switch command {
        case .confirm: activateSelected()
        case .up, .down, .left, .right: moveFocus(command)
        case .search: showSearch()
        case .favorite:
            let current = actions.first { $0.id == model.selected[focusKey] }?.game ?? game
            if let current { experience.update(current) { $0.favorite.toggle() } }
        case .previousSection: model.section(-1)
        case .nextSection: model.section(1)
        case .previousPage: if let previous = actions.first(where: { $0.id == "previous" }), previous.enabled { previous.run() }
        case .nextPage: if let next = actions.first(where: { $0.id == "next" }), next.enabled { next.run() }
        case .menu: model.navigate(.home, replacing: true)
        default: break
        }
    }
    private func activateSelected() {
        guard let id = model.selected[focusKey], let action = actions.first(where: { $0.id == id }) else { reconcileFocus(); return }
        if action.enabled { action.run() }
    }
    private func moveFocus(_ command: DeckCommand) {
        let list = actions
        guard !list.isEmpty else { return }
        let current = list.firstIndex(where: { $0.id == model.selected[focusKey] }) ?? 0
        let next = browsingLibrary
            ? DeckFocusNavigation.moveSections(command, current: current, counts: [navigationActions.count, filterActions.count, libraryGameActions.count, libraryPagination.count], columns: [DeckPage.sections.count, filterColumns, columns, 2])
            : isGameDetail ? DeckFocusNavigation.moveSections(command, current: current, counts: [primaryGameActions.count, detailInformationActions.count, detailTrophyActions.count, communityGameActions.count, advancedGameActions.count], columns: [2, 2, 2, 2, 2])
            : DeckFocusNavigation.move(command, current: current, count: list.count, columns: columns)
        model.selected[focusKey] = list[next].id
    }
}
