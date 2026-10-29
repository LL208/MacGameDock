import SwiftUI

struct SteamOperationView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @EnvironmentObject var steam: ManagedSteam
    var body: some View {
        if steam.busy || !steam.message.isEmpty {
            HStack(spacing: 20) {
                if let qr = steam.qr {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 180, height: 180)
                        .padding(12).background(.white).cornerRadius(10)
                } else if steam.busy { ProgressView().controlSize(.small) }
                Text(L10n.text(steam.message)).frame(maxWidth: .infinity, alignment: .leading)
                if steam.busy { Button(L10n.text("Annulla")) { steam.cancel() } }
            }.padding(20).background(.regularMaterial)
        }
    }
}
struct SteamAccountView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @EnvironmentObject var library: Library
    @EnvironmentObject var steam: ManagedSteam
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(L10n.text("Account Steam")).font(.largeTitle.bold())
            Text(L10n.text("Accedi con Steam Guard per caricare la libreria e installare i giochi direttamente nei container di MacGameDeck."))
                .foregroundStyle(.secondary)
            if let account = library.data.steamAccount {
                let ready = steam.hasSavedSession && steam.savedAccountID == account.steamID
                Label(L10n.text(ready ? "Sessione per i download salvata" : "Profilo riconosciuto · download da abilitare"),
                      systemImage: ready ? "checkmark.circle.fill" : "person.crop.circle")
                    .foregroundStyle(ready ? Color.mint : Color.orange)
                if !ready {
                    Text(L10n.text("La libreria è stata collegata, ma manca una sessione per scaricare. L'accesso nel client Steam o il vecchio login del profilo non autorizzano questo installatore. Completa il QR una volta, oppure importa la sessione precedente."))
                        .font(.callout).foregroundStyle(.secondary)
                    Button(L10n.text("Abilita download automatici")) { library.connectSteam() }
                        .buttonStyle(.borderedProminent).disabled(library.signingIn || steam.busy)
                }
                Text(L10n.text("SteamID: \(account.steamID)")).font(.caption.monospaced())
                HStack {
                    Button(L10n.text("Aggiorna libreria")) { library.syncSteam() }
                    Button(L10n.text("Ricollega con QR")) { library.reconnectSteam() }
                    Button(L10n.text("Scollega"), role: .destructive) { library.disconnectSteam() }
                }.disabled(library.signingIn || steam.busy)
            } else {
                Button(L10n.text("Accedi con QR Steam")) { library.connectSteam() }
                    .buttonStyle(.borderedProminent).disabled(library.signingIn || steam.busy)
            }
            Text(L10n.text("Scansiona il QR con l'app Steam sul telefono. La sessione viene conservata in una cartella privata del tuo utente: l'accesso successivo è automatico finché Steam la considera valida, senza aprire il Portachiavi."))
                .foregroundStyle(.secondary)
            Button(L10n.text("Importa sessione della versione precedente")) { library.importPreviousSession() }
                .disabled(library.signingIn || steam.busy)
            Text(L10n.text("L'importazione facoltativa può chiedere lo sblocco del Portachiavi una volta. In alternativa accedi con QR una volta: poi la sessione viene riutilizzata."))
                .font(.caption).foregroundStyle(.secondary)
            if !library.steamMessage.isEmpty { Text(L10n.text(library.steamMessage)) }
            Text(L10n.text("Non è richiesta una chiave Web API. La disponibilità del download dipende dalle licenze dell'account; l'avvio dipende dal runtime e dai servizi richiesti dal gioco."))
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
