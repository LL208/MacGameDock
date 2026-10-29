import AppKit
import Combine
import CryptoKit
import ImageIO

// Only the API receives the credential. CDN requests never carry it.
enum ArtworkKind: String, Codable, CaseIterable {
    case cover, landscape, hero, logo
    var endpoint: String { self == .hero ? "heroes" : self == .logo ? "logos" : "grids" }
    var dimensions: String? { self == .cover ? "600x900" : self == .landscape ? "460x215,920x430" : nil }
    func steamURL(_ id: Int) -> URL {
        let file = self == .cover ? "library_600x900.jpg" : self == .hero ? "library_hero.jpg" : self == .logo ? "logo.png" : "header.jpg"
        return URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/\(file)")!
    }
}
struct ArtworkAsset: Codable, Equatable {
    let url: URL
    let author: String
    let source: String
}
struct GridDBImage: Decodable {
    let id: Int
    let score: Int?
    let url: URL
    let nsfw: Bool?
    let humor: Bool?
    let author: Author?
    struct Author: Decodable { let name: String? }
}
enum ArtworkPolicy {
    static func trusted(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, let host = url.host?.lowercased() else { return false }
        return host == "cdn.steamgriddb.com" || host.hasSuffix(".steamgriddb.com")
    }
    static func best(_ images: [GridDBImage]) -> GridDBImage? {
        images.filter { trusted($0.url) && $0.nsfw != true && $0.humor != true }.sorted {
            if ($0.score ?? 0) != ($1.score ?? 0) { return ($0.score ?? 0) > ($1.score ?? 0) }
            return $0.id < $1.id
        }.first
    }
    static func normalized(_ title: String) -> String {
        title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    static func key(_ identity: String, _ kind: ArtworkKind) -> String {
        SHA256.hash(data: Data((identity + ":" + kind.rawValue).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
private final class ArtworkNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
actor ArtworkClient {
    private let session: URLSession
    private var active = 0
    init(session provided: URLSession? = nil) {
        if let provided { session = provided; return }
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 4; config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 40
        session = URLSession(configuration: config, delegate: ArtworkNoRedirect(), delegateQueue: nil)
    }
    private struct Envelope<T: Decodable>: Decodable { let success: Bool; let data: T }
    private struct SearchGame: Decodable { let id: Int; let name: String }
    private func request(_ url: URL, key: String? = nil, limit: Int) async throws -> Data {
        while active >= 4 { try await Task.sleep(nanoseconds: 80_000_000) }
        try Task.checkCancellation(); active += 1; defer { active -= 1 }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        if let key { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DockError.message("Risposta immagini non valida.") }
        if http.statusCode == 401 || http.statusCode == 403 { throw DockError.message("Chiave SteamGridDB non valida o accesso non autorizzato.") }
        if http.statusCode == 429 { throw DockError.message("Limite SteamGridDB raggiunto. Riprova più tardi.") }
        guard http.statusCode == 200, response.expectedContentLength <= Int64(limit) else { throw DockError.message("Artwork non disponibile.") }
        var data = Data()
        for try await byte in bytes { guard data.count < limit else { throw DockError.message("Immagine troppo grande.") }; data.append(byte) }
        return data
    }
    func lookup(appID: Int?, title: String, kind: ArtworkKind, key: String) async throws -> (URL, String)? {
        let base = URL(string: "https://www.steamgriddb.com/api/v2")!
        var path: String
        if let appID { path = "\(kind.endpoint)/steam/\(appID)" }
        else {
            let url = base.appendingPathComponent("search/autocomplete").appendingPathComponent(title)
            let result = try JSONDecoder().decode(Envelope<[SearchGame]>.self, from: await request(url, key: key, limit: 2_000_000))
            let exact = result.data.filter { ArtworkPolicy.normalized($0.name) == ArtworkPolicy.normalized(title) }
            guard result.success, exact.count == 1, let match = exact.first else { return nil }
            path = "\(kind.endpoint)/game/\(match.id)"
        }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "nsfw", value: "false"), URLQueryItem(name: "humor", value: "false"), URLQueryItem(name: "types", value: "static")]
        if let dimensions = kind.dimensions { components.queryItems?.append(URLQueryItem(name: "dimensions", value: dimensions)) }
        let result = try JSONDecoder().decode(Envelope<[GridDBImage]>.self, from: await request(components.url!, key: key, limit: 4_000_000))
        guard result.success, let selected = ArtworkPolicy.best(result.data) else { return nil }
        return (selected.url, selected.author?.name ?? "Autore SteamGridDB")
    }
    func download(_ url: URL) async throws -> Data {
        guard ArtworkPolicy.trusted(url) || (url.scheme == "https" && url.host == "cdn.cloudflare.steamstatic.com") else { throw DockError.message("Origine artwork non valida.") }
        let data = try await request(url, limit: 16_000_000)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 8192, h <= 8192, w * h <= 32_000_000 else { throw DockError.message("Formato immagine non supportato.") }
        return data
    }
}
@MainActor
final class ArtworkStore: ObservableObject {
    @Published private(set) var assets: [String: ArtworkAsset] = [:]
    @Published private(set) var configured = false
    @Published private(set) var revision = 0
    @Published private(set) var message = "Usa le immagini Steam. Aggiungi una chiave per attivare SteamGridDB."
    private struct Record: Codable { let asset: ArtworkAsset; let date: Date }
    private var records: [String: Record] = [:]
    private var attempts: [String: Date] = [:]
    private var pending: [String: Task<Void, Never>] = [:]
    private var key = ""
    private let directory: URL
    private let credential: URL
    private let client: ArtworkClient
    private let decoded = NSCache<NSString, NSImage>()
    init(root: URL, client: ArtworkClient = ArtworkClient()) {
        self.client = client
        directory = root.appendingPathComponent("Artwork", isDirectory: true)
        credential = root.appendingPathComponent("Credentials/steamgriddb.key")
        key = (try? String(contentsOf: credential, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        configured = !key.isEmpty
        if configured { message = "SteamGridDB attivo · immagini salvate in cache locale." }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")), let saved = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = saved.filter { $0.value.asset.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL && FileManager.default.fileExists(atPath: $0.value.asset.url.path) }
            assets = records.mapValues(\.asset)
        }
    }
    func configure(_ value: String) {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.isEmpty || (candidate.count >= 24 && candidate.count <= 128 && candidate.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { message = "La chiave SteamGridDB non ha un formato valido."; return }
        do {
            try FileManager.default.createDirectory(at: credential.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: credential.deletingLastPathComponent().path)
            if candidate.isEmpty { if FileManager.default.fileExists(atPath: credential.path) { try FileManager.default.removeItem(at: credential) } }
            else { try Data(candidate.utf8).write(to: credential, options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credential.path) }
            for task in pending.values { task.cancel() }; pending = [:]; attempts = [:]
            key = candidate; configured = !candidate.isEmpty; revision += 1
            message = configured ? "SteamGridDB configurato. Le immagini visibili vengono aggiornate automaticamente." : "SteamGridDB disattivato. Usa immagini Steam e cache locale."
        } catch { message = "Impossibile salvare la configurazione SteamGridDB." }
    }
    func refresh() { for task in pending.values { task.cancel() }; pending = [:]; attempts = [:]; records = records.mapValues { Record(asset: $0.asset, date: .distantPast) }; revision += 1; message = "Aggiornamento delle immagini visibili…" }
    func ensure(_ game: Game, kind: ArtworkKind) async {
        let id = ArtworkPolicy.key(game.identity, kind)
        if let task = pending[id] { await task.value; return }
        if let record = records[id], Date().timeIntervalSince(record.date) < 7 * 86400, (!configured || record.asset.source == "SteamGridDB") { return }
        if let last = attempts[id], Date().timeIntervalSince(last) < 900 { return }
        attempts[id] = Date(); let token = revision; let apiKey = key
        let task = Task { [weak self] in
            guard let self else { return }
            var selected: (URL, String)?
            if !apiKey.isEmpty {
                do { selected = try await client.lookup(appID: game.steamAppID, title: game.title, kind: kind, key: apiKey) }
                catch { if token == revision { message = "SteamGridDB non disponibile. Controlla la chiave e la rete; nel frattempo uso Steam o la cache." }; if assets[id] != nil { return } }
            }
            do {
                try Task.checkCancellation()
                var source = "SteamGridDB"
                if selected == nil, let appID = game.steamAppID { selected = (kind.steamURL(appID), "Valve / editore del gioco"); source = "Steam" }
                guard let selected else { return }
                let data: Data
                do { data = try await client.download(selected.0) }
                catch { if source == "SteamGridDB", let appID = game.steamAppID { data = try await client.download(kind.steamURL(appID)); source = "Steam" } else { throw error } }
                try Task.checkCancellation(); guard token == revision else { return }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(id + ".image")
                try data.write(to: file, options: .atomic)
                let asset = ArtworkAsset(url: file, author: source == "SteamGridDB" ? selected.1 : "Valve / editore del gioco", source: source)
                decoded.removeObject(forKey: id as NSString)
                assets[id] = asset; records[id] = Record(asset: asset, date: Date())
                pruneCache(keeping: id)
                try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
            } catch { /* Cached image or placeholder stays visible; game launch is never blocked. */ }
        }
        pending[id] = task; await task.value
        if token == revision { pending.removeValue(forKey: id) }
    }
    private func pruneCache(keeping newest: String) {
        var sizes: [String: Int] = [:]
        for (id, record) in records { sizes[id] = (try? record.asset.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        var total = sizes.values.reduce(0, +)
        for (id, record) in records.sorted(by: { $0.value.date < $1.value.date }) where total > 256 * 1024 * 1024 && id != newest {
            guard record.asset.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { continue }
            try? FileManager.default.removeItem(at: record.asset.url)
            total -= sizes[id] ?? 0; records.removeValue(forKey: id); assets.removeValue(forKey: id); decoded.removeObject(forKey: id as NSString)
        }
    }
    func image(_ game: Game, kind: ArtworkKind) -> NSImage? {
        let id = ArtworkPolicy.key(game.identity, kind)
        if let image = decoded.object(forKey: id as NSString) { return image }
        guard let url = assets[id]?.url, let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        decoded.countLimit = 64; decoded.totalCostLimit = 96 * 1024 * 1024
        let rep = image.representations.first
        let width = min(8192, max(1, rep?.pixelsWide ?? 1)), height = min(8192, max(1, rep?.pixelsHigh ?? 1))
        decoded.setObject(image, forKey: id as NSString, cost: width * height * 4); return image
    }
    func asset(_ game: Game, kind: ArtworkKind) -> ArtworkAsset? { assets[ArtworkPolicy.key(game.identity, kind)] }
}
