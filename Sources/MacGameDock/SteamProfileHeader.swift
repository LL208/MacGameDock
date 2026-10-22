import SwiftUI

struct SteamProfileHeader: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var social: SteamSocial
    private var color: Color {
        switch social.profile?.persona ?? .offline {
        case .online, .play, .trade: return .mint
        case .busy, .away, .snooze: return .orange
        case .offline, .invisible: return .secondary
        }
    }
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: social.profile?.imageURL) { image in image.resizable().scaledToFill() } placeholder: {
                Image(systemName: "person.crop.square.fill").resizable().foregroundStyle(.secondary)
            }.frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(social.profile?.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Account Steam").font(.headline)
                if social.connecting { ProgressView("Connessione…").controlSize(.small) }
                else if social.connected {
                    Menu {
                        ForEach(SteamPersona.allCases) { state in
                            Button { social.setPresence(state) } label: {
                                if social.profile?.persona == state { Label(state.label, systemImage: "checkmark") } else { Text(state.label) }
                            }
                        }
                    } label: { HStack(spacing: 5) { Circle().fill(color).frame(width: 7, height: 7); Text(social.profile?.persona.label ?? "Offline") } }
                        .menuStyle(.borderlessButton).fixedSize().disabled(social.changingPresence)
                } else {
                    Button("Connetti Steam") {
                        if let owner = library.data.steamAccount?.steamID { social.start(owner: owner) } else { library.connectSteam() }
                    }
                }
                if !social.status.isEmpty { Text(social.status).font(.caption2).foregroundStyle(.orange).lineLimit(2).frame(maxWidth: 230, alignment: .leading) }
            }
        }
    }
}
