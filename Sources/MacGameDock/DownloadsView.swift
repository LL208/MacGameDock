import SwiftUI

struct GameArtwork: View {
    let game: Game
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.4))
            Image(systemName: "gamecontroller.fill").foregroundStyle(.mint)
            if let id = game.steamAppID {
                let url = game.iconHash.flatMap { hash in
                    hash.isEmpty ? nil : URL(string: "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/\(id)/\(hash).jpg")
                } ?? URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/header.jpg")
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
            }
        }.clipped().clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
struct DownloadsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var queue: DownloadQueue
    @EnvironmentObject var steam: ManagedSteam
    private var active: DownloadJob? { queue.pending.first { $0.state == .active } }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download").font(.largeTitle.bold())
                    Text("\(queue.pending.count) in gestione · \(queue.history.count) nella cronologia").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Pausa tutto", systemImage: "pause.fill") { queue.pauseAll() }.disabled(!queue.pending.contains { [.active, .queued].contains($0.state) })
                Button("Riprendi", systemImage: "play.fill") { queue.resumeAll() }.disabled(!queue.pending.contains { $0.state == .paused } || queue.storageError != nil)
            }
            if let error = queue.storageError { Text(error).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let active {
                        downloadRow(active, featured: true)
                    } else {
                        Label("Nessun download in corso", systemImage: "checkmark.circle").font(.title3).padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Color.mint.opacity(0.07)).cornerRadius(14)
                    }
                    Text("IN CODA E INTERROTTI").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(queue.pending.filter { $0.state != .active }) { downloadRow($0) }
                    if queue.pending.isEmpty { Text("Scegli un gioco dalla libreria per installarlo.").foregroundStyle(.secondary) }
                    Divider().padding(.vertical, 8)
                    HStack {
                        Text("CRONOLOGIA").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Svuota cronologia") { queue.clearHistory() }.disabled(queue.history.isEmpty)
                    }
                    ForEach(queue.history) { downloadRow($0) }
                    if queue.history.isEmpty { Text("I download conclusi appariranno qui.").foregroundStyle(.secondary) }
                }.padding(.bottom, 20)
            }
            Text("Pausa e annullamento conservano i file già scaricati. Rimuovere una voce dalla cronologia non disinstalla il gioco.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func downloadRow(_ job: DownloadJob, featured: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 18) {
            GameArtwork(game: job.game).frame(width: featured ? 160 : 84, height: featured ? 100 : 62)
            VStack(alignment: .leading, spacing: 9) {
                Text(job.game.title).font(featured ? .title2.bold() : .headline)
                Text("\(job.platform.label) · \(job.state.label)").font(.caption).foregroundStyle(.secondary)
                if job.state == .active && steam.activeGame == job.game.id {
                    ProgressView(value: steam.progress).tint(.mint)
                    HStack {
                        Text(steam.message).lineLimit(2)
                        Spacer()
                        if steam.totalBytes > 0 { Text("\(ByteCountFormatter.string(fromByteCount: Int64(steam.downloadedBytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(steam.totalBytes), countStyle: .file))") }
                    }.font(.caption)
                    if steam.bytesPerSecond > 0 {
                        Text(String(format: "%.1f MB/s · circa %.0f min rimanenti", steam.bytesPerSecond / 1_048_576, max(0, steam.totalBytes - steam.downloadedBytes) / steam.bytesPerSecond / 60)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let date = job.finishedAt { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
                if let error = job.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                if [.active, .queued].contains(job.state) { Button("Pausa", systemImage: "pause.fill") { queue.pause(job.id) } }
                if [.active, .queued, .paused, .failed].contains(job.state) { Button("Annulla", role: .destructive) { queue.cancel(job.id) } }
                if [.paused, .failed].contains(job.state) { Button("Riprendi", systemImage: "play.fill") { queue.resume(job.id) } }
                if job.state == .queued { Button("Scarica prima") { queue.prioritize(job.id) } }
                if job.state == .failed { Button("Apri log") { library.openLog(job.game) } }
                if [.completed, .cancelled, .failed].contains(job.state) { Button("Rimuovi dalla lista", systemImage: "xmark") { queue.remove(job.id) }.disabled(!queue.canRemove(job.id)) }
            }
        }.padding(featured ? 22 : 16).background(featured ? Color.mint.opacity(0.08) : Color.white.opacity(0.04)).cornerRadius(14)
    }
}
struct GameDetailsView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    let game: Game
    @State private var insights: GameInsights?
    @State private var fetching = true
    @State private var informationError: String?
    @State private var platform: InstallPlatform = .windows
    private var hasMac: Bool { insights?.macAvailable == true || game.platforms?.contains("macos") == true }
    private var hasWindows: Bool { insights?.windowsAvailable ?? (game.platforms == nil || game.platforms!.isEmpty || game.platforms!.contains("windows")) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 18) {
                    GameArtwork(game: game).frame(width: 80, height: 80)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.title).font(.title2.bold())
                        if game.isFamilyShared { Label("Libreria della famiglia", systemImage: "person.2.fill").foregroundStyle(.mint) }
                    }
                    Spacer()
                    Button("Chiudi") { dismiss() }
                }
                if fetching { ProgressView("Verifica versioni e requisiti Steam…") }
                else {
                    Text("Quale versione vuoi installare?").font(.headline)
                    Picker("Versione", selection: $platform) {
                        if hasMac { Text("Mac nativa").tag(InstallPlatform.macOS) }
                        if hasWindows { Text("Windows · Wine").tag(InstallPlatform.windows) }
                    }.pickerStyle(.segmented)
                    Text(hasMac ? "La versione Mac evita Wine. Se è compilata per Intel, può richiedere Rosetta. La versione Windows usa un container separato." : "Non risulta una versione Mac disponibile nei dati ricevuti. La versione Windows usa Wine.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let informationError { Text(informationError).font(.caption).foregroundStyle(.orange) }
                    let estimate = PerformanceEstimate(machine: library.machine, platform: platform, insights: insights)
                    GroupBox("Come potrebbe girare sul tuo Mac") {
                        VStack(alignment: .leading, spacing: 12) {
                            metric("Il tuo Mac", "\(library.machine.chip) · \(library.machine.memoryGB) GB")
                            metric("RAM minima pubblicata", estimate.minimumRAM.map { "\($0) GB" } ?? "Non disponibile")
                            metric("RAM minima + margine runtime", estimate.suggestedRAM.map { "\($0) GB" } ?? "Non disponibile")
                            Text(estimate.memoryStatus).foregroundStyle(.secondary)
                            metric("GPU minima pubblicata", insights?.requirement("Graphics", for: platform) ?? "Non disponibile")
                            if let directX = insights?.requirement("DirectX", for: platform), platform == .windows {
                                metric("DirectX richiesta", directX)
                            }
                            metric("Impostazione iniziale suggerita", estimate.startingResolution)
                            metric("FPS previsti", "Non disponibili senza benchmark del gioco")
                            Text(estimate.confidence + " Per Windows aggiungo 2 GB al minimo pubblicato come margine indicativo. La stima non modifica il gioco.").font(.caption).foregroundStyle(.secondary)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if game.isFamilyShared {
                        Text("La famiglia condivide i giochi ammessi da Steam. Una copia disponibile e l'autorizzazione al download dipendono da Steam; il supporto Steamworks dell'avvio resta da verificare.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Aggiungi ai download", systemImage: "arrow.down.circle.fill") {
                        library.installSteam(game, platform: platform); dismiss()
                    }.buttonStyle(.borderedProminent)
                        .disabled(library.downloads.storageError != nil || (!hasMac && !hasWindows) || library.downloads.jobs.contains(where: { $0.game.id == game.id && [.queued, .active, .paused].contains($0.state) }))
                }
            }.padding(28)
        }.frame(width: 600, height: 620)
        .task {
            defer { fetching = false }
            if let id = game.steamAppID {
                do { insights = try await GameInsights.fetch(appID: id) }
                catch { informationError = "Requisiti dello store non disponibili: uso le versioni indicate dal catalogo." }
            }
            platform = hasMac ? .macOS : .windows
        }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 200, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.callout)
    }
}
