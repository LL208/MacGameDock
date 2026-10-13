import AppKit
import SwiftUI

@MainActor
final class PlayActivity: ObservableObject {
    @Published private(set) var seconds: [String: Double] = [:]
    @Published var storageError: String?
    private let file: URL
    private var active: [String: TimeInterval] = [:]
    private var timer: Timer?
    private var writable = true
    private let uptime: () -> TimeInterval
    init(root: URL, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, automaticCheckpoint: Bool = true) {
        self.uptime = uptime
        file = root.appendingPathComponent("playtime.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                seconds = try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: file))
                guard seconds.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw DockError.message("Ore di gioco non valide.") }
            }
        } catch { writable = false; storageError = "Conteggio ore non disponibile: il file originale è conservato." }
        if automaticCheckpoint { timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkpoint() } } }
    }
    func start(_ game: Game) { if active[game.identity] == nil { active[game.identity] = uptime() } }
    func stop(_ game: Game) { checkpoint(); active.removeValue(forKey: game.identity) }
    func checkpoint() {
        guard writable else { return }
        let now = uptime()
        var next = seconds
        for (key, start) in active { next[key, default: 0] += max(0, now - start) }
        do {
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            seconds = next
            for key in Array(active.keys) { active[key] = now }
        } catch { storageError = "Impossibile salvare le ore di gioco: \(error.localizedDescription)" }
    }
    func label(_ game: Game) -> String { String(format: "%.1f ore in MacGameDeck", (seconds[game.identity] ?? 0) / 3600) }
}
