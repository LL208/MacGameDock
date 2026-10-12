import SwiftUI

struct SteamOperationView: View {
    @EnvironmentObject var steam: ManagedSteam
    var body: some View {
        if steam.busy || !steam.message.isEmpty {
            HStack(spacing: 20) {
                if let qr = steam.qr {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 180, height: 180)
                        .padding(12).background(.white).cornerRadius(10)
                } else if steam.busy { ProgressView().controlSize(.small) }
                Text(steam.message).frame(maxWidth: .infinity, alignment: .leading)
                if steam.busy { Button("Annulla") { steam.cancel() } }
            }.padding(20).background(.regularMaterial)
        }
    }
}
struct SteamAccountView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var steam: ManagedSteam
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Account Steam").font(.largeTitle.bold())
            Text("Accedi con Steam Guard per caricare la libreria e installare i giochi direttamente nei container di MacGameDeck.")
                .foregroundStyle(.secondary)
            if let account = library.data.steamAccount {
                Label("Account collegato", systemImage: "checkmark.circle.fill").foregroundStyle(.mint)
                Text("SteamID: \(account.steamID)").font(.caption.monospaced())
                HStack {
                    Button("Aggiorna libreria") { library.syncSteam() }
                    Button("Ricollega con QR") { library.connectSteam() }
                    Button("Scollega", role: .destructive) { library.disconnectSteam() }
                }.disabled(library.signingIn || steam.busy)
            } else {
                Button("Accedi con QR Steam") { library.connectSteam() }
                    .buttonStyle(.borderedProminent).disabled(library.signingIn || steam.busy)
            }
            Text("Scansiona il QR con l'app Steam sul telefono. La sessione viene conservata nel Portachiavi: l'accesso successivo è automatico finché Steam la considera valida.")
                .foregroundStyle(.secondary)
            if !library.steamMessage.isEmpty { Text(library.steamMessage) }
            Text("Non è richiesta una chiave Web API. La disponibilità del download dipende dalle licenze dell'account; l'avvio dipende dal runtime e dai servizi richiesti dal gioco.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
