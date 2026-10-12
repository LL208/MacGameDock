import AppKit
import Foundation
import Security
import CryptoKit
import CoreImage.CIFilterBuiltins
import Darwin

struct SteamSession: Codable {
    let steamID: String
    let username: String
    let account: Data
}
enum SessionVault {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.macgamedeck.steam-session", kSecAttrAccount as String: "session"] }
    static func read() throws -> SteamSession? {
        var q = query; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw DockError.message("Impossibile leggere la sessione Steam nel Portachiavi.") }
        return try JSONDecoder().decode(SteamSession.self, from: bytes)
    }
    static func save(_ session: SteamSession) throws {
        let bytes = try JSONEncoder().encode(session)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = bytes
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw DockError.message("Impossibile salvare la sessione Steam.") }; return
        }
        guard status == errSecSuccess else { throw DockError.message("Impossibile aggiornare la sessione Steam.") }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DockError.message("Impossibile rimuovere la sessione Steam.") }
    }
}
struct ManagedLaunch: Codable {
    let prefix: String
    let arguments: [String]
    let workingDirectory: String
    var platform: InstallPlatform?
}
struct DeckMetadata: Decodable {
    struct Launch: Decodable {
        let executable: String?
        let arguments: String?
        let workingDirectory: String?
        let oslist: String?
        let osarch: String?
    }
    let appID: Int
    let launches: [Launch]?
    static func contained(_ relative: String, in directory: URL) throws -> URL {
        let path = relative.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/"), !path.contains(":"), !path.split(separator: "/").contains("..") else {
            throw DockError.message("Percorso di avvio Steam non sicuro.")
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        var ancestor = directory
        for component in path.split(separator: "/") {
            ancestor.appendPathComponent(String(component))
            if (try? FileManager.default.attributesOfItem(atPath: ancestor.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw DockError.message("Il percorso di avvio contiene un collegamento simbolico.")
            }
        }
        let value = directory.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard value.path == root.path || value.path.hasPrefix(root.path + "/") else { throw DockError.message("Il file è fuori dal container.") }
        return value
    }
    func select(in directory: URL, platform: InstallPlatform = .windows) throws -> (URL, [String], URL) {
        let options = (launches ?? []).filter {
            ($0.oslist == nil || $0.oslist == "" || $0.oslist!.split(separator: ",").contains(Substring(platform.rawValue))) &&
            ($0.executable?.isEmpty == false) && (platform == .macOS || $0.executable?.lowercased().hasSuffix(".exe") == true)
        }
        for option in options {
            let exe = try Self.contained(option.executable!, in: directory)
            guard FileManager.default.fileExists(atPath: exe.path) else { continue }
            var selected = exe
            if platform == .macOS {
                let components = (option.executable ?? "").replacingOccurrences(of: "\\", with: "/").split(separator: "/")
                if let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) {
                    selected = try Self.contained(components[...index].joined(separator: "/"), in: directory)
                } else {
                    guard FileManager.default.isExecutableFile(atPath: exe.path) else { continue }
                }
            }
            let args = try WindowsArguments.parse(option.arguments ?? "")
            let working = try Self.contained(option.workingDirectory ?? "", in: directory)
            return (selected, args, working)
        }
        throw DockError.message("Download completato, ma Steam non fornisce un eseguibile Windows utilizzabile. Il gioco non è ancora pronto.")
    }
}
enum WindowsArguments {
    static func parse(_ value: String) throws -> [String] {
        var result: [String] = [], current = "", quoted = false, started = false, slashes = 0
        for char in value {
            if char == "\\" { slashes += 1; started = true; continue }
            if char == "\"" {
                current += String(repeating: "\\", count: slashes / 2)
                if slashes % 2 == 1 { current.append(char) } else { quoted.toggle() }
                slashes = 0; started = true; continue
            }
            current += String(repeating: "\\", count: slashes); slashes = 0
            if char.isWhitespace && !quoted {
                if started { result.append(current); current = ""; started = false }
            } else { current.append(char); started = true }
        }
        current += String(repeating: "\\", count: slashes)
        guard !quoted else { throw DockError.message("Argomenti di avvio Steam non validi.") }
        if started { result.append(current) }
        guard !result.contains(where: { $0.contains("%") }) else { throw DockError.message("Questo gioco richiede parametri Steam non ancora supportati.") }
        return result
    }
}
enum WineRuntime {
    static func detect() -> String? {
        let candidates = ["/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/wine",
            "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine64", "/opt/homebrew/bin/wine64"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func validate(prefix: URL) throws {
        for path in ["system.reg", "user.reg", "drive_c/windows/system32/kernel32.dll"] {
            guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent(path).path) else {
                throw DockError.message("Wine non ha inizializzato il container. I file del gioco sono conservati; installazione non ancora pronta.")
            }
        }
    }
    static func environment(prefix: URL, runtime: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix.path; env["WINEDEBUG"] = "-all"
        if let range = runtime.range(of: "/lib/wine/x86_64-unix/wine") {
            let cx = String(runtime[..<range.lowerBound])
            env["CX_ROOT"] = cx; env["WINESERVER"] = cx + "/bin/wineserver"
        }
        return env
    }
}

// Drain both streams without persisting credentials or arbitrary helper output.
private final class LineSink: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private var latest: [String: Data] = [:]
    let event: @Sendable (Data) -> Void
    init(event: @escaping @Sendable (Data) -> Void) { self.event = event }
    func finalEvents() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return ["qr", "account", "account_mismatch", "library_progress", "download_progress", "download_complete"].compactMap { latest[$0] }
    }
    func feed(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(bytes)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]; buffer.removeSubrange(...end)
            let marker = Data("MACGAMEDECK_EVENT:".utf8)
            if line.starts(with: marker) {
                let data = Data(line.dropFirst(marker.count))
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = json["type"] as? String { latest[type] = data }
                event(data)
            }
        }
        if buffer.count > 65536 { buffer.removeAll() }
    }
}
@MainActor
final class ManagedSteam: ObservableObject {
    @Published private(set) var hasSavedSession = false
    @Published private(set) var savedAccountID: String?
    @Published var busy = false
    @Published var preparing = false
    @Published var message = ""
    @Published var qr: NSImage?
    @Published var activeGame: UUID?
    private var process: Process?
    private var account: (String, String)?
    private var rejectedAccount = false
    private var cancelled = false
    private var sessionDirectory: URL?
    private var expectedAccount: String?
    @Published var progress: Double = 0
    @Published var downloadedBytes: Double = 0
    @Published var totalBytes: Double = 0
    @Published var bytesPerSecond: Double = 0
    private var lastProgress: (Date, Double)?
    let root: URL
    private let helperProvider: (() throws -> URL)?
    init(root: URL, helperProvider: (() throws -> URL)? = nil) {
        self.root = root
        self.helperProvider = helperProvider
        let saved = try? SessionStore.read(root: root)
        self.hasSavedSession = saved != nil
        self.savedAccountID = saved?.steamID
        let sessions = root.appendingPathComponent("Sessions")
        if let entries = try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.creationDateKey]) {
            for entry in entries {
                if let date = try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate, Date().timeIntervalSince(date) > 86_400 {
                    try? FileManager.default.removeItem(at: entry)
                }
            }
        }
    }
    func refreshSessionStatus() {
        let saved = try? SessionStore.read(root: root)
        hasSavedSession = saved != nil; savedAccountID = saved?.steamID
    }
    private func preserveSession() throws {
        guard let account, let directory = sessionDirectory else { throw DockError.message("Sessione Steam non confermata.") }
        let config = directory.appendingPathComponent("account.config")
        guard let bytes = try? Data(contentsOf: config), !bytes.isEmpty else {
            throw DockError.message("Steam ha confermato l'accesso, ma il motore non ha salvato la sessione. Il login per i download non è completo.")
        }
        try SessionStore.save(SteamSession(steamID: account.0, username: account.1, account: bytes), root: root)
        hasSavedSession = true
        savedAccountID = account.0
    }
    func cancel() {
        cancelled = true; qr = nil
        guard let current = process, current.isRunning else { return }
        current.terminate()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if current.isRunning { kill(current.processIdentifier, SIGKILL) }
        }
    }
    private func event(_ bytes: Data) {
        guard let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], let type = value["type"] as? String else { return }
        switch type {
        case "qr":
            guard let text = value["url"] as? String, let url = URL(string: text), url.scheme == "https", url.host == "s.team" else { return }
            let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8)
            if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
               let cg = CIContext().createCGImage(output, from: output.extent) {
                qr = NSImage(cgImage: cg, size: NSSize(width: 256, height: 256))
            }
            message = "Scansiona il QR con Steam Guard e conferma l'accesso a MacGameDeck."
        case "account":
            if let id = value["steamID"] as? String, let name = value["username"] as? String {
                guard expectedAccount == nil || expectedAccount == id else { rejectedAccount = true; cancel(); return }
                account = (id, name); qr = nil; message = "Account verificato. Elaborazione…"
                do { try preserveSession() }
                catch { message = error.localizedDescription; cancel() }

            }
        case "account_mismatch": rejectedAccount = true
        case "library_progress": message = "Caricamento catalogo: \(value["done"] ?? 0) / \(value["total"] ?? 0)"
        case "download_progress":
            if let done = value["done"] as? NSNumber, let total = value["total"] as? NSNumber, total.doubleValue > 0 {
                let now = Date()
                if let (date, previous) = lastProgress, now.timeIntervalSince(date) > 0.2, done.doubleValue >= previous {
                    bytesPerSecond = (done.doubleValue - previous) / now.timeIntervalSince(date)
                }
                if lastProgress == nil || now.timeIntervalSince(lastProgress!.0) > 0.2 { lastProgress = (now, done.doubleValue) }
                downloadedBytes = done.doubleValue; totalBytes = total.doubleValue
                progress = min(1, downloadedBytes / totalBytes)
                message = String(format: "Download verificato: %.1f%% · %.0f / %.0f MB", min(100, done.doubleValue / total.doubleValue * 100), done.doubleValue / 1_048_576, total.doubleValue / 1_048_576)
            }
        case "download_complete":
            progress = 1; bytesPerSecond = 0
            message = "Download verificato. Preparazione del container…"
        default: break
        }
    }
    private func helper() throws -> URL {
        if let helperProvider { return try helperProvider() }
        let resources = try SteamResources.current()
        let source = resources.appendingPathComponent("SteamRuntime")
        let manifest = resources.appendingPathComponent("helper-files.json")
        guard FileManager.default.fileExists(atPath: source.path), FileManager.default.fileExists(atPath: manifest.path) else {
            throw DockError.message("Motore Steam mancante: ricompila il progetto con le risorse incluse.")
        }
        let hashes = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
        let target = root.appendingPathComponent("Tools/SteamRuntime")
        for (relative, expected) in hashes {
            let file = try DeckMetadata.contained(relative, in: source)
            let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw DockError.message("Il motore Steam non supera il controllo di integrità.") }
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: source, to: target)
        let executable = target.appendingPathComponent("DepotDownloader")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
    func run(_ args: [String], expected: String?, forceQR: Bool = false) async throws -> String {
        guard !busy else { throw DockError.message("Attendi il completamento dell'operazione Steam in corso.") }
        try Task.checkCancellation()
        busy = true; cancelled = false; rejectedAccount = false; account = nil; qr = nil
        expectedAccount = expected; progress = 0; lastProgress = nil; bytesPerSecond = 0; downloadedBytes = 0; totalBytes = 0
        defer { busy = false; process = nil; qr = nil; sessionDirectory = nil }
        let executable = try helper()
        let session = forceQR ? nil : try SessionStore.read(root: root)
        if let expected, let session, expected != session.steamID { throw DockError.message("La sessione Steam appartiene a un altro account. Ricollega Steam.") }
        let directory = root.appendingPathComponent("Sessions/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        sessionDirectory = directory
        defer { try? FileManager.default.removeItem(at: directory) }
        if let session { try session.account.write(to: directory.appendingPathComponent("account.config"), options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("account.config").path) }
        let p = Process(); p.executableURL = executable; p.currentDirectoryURL = directory
        p.arguments = args + ["-remember-password", "-loginid", "1296516164"] + (session.map { ["-username", $0.username] } ?? ["-qr"])
        var env = ProcessInfo.processInfo.environment; env["MACGAMEDECK_PROTOCOL"] = "1"; env["MACGAMEDECK_EXPECTED_STEAMID"] = expected
        env["DOTNET_ROOT"] = executable.deletingLastPathComponent().path
        env["DOTNET_ROLL_FORWARD"] = "LatestPatch"
        p.environment = env; p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
        let sink = LineSink { [weak self] bytes in Task { @MainActor in self?.event(bytes) } }
        out.fileHandleForReading.readabilityHandler = { handle in sink.feed(handle.availableData) }
        err.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        defer { out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil }
        process = p
        message = session == nil ? "Richiesta QR a Steam…" : "Accesso con la sessione salvata…"
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            p.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do { try p.run() } catch { p.terminationHandler = nil; continuation.resume(throwing: error) }
        }
        // Allow the last protocol events queued by the pipe reader to reach the main actor.
        try? await Task.sleep(nanoseconds: 50_000_000)
        for bytes in sink.finalEvents() { event(bytes) }
        if rejectedAccount { throw DockError.message("Hai autenticato un account diverso da quello collegato.") }
        guard let account else { throw DockError.message("Steam non ha completato l'accesso. Ricollega l'account tramite QR se la sessione è scaduta.") }
        try preserveSession()
        if cancelled || Task.isCancelled { throw CancellationError() }
        guard status == 0 else { throw DockError.message("Steam non ha completato l'operazione. I file parziali sono conservati per riprendere il download. Verifica rete, spazio disponibile e licenza del gioco.") }
        return account.0
    }
    func catalog(expected: String?, forceQR: Bool = false) async throws -> (String, [SteamOwnedGame]) {
        let file = root.appendingPathComponent("catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let id = try await run(["-deck-library", file.path], expected: expected, forceQR: forceQR)
        struct Catalog: Decodable { let steamID: String; let games: [SteamOwnedGame] }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: file))
        guard id == catalog.steamID else { throw DockError.message("Catalogo Steam non associato alla sessione.") }
        return (id, catalog.games)
    }
    func install(_ game: Game, platform: InstallPlatform = .windows, runtime: String?, expected: String?) async throws -> (String, String, ManagedLaunch) {
        guard let id = game.steamAppID else { throw DockError.message("Identificativo Steam mancante.") }
        let prefix = root.appendingPathComponent("Containers/Steam/\(id)/prefix")
        let directory = platform == .windows ? prefix.appendingPathComponent("drive_c/Program Files/MacGameDeck/Games/\(id)") : root.appendingPathComponent("Containers/Steam/\(id)/macOS")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        activeGame = game.id
        defer { activeGame = nil; preparing = false }
        let architecture = platform == .macOS ? ["-osarch", "64"] : ["-all-archs"]
        _ = try await run(["-app", String(id), "-os", platform.rawValue, "-dir", directory.path, "-validate"] + architecture, expected: expected)
        preparing = true
        let metadata = try JSONDecoder().decode(DeckMetadata.self, from: Data(contentsOf: directory.appendingPathComponent(".MacGameDeck/metadata.json")))
        guard metadata.appID == id else { throw DockError.message("Metadati Steam non validi.") }
        let (exe, arguments, working) = try metadata.select(in: directory, platform: platform)
        if platform == .macOS {
            message = "Versione Mac installata."
            return (exe.path, directory.path, ManagedLaunch(prefix: "", arguments: arguments, workingDirectory: working.path, platform: .macOS))
        }
        guard let runtime else { throw DockError.message("Runtime Wine non disponibile.") }
        message = "Inizializzazione ambiente Windows…"
        let dependencies = try SteamDependencies.plan(in: directory)
        try await prepare(prefix: prefix, runtime: runtime, arguments: ["wineboot", "-u"])
        try WineRuntime.validate(prefix: prefix)
        for step in dependencies {
            message = "Installazione dipendenza: \(step.executable.lastPathComponent)…"
            let executable = "Z:" + step.executable.path.replacingOccurrences(of: "/", with: "\\")
            let args = step.executable.pathExtension.lowercased() == "msi" ? ["msiexec", "/i", executable] + step.arguments : [executable] + step.arguments
            try await prepare(prefix: prefix, runtime: runtime, arguments: args)
            try FileManager.default.createDirectory(at: step.marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: step.marker, options: [.atomic])
        }
        message = "Installato nel container. Pronto per la prova di avvio."
        return (exe.path, directory.path, ManagedLaunch(prefix: prefix.path, arguments: arguments, workingDirectory: working.path, platform: .windows))
    }
    private func prepare(prefix: URL, runtime: String, arguments: [String]) async throws {
        try Task.checkCancellation()
        busy = true
        defer { busy = false; process = nil }
        let p = Process(); p.executableURL = URL(fileURLWithPath: runtime)
        p.arguments = arguments; p.environment = WineRuntime.environment(prefix: prefix, runtime: runtime)
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        process = p
        let status: Int32 = try await withCheckedThrowingContinuation { c in
            p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { p.terminationHandler = nil; c.resume(throwing: error) }
        }
        process = nil
        if cancelled || Task.isCancelled { throw CancellationError() }
        guard [0, 194, 105].contains(status) else { throw DockError.message("Il download è completo, ma la preparazione Wine non è riuscita (\(status)).") }
    }
}
