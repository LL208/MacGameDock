import Foundation

enum InstallPlatform: String, Codable, CaseIterable, Identifiable {
    case macOS = "macos", windows = "windows"
    var id: String { rawValue }
    var label: String { self == .macOS ? "Mac nativa" : "Windows · Wine" }
}
enum DownloadState: String, Codable {
    case queued, active, paused, completed, failed, cancelled
    var label: String {
        switch self {
        case .queued: return "In coda"
        case .active: return "Download e preparazione"
        case .paused: return "In pausa"
        case .completed: return "Completato"
        case .failed: return "Da riprovare"
        case .cancelled: return "Annullato"
        }
    }
}
struct DownloadJob: Identifiable, Codable {
    let id: UUID
    let game: Game
    let platform: InstallPlatform
    let accountID: String?
    var state: DownloadState
    var error: String?
    let createdAt: Date
    var finishedAt: Date? = nil
}
@MainActor
final class DownloadQueue: ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []
    @Published var storageError: String?
    private var worker: Task<Void, Never>?
    @Published private var activeID: UUID?
    private let file: URL
    private let runner: (DownloadJob) async throws -> Void
    private let interrupt: () -> Void
    init(root: URL, runner: @escaping (DownloadJob) async throws -> Void, interrupt: @escaping () -> Void) {
        file = root.appendingPathComponent("downloads.json")
        self.runner = runner; self.interrupt = interrupt
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                jobs = try JSONDecoder().decode([DownloadJob].self, from: Data(contentsOf: file))
                // A restarted application must never claim a still-running download.
                for i in jobs.indices where jobs[i].state == .active || jobs[i].state == .queued { jobs[i].state = .paused }
            } catch { storageError = "Impossibile leggere la coda. Il file originale è conservato." }
        }
    }
    private func persist() {
        guard storageError == nil else { return }
        do { try JSONEncoder().encode(jobs).write(to: file, options: [.atomic]) }
        catch { storageError = "Impossibile salvare la coda dei download." }
    }
    func enqueue(_ game: Game, platform: InstallPlatform, accountID: String?) {
        guard storageError == nil else { return }
        guard !jobs.contains(where: { $0.game.id == game.id && [.queued, .active, .paused].contains($0.state) }) else { return }
        jobs.append(DownloadJob(id: UUID(), game: game, platform: platform, accountID: accountID, state: .queued, createdAt: Date()))
        persist(); start()
    }
    func pause(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), [.queued, .active].contains(jobs[i].state) else { return }
        jobs[i].state = .paused; persist()
        if activeID == id { worker?.cancel(); interrupt() }
    }
    func resume(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), [.paused, .failed, .cancelled].contains(jobs[i].state) else { return }
        jobs[i].state = .queued; jobs[i].error = nil; jobs[i].finishedAt = nil; persist(); start()
    }
    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state != .completed else { return }
        jobs[i].state = .cancelled; jobs[i].finishedAt = Date(); jobs[i].error = nil; persist()
        if activeID == id { worker?.cancel(); interrupt() }
    }
    var pending: [DownloadJob] { jobs.filter { ![.completed, .cancelled].contains($0.state) } }
    var history: [DownloadJob] { jobs.filter { [.completed, .cancelled].contains($0.state) }.sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) } }
    func canRemove(_ id: UUID) -> Bool { activeID != id && jobs.contains { $0.id == id && [.completed, .cancelled, .failed, .paused].contains($0.state) } }
    func remove(_ id: UUID) {
        guard canRemove(id) else { return }
        jobs.removeAll { $0.id == id }; persist()
    }
    func clearHistory() {
        jobs.removeAll { [.completed, .cancelled].contains($0.state) && $0.id != activeID }; persist()
    }
    func prioritize(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .queued else { return }
        let job = jobs.remove(at: i); jobs.insert(job, at: 0); persist()
    }
    func pauseAll() {
        let ids = jobs.filter { [.active, .queued].contains($0.state) }.map(\.id)
        for id in ids { pause(id) }
    }
    func resumeAll() {
        for i in jobs.indices where jobs[i].state == .paused { jobs[i].state = .queued; jobs[i].error = nil }
        persist(); start()
    }
    func start() {
        guard worker == nil else { return }
        worker = Task {
            while let index = jobs.firstIndex(where: { $0.state == .queued }) {
                let job = jobs[index]; activeID = job.id
                jobs[index].state = .active; persist()
                do {
                    try await runner(job)
                    if let i = jobs.firstIndex(where: { $0.id == job.id }), jobs[i].state == .active { jobs[i].state = .completed; jobs[i].finishedAt = Date() }
                } catch {
                    if let i = jobs.firstIndex(where: { $0.id == job.id }), jobs[i].state == .active {
                        jobs[i].state = error is CancellationError ? .paused : .failed
                        jobs[i].error = error is CancellationError ? nil : error.localizedDescription
                    }
                }
                persist(); activeID = nil
                // A paused worker's cancellation must not cancel the next job.
                if Task.isCancelled { break }
            }
            worker = nil
            if jobs.contains(where: { $0.state == .queued }) { start() }
        }
    }
}
