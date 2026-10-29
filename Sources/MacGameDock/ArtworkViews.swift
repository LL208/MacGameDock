import SwiftUI

struct DeckArtwork: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let game: Game
    var kind: ArtworkKind = .landscape
    @EnvironmentObject var artwork: ArtworkStore
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [.indigo.opacity(0.65), .black.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "gamecontroller.fill").font(.system(size: 30)).foregroundStyle(.mint.opacity(0.8))
                if let image = artwork.image(game, kind: kind) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped()
                }
            }.frame(width: proxy.size.width, height: proxy.size.height).clipped()
        }
        .task(id: game.identity + kind.rawValue + String(artwork.revision)) { await artwork.ensure(game, kind: kind) }
        .accessibilityHidden(true)
    }
}
struct ArtworkSettingsView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @EnvironmentObject var artwork: ArtworkStore
    @State private var key = ""
    var body: some View {
        GroupBox(L10n.text("Copertine e sfondi · SteamGridDB")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text(artwork.message)).foregroundStyle(.secondary)
                SecureField(L10n.text("Chiave API SteamGridDB"), text: $key)
                HStack {
                    Button(L10n.text("Salva chiave")) { artwork.configure(key); key = "" }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if artwork.configured { Button(L10n.text("Scollega")) { artwork.configure("") } }
                    Button(L10n.text("Aggiorna immagini")) { artwork.refresh() }
                    Link("Ottieni una chiave personale", destination: URL(string: "https://www.steamgriddb.com/profile/preferences/api")!)
                }
                Text(L10n.text("Copertine e sfondi vengono cercati automaticamente. La chiave resta sul Mac; le immagini sono conservate in cache per l’uso offline. Artwork degli autori SteamGridDB; in assenza di risultati vengono usate le immagini Steam.")).font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
    }
}
