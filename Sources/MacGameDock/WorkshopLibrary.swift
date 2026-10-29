import Foundation
import Combine

struct InstalledMod: Codable, Identifiable {
    let id: UUID
    let gameIdentity: String
    let itemID: String
    let title: String
    let destination: String
    var enabled: Bool
}
@MainActor
final class WorkshopLibrary: ObservableObject {
    @Published private(set) var installed: [InstalledMod] = []
    @Published private(set) var error: String?
    private let root: URL
    private var writable = true
    private var file: URL { root.appendingPathComponent("workshop-installed.json") }
    init(root: URL) {
        self.root = root
        if FileManager.default.fileExists(atPath: file.path) {
            do { installed = try JSONDecoder().decode([InstalledMod].self, from: Data(contentsOf: file)) }
            catch { writable = false; self.error = "Elenco mod non leggibile: il file originale è conservato." }
        }
    }
    func mods(for game: Game) -> [InstalledMod] { installed.filter { $0.gameIdentity == game.identity } }
    private func location(_ mod: InstalledMod) -> URL { mod.enabled ? URL(fileURLWithPath: mod.destination) : root.appendingPathComponent("Workshop/Disabled/\(mod.id.uuidString)/Content") }
    private func persist(_ candidate: [InstalledMod]) throws {
        guard writable else { throw DockError.message(error ?? "Elenco mod non disponibile.") }
        try JSONEncoder().encode(candidate).write(to: file, options: .atomic); installed = candidate
    }
    func register(game: Game, itemID: String, title: String, destination: URL) throws {
        guard writable else { throw DockError.message(error ?? "Elenco mod non disponibile.") }
        let value = InstalledMod(id: UUID(), gameIdentity: game.identity, itemID: itemID, title: title, destination: destination.path, enabled: true)
        try JSONEncoder().encode(value).write(to: destination.appendingPathComponent(".MacGameDeckMod.json"), options: .atomic)
        do { try persist(installed + [value]) }
        catch { try? FileManager.default.removeItem(at: destination.appendingPathComponent(".MacGameDeckMod.json")); throw error }
    }
    func toggle(_ mod: InstalledMod) throws {
        guard writable, let index = installed.firstIndex(where: { $0.id == mod.id }) else { throw DockError.message("Mod non presente nell’elenco.") }
        let source = location(installed[index])
        try SteamCloudRestore.rejectSymlinks(source)
        let marker = try JSONDecoder().decode(InstalledMod.self, from: Data(contentsOf: source.appendingPathComponent(".MacGameDeckMod.json")))
        guard marker.id == mod.id, marker.destination == mod.destination else { throw DockError.message("La cartella della mod non corrisponde alla ricevuta. I file sono conservati.") }
        var next = installed; next[index].enabled.toggle()
        let target = location(next[index])
        try SteamCloudRestore.rejectSymlinks(target)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw DockError.message("La cartella di destinazione esiste già. Nessun file viene sovrascritto.") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: target)
        do { try persist(next) } catch { try? FileManager.default.moveItem(at: target, to: source); throw error }
    }
    func folder(_ mod: InstalledMod) -> URL { location(mod) }
}
