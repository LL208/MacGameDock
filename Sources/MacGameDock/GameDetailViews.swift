import SwiftUI

struct GameOverviewView: View {
    @ObservedObject var detail: GameDetailModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Informazioni sul gioco").font(.title2.bold())
            if detail.metadataLoading && detail.insights == nil { ProgressView("Caricamento descrizione e modalità…") }
            if let info = detail.insights {
                if !info.genres.isEmpty { Text(info.genres.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary) }
                Text(detail.expandedDescription && !info.longDescription.isEmpty ? info.longDescription : (info.description.isEmpty ? "Descrizione non disponibile nello store." : info.description))
                    .font(.body).lineSpacing(4).lineLimit(detail.expandedDescription ? nil : 5).frame(maxWidth: .infinity, alignment: .leading)
                if !info.developers.isEmpty { Text("Sviluppatore: " + info.developers.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                card("Giocatori online su Steam", value: detail.players.map { $0.count.formatted(.number) } ?? "—", icon: "person.3.fill", note: detail.playersStatus)
                card("Giocatore singolo", value: support(detail.insights?.singlePlayer), icon: "person.fill")
                card("Multiplayer online", value: support(detail.insights?.onlineMultiplayer), icon: "network")
                card("Cooperativa locale", value: support(detail.insights?.localCoop), icon: "person.2.fill")
                card("Schermo condiviso / split-screen", value: support(detail.insights?.localSharedScreen), icon: "rectangle.split.2x1")
                card("Giocatori locali massimi", value: "Non specificato", icon: "gamecontroller.fill", note: "Lo store non fornisce un limite affidabile")
            }
            Text("Le modalità sono dichiarate dallo store: schermo condiviso e split-screen non vengono distinti. Il conteggio Steam indica chi sta giocando online, non il numero massimo per partita.").font(.caption).foregroundStyle(.secondary)
            if !detail.metadataStatus.isEmpty { Text(detail.metadataStatus).font(.caption).foregroundStyle(.secondary) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 16))
    }
    private func support(_ value: Bool?) -> String { value == true ? "Disponibile" : value == false ? "Non dichiarato" : "Dato non disponibile" }
    private func card(_ title: String, value: String, icon: String, note: String = "") -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
            if !note.isEmpty { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading).padding(12).background(.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
struct GameTrophySummary: View {
    @ObservedObject var detail: GameDetailModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("I tuoi trofei", systemImage: "trophy.fill").font(.title2.bold())
                Spacer()
                if detail.trophiesLoading { ProgressView().controlSize(.small) }
                if detail.trophiesLoaded { Text("\(detail.unlocked) / \(detail.trophies.count)").font(.headline).monospacedDigit() }
            }
            if !detail.trophies.isEmpty { ProgressView(value: Double(detail.unlocked), total: Double(detail.trophies.count)).tint(.mint) }
            Text(detail.trophyStatus.isEmpty ? "Caricamento automatico dei trofei…" : detail.trophyStatus).font(.caption).foregroundStyle(.secondary)
        }
    }
}
