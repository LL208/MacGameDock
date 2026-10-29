import SwiftUI

struct GameSessionMenu: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject var session: GameSessionCoordinator
    @ObservedObject var library: Library
    @ObservedObject var activity: PlayActivity
    @ObservedObject var achievements: AchievementMonitor
    @ObservedObject var controller: DeckControllerInput
    let game: Game
    @StateObject private var detail = GameDetailModel()
    @State private var section = 0
    @State private var selected = 0
    @State private var trophyPage = 0
    @State private var confirmingExit = false
    @State private var forceExit = false
    private let sections = ["Sessione", "Trofei", "Controller"]
    private var actions: [(String, () -> Void)] {
        if confirmingExit {
            return [("Annulla", { confirmingExit = false }), (forceExit ? "Termina il processo del gioco" : "Conferma uscita dal gioco", { confirmingExit = false; session.requestExit(force: forceExit) })]
        }
        var result: [(String, () -> Void)] = [
            ("Riprendi il gioco", { session.resume() }),
            ("Sessione", { section = 0 }), ("Trofei", { section = 1 }), ("Controller", { section = 2 })]
        if section == 1 && detail.trophies.count > 6 {
            result.append(("Pagina trofei precedente", { trophyPage = max(0, trophyPage - 1) }))
            result.append(("Pagina trofei successiva", { trophyPage = min(max(0, (detail.trophies.count - 1) / 6), trophyPage + 1) }))
        }
        if section == 2 {
            result.append(("Rimappa il controller in macOS", { session.openControllerSettings() }))
            result.append(("Inverti Conferma / Indietro: " + (library.experience.preferences.swapControllerConfirmBack == true ? "Sì" : "No"), { library.experience.settings { $0.swapControllerConfirmBack = !($0.swapControllerConfirmBack == true) } }))
        }
        if !session.accessibilityAllowed { result.append(("Abilita gestione finestre e schermi", { session.requestAccessibility() })) }
        result.append(("Esci dal gioco…", { forceExit = false; confirmingExit = true; selected = 0 }))
        result.append(("Il gioco non risponde: termina…", { forceExit = true; confirmingExit = true; selected = 0 }))
        return result
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Label(L10n.text("Menu di gioco"), systemImage: "gamecontroller.fill").foregroundStyle(.mint); Spacer(); Text(L10n.text(controller.label(.home) + " · Riprendi")).foregroundStyle(.secondary) }
                    Text(game.title).font(.largeTitle.bold()).id("session-top")
                    if confirmingExit {
                        Text(L10n.text(forceExit ? "Terminare il processo può perdere i progressi non salvati." : "Salva i progressi prima di uscire. Il gioco potrebbe chiedere una conferma.")).foregroundStyle(.orange)
                    } else {
                        Text(L10n.text(sections[section])).font(.title2.bold())
                        if section == 0 {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                HStack(spacing: 30) {
                                    metric("Questa sessione", duration(session.elapsed(game)))
                                    metric("Su Steam", game.steamMinutes.map { String(format: "%.1f ore", Double($0) / 60) } ?? "Non disponibile")
                                }
                            }
                            Text(L10n.text(activity.label(game))).foregroundStyle(.secondary)
                            Text(L10n.text("Il gioco resta in esecuzione mentre il menu è aperto. Le ore Steam sono quelle dell’ultima sincronizzazione.")).font(.caption).foregroundStyle(.secondary)
                            Text(L10n.text(achievements.status[game.id] ?? "I trofei vengono aggiornati quando il gioco invia gli eventi Steam supportati.")).font(.caption)
                        } else if section == 1 {
                            GameTrophySummary(detail: detail)
                            ForEach(Array(detail.trophies.sorted { $0.unlocked && !$1.unlocked }.dropFirst(trophyPage * 6).prefix(6)), id: \.name) { item in SteamAchievementRow(achievement: item) }
                            if detail.trophies.count > 6 { Text(L10n.text("Pagina \(trophyPage + 1) di \((detail.trophies.count + 5) / 6)")).font(.caption) }
                        } else {
                            Label(L10n.text(controller.controllerName), systemImage: "gamecontroller.fill")
                            if let battery = controller.battery { Text(L10n.text("Batteria: \(battery)%")) }
                            Text(L10n.text("La rimappatura nei giochi usa i profili controller di macOS. Conferma / Indietro modifica soltanto l’interfaccia di MacGameDeck. Il supporto delle mappature di sistema nei giochi Windows dipende dal runtime.")).font(.callout).foregroundStyle(.secondary)
                        }
                        if !session.status.isEmpty { Text(L10n.text(session.status)).font(.callout).foregroundStyle(.orange) }
                    }
                    ForEach(Array(actions.enumerated()), id: \.offset) { index, item in
                        Button { item.1() } label: {
                            HStack { Text(L10n.text(item.0)).font(.headline); Spacer(); if selected == index { Text(L10n.text(controller.label(.confirm))).foregroundStyle(.mint) } }
                                .padding(14).frame(maxWidth: .infinity).background(selected == index ? Color.mint.opacity(0.18) : Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected == index ? Color.mint : .clear, lineWidth: 2))
                        }.buttonStyle(.plain).id(index)
                    }
                    Text(L10n.text("\(controller.label(.back)) · Riprendi    L1 / R1 · Sezione    Menu tenuto premuto · Alternativa a Home")).font(.caption).foregroundStyle(.secondary)
                }.padding(26)
            }
            .onChange(of: selected) { value in withAnimation { proxy.scrollTo(value, anchor: .center) } }
            .onChange(of: section) { _ in withAnimation { proxy.scrollTo("session-top", anchor: .top) } }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { detail.load(game, library: library) }
        .onDisappear { detail.cancel() }
        .onReceive(achievements.$snapshots) { snapshots in if let id = game.steamAppID, let value = snapshots[id] { detail.accept(value) } }
        .onReceive(controller.commands) { command in
            guard session.menuVisible else { return }
            switch command {
            case .back: if confirmingExit { confirmingExit = false; selected = 0 } else { session.resume() }
            case .confirm: let list = actions; if list.indices.contains(selected) { list[selected].1() }
            case .up, .down: selected = DeckFocusNavigation.move(command, current: selected, count: actions.count, columns: 1)
            case .previousSection, .nextSection: section = (section + (command == .nextSection ? 1 : 2)) % 3; selected = 0
            case .previousPage: trophyPage = max(0, trophyPage - 1)
            case .nextPage: trophyPage = min(max(0, (detail.trophies.count - 1) / 6), trophyPage + 1)
            default: break
            }
        }
    }
    private func metric(_ label: String, _ value: String) -> some View { VStack(alignment: .leading) { Text(L10n.text(label)).font(.caption).foregroundStyle(.secondary); Text(L10n.text(value)).font(.title2.monospacedDigit()) } }
    private func duration(_ value: TimeInterval) -> String { let seconds = Int(value); return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
}
