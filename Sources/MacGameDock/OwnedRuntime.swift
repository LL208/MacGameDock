import Foundation
import CryptoKit
import SwiftUI

struct RuntimeAsset {
    let id: String
    let url: URL
    let sha256: String
    let size: Int64
    let directory: String
    static let wine = RuntimeAsset(id: "wine-cx-foss-24.0.7_7", url: URL(string: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineCX24.0.7_7.tar.xz")!, sha256: "203f9e9fd6c2cc77e6525d798a434ced326145db34a356355e05659d3445fd1c", size: 172348356, directory: "wswine.bundle")
    static let support = RuntimeAsset(id: "wine-support-11.18", url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/wine-staging-11.18-osx64.tar.xz")!, sha256: "b63704b91af269bc026a87f12bd297c4a50caaf570c322e600b6621ef918f127", size: 193105336, directory: "Wine Staging.app/Contents/Resources/wine")
    static let dxmt = RuntimeAsset(id: "dxmt-0.80", url: URL(string: "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz")!, sha256: "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d", size: 18681669, directory: "v0.80")
    static func hash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func validate(_ file: URL) throws {
        let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(bytes) == size, try Self.hash(file) == sha256 else { throw DockError.message("Il pacchetto " + id + " non supera la verifica di integrità. Riprova il download.") }
    }
}
private final class RuntimeProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Int64, Int64) -> Void
    init(update: @escaping @Sendable (Int64, Int64) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { update(totalBytesWritten, totalBytesExpectedToWrite) }
}
@MainActor
final class OwnedRuntime: ObservableObject {
    let root: URL
    @Published private(set) var message = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var busy = false
    private var task: Task<URL, Error>?
    private var folder: URL { root.appendingPathComponent("Tools/GameEngine/wine-cxfoss-24.0.7_7-dxmt-0.80-support1") }
    var wineRoot: URL { folder.appendingPathComponent("Wine/" + RuntimeAsset.wine.directory) }
    var dxmtRoot: URL { folder.appendingPathComponent("DXMT/v0.80") }
    static func executable(in root: URL) -> URL {
        let wine = root.appendingPathComponent("bin/wine")
        return FileManager.default.isExecutableFile(atPath: wine.path) ? wine : root.appendingPathComponent("bin/wine64")
    }
    static func validateGraphics(in root: URL) throws {
        let modern = root.appendingPathComponent("lib/wine/x86_64-unix/winemac.so")
        let module = FileManager.default.fileExists(atPath: modern.path) ? modern : root.appendingPathComponent("lib/wine/x86_64-unix/winemac.drv.so")
        try RuntimeGraphicsValidator.validate(module)
    }
    var requiredFiles: [URL] {
        [wineRoot.appendingPathComponent("bin/wine"), wineRoot.appendingPathComponent("bin/wineserver"), wineRoot.appendingPathComponent("lib/libinotify.0.dylib"),
         dxmtRoot.appendingPathComponent("x86_64-unix/winemetal.so"), dxmtRoot.appendingPathComponent("x86_64-windows/d3d11.dll"), dxmtRoot.appendingPathComponent("x86_64-windows/dxgi.dll")]
    }
    var installed: URL? {
        let exe = Self.executable(in: wineRoot)
        guard FileManager.default.isExecutableFile(atPath: exe.path),
              let bytes = try? Data(contentsOf: folder.appendingPathComponent("ready.json")),
              let receipt = try? JSONDecoder().decode([String: String].self, from: bytes),
              receipt["wine"] == RuntimeAsset.wine.sha256, receipt["dxmt"] == RuntimeAsset.dxmt.sha256, receipt["support"] == RuntimeAsset.support.sha256,
              requiredFiles.dropFirst().allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }),
              (try? Self.validateGraphics(in: wineRoot)) != nil else { return nil }
        return exe
    }
    private var bootstrapReceipt: [String: String] { ["wine": RuntimeAsset.wine.sha256, "dxmt": RuntimeAsset.dxmt.sha256, "support": RuntimeAsset.support.sha256] }
    var bootstrapVerified: Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("bootstrap-ready.json")),
              let receipt = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
        return receipt == bootstrapReceipt
    }
    func recordBootstrapSuccess() throws {
        try JSONEncoder().encode(bootstrapReceipt).write(to: folder.appendingPathComponent("bootstrap-ready.json"), options: .atomic)
        message = "Motore Windows inizializzato e verificato"
    }
    init(root: URL) { self.root = root }
    func cancel() { task?.cancel() }
    func ensure() async throws -> URL {
        if let installed { try Self.installGraphics(in: folder); return installed }
        let shared: Task<URL, Error>
        if let task { shared = task }
        else {
            shared = Task { try await self.install() }; task = shared
        }
        return try await withTaskCancellationHandler(operation: { try await shared.value }, onCancel: { shared.cancel() })
    }
    private func install() async throws -> URL {
        busy = true
        defer { busy = false; task = nil }
        let staging = root.appendingPathComponent("Tools/GameEngine/staging-" + UUID().uuidString)
        do {
            try SteamCloudRestore.rejectSymlinks(folder.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            for (asset, name) in [(RuntimeAsset.wine, "Wine"), (RuntimeAsset.support, "Support"), (RuntimeAsset.dxmt, "DXMT")] {
                message = "Scarico il motore: " + asset.id
                AppDiagnostics(root: root).write("Motore", message)
                let archive = try await download(asset)
                message = "Installazione " + asset.id + "…"; progress = 1
                let target = staging.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try await extract(archive, to: target)
                _ = try DeckMetadata.contained(asset.directory, in: target)
            }
            try Self.installSupport(in: staging)
            try Self.installGraphics(in: staging)
            let stagedWine = staging.appendingPathComponent("Wine/" + RuntimeAsset.wine.directory)
            try Self.validateGraphics(in: stagedWine)
            AppDiagnostics(root: root).write("Grafica", "Interfaccia Metal Wine verificata: DXMT compatibile")
            let exe = Self.executable(in: stagedWine)
            guard FileManager.default.isExecutableFile(atPath: exe.path),
                  FileManager.default.fileExists(atPath: staging.appendingPathComponent("DXMT/v0.80/x86_64-unix/winemetal.so").path) else { throw DockError.message("Il motore scaricato è incompleto.") }
            try await Self.probeServer(in: stagedWine)
            // Publish only a complete installation. An interrupted update keeps the previous engine.
            try JSONEncoder().encode(["wine": RuntimeAsset.wine.sha256, "dxmt": RuntimeAsset.dxmt.sha256, "support": RuntimeAsset.support.sha256]).write(to: staging.appendingPathComponent("ready.json"), options: .atomic)
            if let notices = try? SteamResources.current().appendingPathComponent("RuntimeNotices") {
                try FileManager.default.copyItem(at: notices, to: staging.appendingPathComponent("Notices"))
            }
            let previous = folder.deletingLastPathComponent().appendingPathComponent("recovery-" + UUID().uuidString)
            let hadPrevious = FileManager.default.fileExists(atPath: folder.path)
            if hadPrevious { try FileManager.default.moveItem(at: folder, to: previous) }
            do { try FileManager.default.moveItem(at: staging, to: folder) }
            catch { if hadPrevious { try? FileManager.default.moveItem(at: previous, to: folder) }; throw error }
            message = "Pacchetti verificati; inizializzazione Windows da verificare"; AppDiagnostics(root: root).write("Motore", message)
            return Self.executable(in: wineRoot)
        } catch {
            message = error is CancellationError ? "Preparazione del motore interrotta" : error.localizedDescription
            AppDiagnostics(root: root).write("Motore", message); throw error
        }
    }
    private func download(_ asset: RuntimeAsset) async throws -> URL {
        let cache = root.appendingPathComponent("Tools/GameEngine/Downloads")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let target = cache.appendingPathComponent(asset.url.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path), (try? asset.validate(target)) != nil { return target }
        let delegate = RuntimeProgress { [weak self] bytes, total in
            Task { @MainActor in self?.progress = min(1, Double(bytes) / Double(total > 0 ? total : asset.size)) }
        }
        let resumeFile = cache.appendingPathComponent(asset.id + ".resume")
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 7200
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var resume = try? Data(contentsOf: resumeFile)
        for attempt in 1...4 {
            try Task.checkCancellation()
            do {
                let result: (URL, URLResponse)
                if let data = resume {
                    result = try await session.download(resumeFrom: data, delegate: delegate)
                } else {
                    var request = URLRequest(url: asset.url)
                    request.timeoutInterval = 120
                    result = try await session.download(for: request, delegate: delegate)
                }
                let (temporary, response) = result
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode), response.url?.scheme == "https" else {
                    throw DockError.message("Il server del motore non ha completato il download.")
                }
                try Task.checkCancellation(); message = "Verifica " + asset.id + "…"
                try asset.validate(temporary)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: temporary, to: target)
                try? FileManager.default.removeItem(at: resumeFile)
                return target
            } catch {
                let ns = error as NSError
                resume = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                if let resume { try? resume.write(to: resumeFile, options: .atomic) }
                else { try? FileManager.default.removeItem(at: resumeFile) }
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                AppDiagnostics(root: root).write("Motore", asset.id + ": " + ns.domain + " (" + String(ns.code) + "), tentativo " + String(attempt))
                guard Self.shouldRetry(error, attempt: attempt) else {
                    throw DockError.message("Download " + asset.id + " non completato: " + error.localizedDescription + ". Riprova: i pacchetti già verificati sono conservati.")
                }
                message = "Connessione interrotta · riprovo " + asset.id + " (" + String(attempt + 1) + "/4)…"
                try await Task.sleep(nanoseconds: UInt64(attempt * 2) * 1_000_000_000)
            }
        }
        throw DockError.message("Download del motore non completato.")
    }
    static func shouldRetry(_ error: Error, attempt: Int) -> Bool {
        guard attempt < 4, let network = error as? URLError else { return false }
        let codes: [URLError.Code] = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet]
        return codes.contains(network.code)
    }

    private func extract(_ archive: URL, to folder: URL) async throws {
        // Only SHA-256 pinned upstream archives reach this operation.
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", archive.path, "-C", folder.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        let code: Int32 = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
            }
        }, onCancel: { if process.isRunning { process.terminate() } })
        try Task.checkCancellation()
        guard code == 0 else { throw DockError.message("Estrazione del motore non riuscita (" + String(code) + ").") }
    }
    static func installSupport(in folder: URL) throws {
        let source = folder.appendingPathComponent("Support/" + RuntimeAsset.support.directory + "/lib")
        let target = folder.appendingPathComponent("Wine/" + RuntimeAsset.wine.directory + "/lib")
        try SteamCloudRestore.rejectSymlinks(target)
        for entry in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where entry.lastPathComponent != "wine" {
            let destination = target.appendingPathComponent(entry.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: entry, to: destination)
        }
        guard FileManager.default.fileExists(atPath: target.appendingPathComponent("libinotify.0.dylib").path) else { throw DockError.message("Librerie macOS del motore incomplete: libinotify mancante.") }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Support"))
    }
    static func probeServer(in root: URL) async throws {
        let process = Process(); process.executableURL = root.appendingPathComponent("bin/wineserver")
        process.arguments = ["--version"]
        var env = ProcessInfo.processInfo.environment
        env["DYLD_FALLBACK_LIBRARY_PATH"] = root.appendingPathComponent("lib").path
        process.environment = env
        let pipe = Pipe(), output = WineOutputTail()
        process.standardOutput = pipe; process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
        }
        guard status == 0 else { throw DockError.message("Verifica del motore Wine fallita: " + String(decoding: output.snapshot(), as: UTF8.self)) }
    }
    static func graphicsFiles() -> [String] {
        ["x86_64-unix/winemetal.so"] + ["x86_64-windows", "i386-windows"].flatMap { arch in
            ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll"].map { arch + "/" + $0 }
        }
    }
    static func installGraphics(in folder: URL) throws {
        let source = folder.appendingPathComponent("DXMT/v0.80")
        let target = folder.appendingPathComponent("Wine/" + RuntimeAsset.wine.directory + "/lib/wine")
        try SteamCloudRestore.rejectSymlinks(target)
        for name in graphicsFiles() {
            let from = source.appendingPathComponent(name), to = target.appendingPathComponent(name)
            try SteamCloudRestore.rejectSymlinks(from); try SteamCloudRestore.rejectSymlinks(to)
            guard FileManager.default.fileExists(atPath: from.path) else { throw DockError.message("Componente DXMT mancante: " + name) }
            if FileManager.default.fileExists(atPath: to.path), try RuntimeAsset.hash(from) == RuntimeAsset.hash(to) { continue }
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = try Data(contentsOf: from)
            try bytes.write(to: to, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: to.path)
        }
    }
    func environment(runtime: String, prefix: URL, directX12: Bool) -> [String: String] {
        var env = WineRuntime.environment(prefix: prefix, runtime: runtime)
        guard runtime == installed?.path else { return env }
        for key in Array(env.keys).filter({ $0.hasPrefix("CX_") }) { env.removeValue(forKey: key) }
        // Xcode's injected diagnostics are for the Swift app, not Wine's translated
        // child processes and their independent Mach-O/Windows loader.
        for key in ["DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"] { env.removeValue(forKey: key) }

        env["PATH"] = wineRoot.appendingPathComponent("bin").path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["WINESERVER"] = wineRoot.appendingPathComponent("bin/wineserver").path
        env["WINELOADER"] = runtime
        if env["ROSETTA_ADVERTISE_AVX"] == nil { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        if env["ROSETTA_ADVERTISE_AVX"] == "0" || env["ROSETTA_ADVERTISE_AVX"] == "" { env.removeValue(forKey: "ROSETTA_ADVERTISE_AVX") }
        env["DOTNET_EnableWriteXorExecute"] = "0"
        // Wine selects the matching architecture under this root and loads the Unix
        // bridge beside its ntdll. Flat PE directories can select the wrong ABI.
        env["WINEDLLPATH"] = wineRoot.appendingPathComponent("lib/wine").path
        if !directX12, ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14 {
            env["WINEDLLOVERRIDES"] = [env["WINEDLLOVERRIDES"], "dxgi,d3d11,d3d10core,winemetal=b"].compactMap { $0 }.joined(separator: ";")
        }
        env["DYLD_FALLBACK_LIBRARY_PATH"] = wineRoot.appendingPathComponent("lib").path
        let plugins = wineRoot.appendingPathComponent("lib/gstreamer-1.0")
        if FileManager.default.fileExists(atPath: plugins.path) {
            env["GST_PLUGIN_SYSTEM_PATH"] = plugins.path
            env["GST_REGISTRY"] = root.appendingPathComponent("Tools/GameEngine/gstreamer-registry.bin").path
        }
        return env
    }
}
struct OwnedRuntimeStatus: View {
    @ObservedObject var engine: OwnedRuntime
    var body: some View {
        if engine.busy {
            VStack(alignment: .leading, spacing: 8) { Text(engine.message).font(.caption); ProgressView(value: engine.progress); Button("Annulla preparazione") { engine.cancel() } }.padding(12)
        }
    }
}
