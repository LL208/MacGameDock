import AppKit
import SwiftUI
import WebKit

struct SteamCommunityPage: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, url.scheme == "https", let host = url.host,
                  host == "steamcommunity.com" || host.hasSuffix(".steamcommunity.com") || host == "store.steampowered.com" else { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
    }
}

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
    @EnvironmentObject var library: Library
    @EnvironmentObject var steam: ManagedSteam
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "Workshop"
    @State private var input = ""
    @State private var downloading = false
    @State private var ownsSteamOperation = false
    @State private var task: Task<Void, Never>?
    @State private var downloaded: URL?
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(game.title).font(.title2.bold()); Spacer(); Button("Chiudi") { dismiss() } }
            Picker("Sezione", selection: $tab) { Text("Workshop e mod").tag("Workshop"); Text("Trofei Steam").tag("Trofei") }.pickerStyle(.segmented)
            if let id = game.steamAppID {
                if tab == "Workshop" {
                    Text("Sfoglia il Workshop e incolla il link della mod. Il download non crea un'iscrizione Steam. Il gioco deve supportare le mod e il loro formato.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Link o ID Workshop", text: $input).textFieldStyle(.roundedBorder)
                        Button("Scarica mod") { download(id) }.disabled(downloading || steam.busy || library.steamServices.busy || library.signingIn || library.syncingSteam || library.running.contains(game.id))
                        if downloading { Button("Annulla") { task?.cancel(); if ownsSteamOperation { steam.cancel() } } }
                    }
                    if let folder = downloaded {
                        HStack { Button("Mostra download") { NSWorkspace.shared.open(folder) }; Button("Installa in cartella mod…") { installMod(folder) }.disabled(library.running.contains(game.id)) }
                    }
                    if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
                    SteamCommunityPage(url: URL(string: "https://steamcommunity.com/app/\(id)/workshop/")!).id("workshop-\(id)")
                } else {
                    Text("I trofei ufficiali vengono sbloccati dal gioco tramite Steamworks. Gioca con Steam avvia il titolo tramite il client ufficiale nello stesso ambiente, così il gioco può registrare gli obiettivi ottenuti. Questa pagina mostra i trofei pubblicati da Steam; i profili privati possono richiedere accesso web separato. La sincronizzazione dipende dal gioco e dalla connessione.").font(.callout).foregroundStyle(.secondary)
                    if let owner = library.data.steamAccount?.steamID {
                        SteamCommunityPage(url: URL(string: "https://steamcommunity.com/profiles/\(owner)/stats/\(id)/?tab=achievements")!).id("trophies-\(id)-\(owner)")
                    } else { Text("Collega l'account Steam per visualizzare i suoi trofei.") }
                }
            }
        }.padding(24).frame(minWidth: 850, minHeight: 640)
        .onDisappear { if downloading { task?.cancel(); if ownsSteamOperation { steam.cancel() } } }
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
                guard !steam.busy, !library.steamServices.busy, !library.signingIn, !library.syncingSteam else { throw DockError.message("Attendi l'operazione Steam in corso.") }
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
            message = "File copiati in \(destination.path). Segui le istruzioni della mod per l'attivazione."
        } catch { message = error.localizedDescription }
    }
}
