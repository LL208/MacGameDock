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
                    guard !["exe", "dll", "bat", "cmd"].contains(exe.pathExtension.lowercased()), FileManager.default.isExecutableFile(atPath: exe.path) else { continue }
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
    static func parse(_ value: String, allowPlaceholders: Bool = false) throws -> [String] {
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
        guard allowPlaceholders || !result.contains(where: { $0.contains("%") }) else { throw DockError.message("Questo gioco richiede parametri Steam non ancora supportati.") }
        return result
    }
}
enum WineRuntime {
    static func detect() -> String? {
        nil // The application provisions its own engine; external apps are never required.
    }
    static let requiredFiles = ["system.reg", "user.reg", "drive_c/windows/system32/kernel32.dll"]
    static func missingFiles(prefix: URL) -> [String] {
        requiredFiles.filter { !FileManager.default.fileExists(atPath: prefix.appendingPathComponent($0).path) }
    }
    static func validate(prefix: URL) throws {
        let missing = missingFiles(prefix: prefix)
        guard missing.isEmpty else {
            throw DockError.message("Container Wine incompleto: mancano \(missing.joined(separator: ", ")). I file del gioco sono conservati.")
        }
    }
    static func waitUntilReady(prefix: URL, timeout: TimeInterval = 60, pollInterval: UInt64 = 200_000_000) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            try Task.checkCancellation()
            let missing = missingFiles(prefix: prefix)
            if missing.isEmpty { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw DockError.message("Wine non ha completato l'inizializzazione entro \(Int(timeout)) secondi: mancano \(missing.joined(separator: ", ")). I file del gioco sono conservati. Consulta il log di preparazione.")
            }
            try await Task.sleep(nanoseconds: pollInterval)
        }
    }
    static func environment(prefix: URL, runtime: String, directX12: Bool = false, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["WINEPREFIX"] = prefix.path; env["WINEDEBUG"] = "-all,err+all"
        if let range = runtime.range(of: "/lib/wine/x86_64-unix/wine") {
            let cx = String(runtime[..<range.lowerBound])
            env["CX_ROOT"] = cx; env["WINESERVER"] = cx + "/bin/wineserver"
            if env["ROSETTA_ADVERTISE_AVX"] == nil { env["ROSETTA_ADVERTISE_AVX"] = "1" }
            if env["ROSETTA_ADVERTISE_AVX"] == "0" || env["ROSETTA_ADVERTISE_AVX"] == "" { env.removeValue(forKey: "ROSETTA_ADVERTISE_AVX") }
            env["DOTNET_EnableWriteXorExecute"] = "0"
            let loader = cx + "/bin/wineloader"
            if FileManager.default.isExecutableFile(atPath: loader) { env["WINELOADER"] = loader; env["CX_WINELOADER"] = loader }
            let gptk = cx + "/lib64/apple_gptk"
            let shared = gptk + "/external/libd3dshared.dylib"
            if FileManager.default.fileExists(atPath: shared) { env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = shared }
            var paths = [cx + "/lib/wine/x86_64-windows", cx + "/lib/wine/i386-windows", cx + "/lib/wine"]
            if directX12, ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14,
               FileManager.default.fileExists(atPath: gptk + "/wine/x86_64-windows/d3d12.dll"),
               FileManager.default.fileExists(atPath: shared) {
                paths.insert(contentsOf: [gptk + "/wine/x86_64-windows", gptk + "/wine"], at: 0)
                env["WINEDLLOVERRIDES"] = [env["WINEDLLOVERRIDES"], "d3d11,d3d12,dxgi=b"].compactMap { $0 }.joined(separator: ";")
                env["DYLD_FALLBACK_LIBRARY_PATH"] = [gptk + "/external", env["DYLD_FALLBACK_LIBRARY_PATH"]].compactMap { $0 }.joined(separator: ":")
            }
            env["WINEDLLPATH"] = (paths + [env["WINEDLLPATH"]].compactMap { $0 }).joined(separator: ":")
        }
        return env
    }
}

// Bounded diagnostics for Wine only; Steam authentication output remains discarded.
final class WineOutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ value: Data) {
        lock.lock(); defer { lock.unlock() }
        bytes.append(value)
        if bytes.count > 65536 { bytes.removeFirst(bytes.count - 65536) }
    }
    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return bytes
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
        return ["qr", "account", "account_mismatch", "library_progress", "download_progress", "download_complete", "cloud_error"].compactMap { latest[$0] }
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
    private var sessionPersistenceFailure: String?
    private var cloudFailure: String?
    private var cloudErrorCode: String?
    private var cloudErrorType: String?
    private var sessionDirectory: URL?
    private var expectedAccount: String?
    @Published var progress: Double = 0
    @Published var downloadedBytes: Double = 0
    @Published var totalBytes: Double = 0
    @Published var bytesPerSecond: Double = 0
    var bandwidthLimitKBPS: Int?
    private var lastProgress: (Date, Double)?
    let root: URL
    private let helperProvider: (() throws -> URL)?
    private lazy var diagnostics = AppDiagnostics(root: root)
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
    private(set) var activeOperationID: UUID?
    func cancel(operationID: UUID) { if activeOperationID == operationID { cancel() } }
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
                catch { sessionPersistenceFailure = error.localizedDescription; message = error.localizedDescription; cancel() }

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
        case "cloud_error":
            cloudErrorCode = value["code"] as? String
            cloudErrorType = value["errorType"] as? String
            if let frames = value["frames"] as? [String] {
                let safe = frames.prefix(8).filter { $0.count < 180 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._+<>".contains($0)) } }
                diagnostics.write("Cloud", "Diagnosi motore: " + safe.joined(separator: " → "))
            }
            cloudFailure = SteamCloudDiagnostic.message(code: value["code"] as? String ?? "engine_error", errorType: value["errorType"] as? String)
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
        let manifestBytes = try Data(contentsOf: manifest)
        let hashes = try JSONDecoder().decode([String: String].self, from: manifestBytes)
        let version = SHA256.hash(data: manifestBytes).map { String(format: "%02x", $0) }.joined()
        let target = root.appendingPathComponent("Tools/SteamRuntime-" + String(version.prefix(16)))
        for (relative, expected) in hashes {
            let file = try DeckMetadata.contained(relative, in: source)
            let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw DockError.message("Il motore Steam non supera il controllo di integrità.") }
        }
        let executable = target.appendingPathComponent("DepotDownloader")
        let valid = hashes.allSatisfy { relative, expected in
            guard let file = try? DeckMetadata.contained(relative, in: target), let bytes = try? Data(contentsOf: file) else { return false }
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == expected
        }
        if valid, FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = root.appendingPathComponent("Tools/.SteamRuntime-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.appendingPathComponent("DepotDownloader").path)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("Tools/SteamRuntime-backup-" + UUID().uuidString))
        }
        try FileManager.default.moveItem(at: staging, to: target)
        return executable
    }
    func run(_ args: [String], expected: String?, forceQR: Bool = false, loginID: UInt32 = 1296516164, operationID: UUID = UUID()) async throws -> String {
        guard !busy else { throw DockError.message("Attendi il completamento dell'operazione Steam in corso.") }
        try Task.checkCancellation()
        activeOperationID = operationID
        busy = true; cancelled = false; sessionPersistenceFailure = nil; cloudFailure = nil; cloudErrorCode = nil; cloudErrorType = nil; rejectedAccount = false; account = nil; qr = nil
        expectedAccount = expected; progress = 0; lastProgress = nil; bytesPerSecond = 0; downloadedBytes = 0; totalBytes = 0
        defer { activeOperationID = nil; busy = false; process = nil; qr = nil; sessionDirectory = nil }
        let executable = try helper()
        let session = forceQR ? nil : try SessionStore.read(root: root)
        if let expected, let session, expected != session.steamID { throw DockError.message("La sessione Steam appartiene a un altro account. Ricollega Steam.") }
        let directory = root.appendingPathComponent("Sessions/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        sessionDirectory = directory
        defer { try? FileManager.default.removeItem(at: directory) }
        if let session { try session.account.write(to: directory.appendingPathComponent("account.config"), options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("account.config").path) }
        let p = Process(); p.executableURL = executable; p.currentDirectoryURL = directory
        p.arguments = args + ["-remember-password", "-loginid", String(loginID)] + (session.map { ["-username", $0.username] } ?? ["-qr"])
        var env = ProcessInfo.processInfo.environment; env["MACGAMEDECK_PROTOCOL"] = "1"; env["MACGAMEDECK_EXPECTED_STEAMID"] = expected
        env["MACGAMEDECK_LANGUAGE"] = AppLanguage.shared.steamLanguage
        env["MACGAMEDECK_MACHINE_ID"] = try machineIdentity()
        env["DOTNET_ROOT"] = executable.deletingLastPathComponent().path
        env["DOTNET_ROLL_FORWARD"] = "LatestPatch"
        env["MACGAMEDECK_BANDWIDTH_KBPS"] = bandwidthLimitKBPS.map(String.init)
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
        if let sessionPersistenceFailure { throw DockError.message(sessionPersistenceFailure) }
        if cancelled || Task.isCancelled { throw CancellationError() }
        if p.terminationReason == .uncaughtSignal {
            throw DockError.message("Il motore Steam è terminato con segnale \(status). La richiesta non è stata completata; questo errore non conferma che la sessione sia scaduta.")
        }
        guard let account else { throw DockError.message("Steam non ha completato l'accesso. Ricollega l'account tramite QR se la sessione è scaduta.") }
        try preserveSession()
        if cancelled || Task.isCancelled { throw CancellationError() }
        if let cloudFailure { throw DockError.message(cloudFailure) }
        if status != 0, args.contains("-deck-cloud-inventory") { throw DockError.message("La verifica Steam Cloud non è stata completata (codice \(status)). Nessun salvataggio modificato.") }
        guard status == 0 else { throw DockError.message("Steam non ha completato l'operazione. I file parziali sono conservati per riprendere il download. Verifica rete, spazio disponibile e licenza del gioco.") }
        return account.0
    }
    private func machineIdentity() throws -> String {
        let file = root.appendingPathComponent("Account/steam-machine-id")
        if let bytes = try? Data(contentsOf: file), bytes.count <= 100,
           let text = String(data: bytes, encoding: .utf8), let id = UUID(uuidString: text) { return id.uuidString }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString
        try Data(id.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return id
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
    func cloudInventory(_ game: Game, expected: String) async throws -> SteamCloudInventory {
        guard !busy, !preparing else { throw DockError.message("Attendi la preparazione o l’operazione Steam in corso.") }
        guard let id = game.steamAppID else { throw DockError.message("Identificativo Steam mancante.") }
        guard let saved = try SessionStore.read(root: root), saved.steamID == expected else {
            throw DockError.message("Per verificare Steam Cloud serve la sessione Steam salvata dell'account collegato.")
        }
        let file = root.appendingPathComponent("cloud-inventory-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        activeGame = game.id
        defer { activeGame = nil }
        for attempt in 0..<2 {
            do {
                _ = try await run(["-app", String(id), "-deck-cloud-inventory", file.path], expected: expected)
                break
            } catch {
                let transient = ["steam_NoConnection", "steam_Timeout", "steam_ServiceUnavailable"].contains(cloudErrorCode ?? "") || (cloudErrorCode == "engine_error" && cloudErrorType == "NullReferenceException")
                guard attempt == 0, transient, !Task.isCancelled else { throw error }
                diagnostics.write("Cloud", "Lettura interrotta; nuovo accesso automatico prima di confrontare i salvataggi.", game: game)
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        let bytes = try Data(contentsOf: file)
        guard bytes.count <= 8_000_000 else { throw DockError.message("Inventario cloud troppo grande.") }
        let inventory = try JSONDecoder().decode(SteamCloudInventory.self, from: bytes)
        try inventory.validate(expectedAccount: expected, expectedAppID: id)
        message = "Inventario Steam Cloud letto: \(inventory.files.count) file. Nessun salvataggio modificato."
        return inventory
    }
    func playerSnapshot(_ game: Game, expected: String) async throws -> SteamPlayerSnapshot {
        guard let id = game.steamAppID else { throw DockError.message("Identificativo Steam mancante.") }
        let file = root.appendingPathComponent("player-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await run(["-app", String(id), "-deck-player", file.path], expected: expected)
        let snapshot = try JSONDecoder().decode(SteamPlayerSnapshot.self, from: Data(contentsOf: file))
        guard snapshot.steamID == expected, snapshot.appID == id, (snapshot.minutes ?? 0) >= 0 else { throw DockError.message("Dati Steam appartenenti a un altro account o non validi.") }
        return snapshot
    }
    func achievements(_ game: Game, expected: String, operationID: UUID = UUID()) async throws -> SteamAchievementSnapshot {
        guard let id = game.steamAppID else { throw DockError.message("Identificativo Steam mancante.") }
        let file = root.appendingPathComponent("achievements-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await run(["-app", String(id), "-deck-achievements", file.path], expected: expected, operationID: operationID)
        let value = try JSONDecoder().decode(SteamAchievementSnapshot.self, from: Data(contentsOf: file))
        try value.validate(owner: expected, appID: id)
        return value
    }
    func workshop(_ game: Game, expected: String, search: String = "", page: Int = 1) async throws -> SteamWorkshopPage {
        guard let id = game.steamAppID else { throw DockError.message("Identificativo Steam mancante.") }
        let file = root.appendingPathComponent("workshop-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await run(["-app", String(id), "-deck-workshop", file.path, "-deck-search", String(search.prefix(200)), "-deck-page", String(max(1, page))], expected: expected)
        let value = try JSONDecoder().decode(SteamWorkshopPage.self, from: Data(contentsOf: file))
        guard value.steamID == expected, value.appID == id, value.items.count <= 24 else { throw DockError.message("Risultati Workshop non validi.") }
        return value
    }
    func restoreCloudBeforeLaunch(_ game: Game, expected: String) async throws -> Int {
        let inventory = try await cloudInventory(game, expected: expected)
        var mapped = 0
        for file in inventory.liveFiles {
            let prefix = inventory.prefixes.isEmpty ? "" : inventory.prefixes[file.prefixIndex]
            let name = prefix + (prefix.isEmpty || prefix.hasSuffix("/") || prefix.hasSuffix("%") ? "" : "/") + file.name
            do { _ = try SteamCloudRestore.destination(name, game: game, inventory: inventory); mapped += 1 }
            catch SteamCloudMappingError.outsideDeclaredPatterns { continue }
        }
        guard inventory.liveFiles.isEmpty || mapped > 0 else { throw DockError.message("I file cloud di questo gioco usano Steam API senza un percorso Auto-Cloud dichiarato: ripristino automatico non ancora supportato.") }
        let entries = try SteamCloudRestore.plan(inventory, game: game)
        guard !entries.isEmpty else { try captureCloudSession(inventory, game: game); message = "Salvataggi locali aggiornati: avvio del gioco…"; return 0 }
        let staging = root.appendingPathComponent("Cloud/Staging/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let request = staging.appendingPathComponent("request.json")
        try JSONEncoder().encode(entries).write(to: request, options: .atomic)
        message = "Download di \(entries.count) salvataggi Steam Cloud…"
        _ = try await run(["-app", String(inventory.appID), "-deck-cloud-download", request.path, "-deck-cloud-directory", staging.path], expected: expected)
        try Task.checkCancellation()
        let backups = root.appendingPathComponent("Cloud/Backups/\(expected)/\(inventory.appID)/\(UUID().uuidString)")
        try SteamCloudRestore.apply(entries, staging: staging, backups: backups)
        message = "\(entries.count) salvataggi cloud ripristinati. Copie locali precedenti conservate." + (mapped < inventory.liveFiles.count ? " I file Steam API senza percorso dichiarato non sono stati ripristinati." : "")
        try captureCloudSession(inventory, game: game)
        return entries.count
    }
    func externalLaunch(_ game: Game, expected: String) async throws -> (String, ManagedLaunch) {
        guard let appID = game.steamAppID, let directory = game.installDirectory else { throw DockError.message("Installazione Steam non disponibile.") }
        let stage = root.appendingPathComponent("Metadata/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        _ = try await run(["-app", String(appID), "-deck-launch-metadata", stage.path], expected: expected)
        let metadata = try JSONDecoder().decode(DeckMetadata.self, from: Data(contentsOf: stage.appendingPathComponent(".MacGameDeck/metadata.json")))
        guard metadata.appID == appID else { throw DockError.message("Metadati di avvio non validi.") }
        let location = URL(fileURLWithPath: directory)
        if let result = try? metadata.select(in: location, platform: .macOS) {
            return (result.0.path, ManagedLaunch(prefix: "", arguments: result.1, workingDirectory: result.2.path, platform: .macOS))
        }
        let result = try metadata.select(in: location, platform: .windows)
        return (result.0.path, ManagedLaunch(prefix: root.appendingPathComponent("Containers/Steam/\(appID)/prefix").path, arguments: result.1, workingDirectory: result.2.path, platform: .windows))
    }
    func install(_ game: Game, platform: InstallPlatform = .windows, runtime: String?, expected: String?, storageRoot: String? = nil) async throws -> (String, String, ManagedLaunch) {
        guard let id = game.steamAppID else { throw DockError.message("Identificativo Steam mancante.") }
        let container: URL
        if let existing = game.storageContainer {
            container = URL(fileURLWithPath: existing)
            guard FileManager.default.fileExists(atPath: container.deletingLastPathComponent().path) else { throw DockError.message("Il disco del gioco non è disponibile. Collegalo prima di continuare.") }
        } else { container = try GameStorage.container(appID: id, root: root, selected: storageRoot) }
        let prefix = container.appendingPathComponent("prefix")
        let directory = platform == .windows ? prefix.appendingPathComponent("drive_c/Program Files/MacGameDeck/Games/\(id)") : container.appendingPathComponent("macOS")
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
        try await prepareWindows(directory: directory, prefix: prefix, runtime: runtime, expected: expected)
        message = "Installato nel container. Pronto per la prova di avvio."
        return (exe.path, directory.path, ManagedLaunch(prefix: prefix.path, arguments: arguments, workingDirectory: working.path, platform: .windows))
    }
    func prepareInstalledGame(_ game: Game, runtime: String, expected: String?) async throws {
        guard !game.isNative else { return }
        let directory = game.installDirectory.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: game.executablePath).deletingLastPathComponent()
        let prefix = game.managedLaunch.map { URL(fileURLWithPath: $0.prefix) } ?? root.appendingPathComponent("Prefixes/" + game.id.uuidString)
        activeGame = game.id; preparing = true; cancelled = false
        defer { activeGame = nil; preparing = false }
        try await prepareWindows(directory: directory, prefix: prefix, runtime: runtime, expected: expected)
    }
    private func prepareWindows(directory: URL, prefix: URL, runtime: String, expected: String?) async throws {
        message = "Inizializzazione ambiente Windows…"
        var dependencies = try SteamDependencies.plan(in: directory, allowMissing: true, prefix: prefix)
        let groups = try SteamDependencies.missingGroups(dependencies.filter { !$0.isModernVisualCPP })
        if !groups.isEmpty {
            message = "Recupero automatico dei componenti richiesti da Steam…"
            let cache = root.appendingPathComponent("Tools/CommonRedist")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let list = root.appendingPathComponent("redist-files-\(UUID().uuidString).txt")
            try Data(SteamDependencies.fileList(groups: groups).utf8).write(to: list, options: .atomic)
            defer { try? FileManager.default.removeItem(at: list) }
            preparing = false
            _ = try await run(["-app", "228980", "-os", "windows", "-all-archs", "-dir", cache.path, "-filelist", list.path, "-validate"], expected: expected)
            preparing = true
            try Task.checkCancellation()
            try SteamDependencies.copyGroups(groups, from: cache, to: directory)
            dependencies = try SteamDependencies.plan(in: directory, allowMissing: true, prefix: prefix)
        }
        let runtimeReceipt = prefix.appendingPathComponent(".MacGameDeck/runtime-path.txt")
        let ownedRuntime = OwnedRuntime(root: root).installed?.path == runtime
        let changedRuntime = ownedRuntime && (try? String(contentsOf: runtimeReceipt, encoding: .utf8)) != runtime
        if changedRuntime {
            let backup = prefix.appendingPathComponent(".MacGameDeck/runtime-backups/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for name in ["system.reg", "user.reg", "userdef.reg"] {
                let file = prefix.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.copyItem(at: file, to: backup.appendingPathComponent(name)) }
            }
            let wine = URL(fileURLWithPath: runtime).deletingLastPathComponent().deletingLastPathComponent()
            let updated = try WinePrefixMigration.refresh(prefix: prefix, wine: wine, backup: backup)
            diagnostics.write("Componenti", "Migrazione Wine: " + String(updated) + " componenti interni aggiornati; backup completato.")
        }
        if changedRuntime || !WineRuntime.missingFiles(prefix: prefix).isEmpty {
            try await prepare(prefix: prefix, runtime: runtime, arguments: ["wineboot", "-u"])
            message = "Attendo che Wine completi il container…"
            try await WineRuntime.waitUntilReady(prefix: prefix)
        }
        try WineRuntime.validate(prefix: prefix)
        if ownedRuntime {
            try FileManager.default.createDirectory(at: runtimeReceipt.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(runtime.utf8).write(to: runtimeReceipt, options: .atomic)
        }
        for step in dependencies where !step.isModernVisualCPP {
            message = "Installazione automatica: \(step.name)…"
            do { try await prepare(prefix: prefix, runtime: runtime, arguments: step.wineArguments, directory: step.executable.deletingLastPathComponent()) }
            catch is CancellationError { throw CancellationError() }
            catch { throw DockError.message("Preparazione automatica di \(step.name) non riuscita: \(error.localizedDescription)") }
            try FileManager.default.createDirectory(at: step.marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: step.marker, options: [.atomic])
        }
        for arch in try WindowsPrerequisites.architectures(in: directory) {
            if WindowsPrerequisites.isReady(prefix: prefix, architecture: arch) {
                diagnostics.write("Componenti", "Visual C++ \(arch) già valido: \(WindowsPrerequisites.registeredVersion(prefix: prefix, architecture: arch)?.map(String.init).joined(separator: ".") ?? "")")
                continue
            }
            message = "Recupero Visual C++ 2015–2022 (\(arch))…"
            let installer = try await WindowsPrerequisites.download(architecture: arch, cache: root.appendingPathComponent("Tools/VisualCPP"))
            message = "Installazione Visual C++ (\(arch))…"
            try await prepare(prefix: prefix, runtime: runtime, arguments: [SteamDependency.windowsPath(installer), "/install", "/quiet", "/norestart"], existingVisualCPP: arch)
            try await WindowsPrerequisites.waitUntilInstalled(prefix: prefix, architecture: arch)
            try WindowsPrerequisites.record(prefix: prefix, architecture: arch)
        }
    }
    func verifyWindowsRuntime(runtime: String) async throws {
        guard !busy && !preparing else { throw DockError.message("Attendi che termini l'operazione corrente.") }
        let probe = root.appendingPathComponent("Tools/BootstrapChecks/" + UUID().uuidString + "/prefix")
        try FileManager.default.createDirectory(at: probe.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let oldGame = activeGame; activeGame = nil
        defer { activeGame = oldGame }
        diagnostics.write("Motore", "Verifica bootstrap Windows in un container nuovo, separato dai giochi.")
        do {
            try await prepare(prefix: probe, runtime: runtime, arguments: ["wineboot", "--init"])
            try await WineRuntime.waitUntilReady(prefix: probe)
        } catch is CancellationError { throw CancellationError() }
        catch {
            diagnostics.write("Motore", "Bootstrap Windows non completato: " + error.localizedDescription)
            throw DockError.message("Il motore Wine non completa l'inizializzazione di Windows. Apri Log → Motore Windows · Bootstrap per la diagnosi.")
        }
        diagnostics.write("Motore", "Bootstrap Windows verificato in un container nuovo.")
    }
    private func prepare(prefix: URL, runtime: String, arguments: [String], directory: URL? = nil, existingVisualCPP: String? = nil) async throws {
        try Task.checkCancellation()
        diagnostics.write("Componenti", "Preparazione: " + (arguments.first.map { URL(fileURLWithPath: $0.replacingOccurrences(of: "\\", with: "/")).lastPathComponent } ?? "Wine"))
        busy = true
        defer { busy = false; process = nil }
        let p = Process(); p.executableURL = URL(fileURLWithPath: runtime)
        p.arguments = arguments
        var wineEnvironment = OwnedRuntime(root: root).environment(runtime: runtime, prefix: prefix, directX12: false)
        if arguments.first?.lowercased().contains("wineboot") == true {
            wineEnvironment["WINEDEBUG"] = "-all,err+all,trace+module,trace+process,trace+seh"
            if OwnedRuntime(root: root).installed?.path == runtime {
                let boot = URL(fileURLWithPath: runtime).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/wine/x86_64-windows/wineboot.exe")
                p.arguments = [boot.path] + arguments.dropFirst()
            }
        }
        let isolated = ["DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"].filter { ProcessInfo.processInfo.environment[$0] != nil && wineEnvironment[$0] == nil }
        if !isolated.isEmpty { diagnostics.write("Componenti", "Diagnostica Xcode esclusa dai processi Wine: " + isolated.joined(separator: ", ")) }
        p.environment = wineEnvironment
        p.currentDirectoryURL = directory
        p.standardInput = FileHandle.nullDevice
        let output = WineOutputTail(), stdout = Pipe(), stderr = Pipe()
        p.standardOutput = stdout; p.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        defer { stdout.fileHandleForReading.readabilityHandler = nil; stderr.fileHandleForReading.readabilityHandler = nil }
        process = p
        let status: Int32 = try await withCheckedThrowingContinuation { c in
            p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { p.terminationHandler = nil; c.resume(throwing: error) }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        do {
            let folder = root.appendingPathComponent("Logs")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(activeGame.map { $0.uuidString + ".log" } ?? "engine-check.log")
            let heading = Data("\nWine preparation — \(Date())\nRuntime: \(runtime)\nCommand: \((p.arguments ?? arguments).joined(separator: " "))\nExit: \(status)\n".utf8)
            var content = Data()
            if let reader = try? FileHandle(forReadingFrom: file) {
                defer { try? reader.close() }
                if let length = try? reader.seekToEnd() {
                    try? reader.seek(toOffset: length > 131072 ? length - 131072 : 0)
                    content = (try? reader.read(upToCount: 131072)) ?? Data()
                }
            }
            content.append(heading); content.append(output.snapshot())
            try? content.write(to: file, options: .atomic)
        }
        process = nil
        diagnostics.write("Componenti", "Wine: codice di uscita \(status)")
        if cancelled || Task.isCancelled { throw CancellationError() }
        if status == 102, let arch = existingVisualCPP, WindowsPrerequisites.installedAndCompatible(prefix: prefix, architecture: arch) { diagnostics.write("Componenti", "Codice 102 accettato: runtime \(arch) già registrato e DLL compatibili verificate."); return }
        guard [0, 194, 105].contains(status) else { throw DockError.message("Il download è completo, ma la preparazione Wine non è riuscita (\(status)).") }
    }
}
