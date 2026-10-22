import AppKit
import SwiftUI

struct LogsView: View {
    @EnvironmentObject var library: Library
    @State private var selected = "application"
    @State private var content = ""
    @State private var search = ""
    @State private var live = true
    @State private var feedback = ""
    private var file: URL {
        if selected == "engine" { return library.root.appendingPathComponent("Logs/engine-check.log") }
        if let game = library.data.games.first(where: { $0.id.uuidString == selected }) { return library.log(for: game) }
        return library.diagnostics.file
    }
    private var visible: String { search.isEmpty ? content : content.components(separatedBy: .newlines).filter { $0.localizedCaseInsensitiveContains(search) }.joined(separator: "\n") }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Log e diagnostica").font(.largeTitle.bold())
            Text("Avvio dei giochi, componenti Wine e sincronizzazione dei trofei. Password e token non vengono registrati.").foregroundStyle(.secondary)
            HStack {
                Picker("Log", selection: $selected) {
                    Text("Applicazione · Steam · Trofei").tag("application")
                    Text("Motore Windows · Bootstrap").tag("engine")
                    ForEach(library.data.games.filter { FileManager.default.fileExists(atPath: library.log(for: $0).path) }.sorted { $0.title < $1.title }) { game in Text(game.title + " · Wine").tag(game.id.uuidString) }
                }.frame(maxWidth: 420)
                Toggle("In tempo reale", isOn: $live).toggleStyle(.checkbox)
                Button("Aggiorna") { refresh() }
            }
            HStack {
                TextField("Filtra le righe", text: $search).textFieldStyle(.roundedBorder)
                Button("Copia") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(visible, forType: .string); feedback = "Log copiato." }
                Button("Esporta…") { export() }
                Button("Mostra cartella") { NSWorkspace.shared.open(library.root.appendingPathComponent("Logs")) }
            }
            ScrollView([.horizontal, .vertical]) {
                Text(visible.isEmpty ? "Nessuna riga corrispondente." : visible).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.opacity(0.25)).cornerRadius(12)
            Text(feedback).font(.caption).foregroundStyle(.secondary)
            Button("Prova notifica trofeo") { library.achievements.testNotification(); feedback = "Notifica di prova: nessun trofeo è stato sbloccato o inviato a Steam." }
        }
        .onChange(of: selected) { _ in refresh() }
        .task {
            refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
                if live { refresh() }
            }
        }
    }
    private func refresh() {
        if !FileManager.default.fileExists(atPath: file.path) { content = "Nessun log disponibile. I prossimi avvii e le operazioni compariranno qui."; return }
        do {
            content = try AppDiagnostics.tail(file)
            if let game = library.data.games.first(where: { $0.id.uuidString == selected }) {
                for installer in AppDiagnostics.componentLogs(for: game) {
                    content += "\n\n--- Installer: " + installer.lastPathComponent + " ---\n" + ((try? AppDiagnostics.tail(installer, limit: 65536)) ?? "Log non leggibile.")
                }
            }
        } catch { content = "Impossibile leggere il log: " + error.localizedDescription }
    }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "MacGameDeck-diagnostica.txt"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do { try Data(visible.utf8).write(to: target, options: .atomic); feedback = "Log esportato." }
        catch { feedback = "Esportazione non riuscita: " + error.localizedDescription }
    }
}
