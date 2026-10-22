import Foundation
import CryptoKit

// Official redistributables are installed in each Wine prefix, never in the host OS.
enum WindowsPrerequisites {
    static func architectures(in directory: URL) throws -> [String] {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        var result = Set<String>()
        for case let file as URL in files {
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { files.skipDescendants(); continue }
            guard file.pathExtension.lowercased() == "exe", !file.path.contains("/_CommonRedist/") else { continue }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            if let header = try handle.read(upToCount: 65536), let arch = try? SteamBridgeInstaller.architecture(header) { result.insert(arch) }
        }
        return result.sorted()
    }
    static func marker(_ prefix: URL, _ architecture: String) -> URL {
        prefix.appendingPathComponent(".MacGameDeck/components/vc2022-" + architecture + ".json")
    }
    static func dlls(_ prefix: URL, _ architecture: String) -> [URL] {
        let folder = architecture == "x64" ? "system32" : "syswow64"
        let names = architecture == "x64" ? ["vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll"] : ["vcruntime140.dll", "msvcp140.dll"]
        return names.map { prefix.appendingPathComponent("drive_c/windows/" + folder + "/" + $0) }
    }
    // Wine's POSIX exit status truncates Windows 1638 to 102. Only accept it after
    // checking registration AND the installed Microsoft PE versions, never by status alone.
    static func registeredVersion(prefix: URL, architecture: String) -> [UInt32]? {
        guard ["x64", "x86"].contains(architecture), let text = try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8) else { return nil }
        var section = "", fields: [String: UInt32] = [:], versions: [[UInt32]] = []
        let roots = ["software\\microsoft\\visualstudio\\14.0\\vc\\runtimes\\" + architecture,
                     "software\\wow6432node\\microsoft\\visualstudio\\14.0\\vc\\runtimes\\" + architecture]
        func collect() {
            if roots.contains(section), fields["installed"] == 1, fields["major"] == 14, let minor = fields["minor"], minor >= 44 {
                versions.append([14, minor, fields["bld"] ?? 0, fields["rbld"] ?? 0])
            }
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                collect(); fields = [:]
                section = String(line[line.index(after: line.startIndex)..<end]).replacingOccurrences(of: "\\\\", with: "\\").lowercased()
            } else if roots.contains(section), line.hasPrefix("\""), let divider = line.range(of: "\"=dword:") {
                let key = String(line[line.index(after: line.startIndex)..<divider.lowerBound]).lowercased()
                fields[key] = UInt32(line[divider.upperBound...], radix: 16)
            }
        }
        collect()
        return versions.sorted { $0.lexicographicallyPrecedes($1) }.last
    }
    static func fileVersion(_ data: Data) -> [UInt32]? {
        let magic = Data([0xbd, 0x04, 0xef, 0xfe])
        guard let range = data.range(of: magic), range.lowerBound + 16 <= data.count else { return nil }
        func uint(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(data[at + $1]) << (8 * $1) } }
        let ms = uint(range.lowerBound + 8), ls = uint(range.lowerBound + 12)
        return [ms >> 16, ms & 65535, ls >> 16, ls & 65535]
    }
    static func installedAndCompatible(prefix: URL, architecture: String) -> Bool {
        guard registeredVersion(prefix: prefix, architecture: architecture) != nil else { return false }
        return dlls(prefix, architecture).allSatisfy { file in
            guard let data = try? Data(contentsOf: file), (try? SteamBridgeInstaller.architecture(data)) == architecture,
                  let version = fileVersion(data), version[0] == 14, version[1] >= 44 else { return false }
            return true
        }
    }
    static func isReady(prefix: URL, architecture: String) -> Bool {
        guard installedAndCompatible(prefix: prefix, architecture: architecture) else { return false }
        let receipt = marker(prefix, architecture)
        if !FileManager.default.fileExists(atPath: receipt.path) { return true }
        guard let data = try? Data(contentsOf: receipt), let hashes = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
        return dlls(prefix, architecture).allSatisfy { file in
            guard let data = try? Data(contentsOf: file) else { return false }
            return hashes[file.lastPathComponent] == SteamBridgeInstaller.sha256(data)
        }
    }
    static func waitUntilInstalled(prefix: URL, architecture: String, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !installedAndCompatible(prefix: prefix, architecture: architecture) {
            try Task.checkCancellation()
            guard Date() < deadline else { throw DockError.message("Visual C++ non risulta pronto nel container (" + architecture + ") dopo l'attesa di registro e DLL.") }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }
    static func record(prefix: URL, architecture: String) throws {
        guard installedAndCompatible(prefix: prefix, architecture: architecture) else { throw DockError.message("Visual C++ non risulta installato correttamente nel container (" + architecture + ").") }
        var hashes: [String: String] = [:]
        for file in dlls(prefix, architecture) {
            guard let data = try? Data(contentsOf: file), !data.isEmpty else {
                throw DockError.message("Visual C++ non ha completato la preparazione del container (" + file.lastPathComponent + ").")
            }
            hashes[file.lastPathComponent] = SteamBridgeInstaller.sha256(data)
        }
        let target = marker(prefix, architecture)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(hashes).write(to: target, options: .atomic)
    }
    static func download(architecture: String, cache: URL) async throws -> URL {
        guard ["x64", "x86"].contains(architecture) else { throw DockError.message("Architettura runtime non supportata.") }
        try SteamCloudRestore.rejectSymlinks(cache)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let target = cache.appendingPathComponent("vc_redist." + architecture + ".exe")
        let checksum = target.appendingPathExtension("sha256")
        if let existing = try? Data(contentsOf: target), let digest = try? String(contentsOf: checksum, encoding: .utf8),
           digest == SteamBridgeInstaller.sha256(existing), existing.prefix(2) == Data([0x4d, 0x5a]) { return target }
        let url = URL(string: "https://aka.ms/vs/17/release/vc_redist." + architecture + ".exe")!
        var request = URLRequest(url: url); request.timeoutInterval = 120
        var failure: Error = DockError.message("Download Visual C++ non riuscito.")
        for attempt in 0..<3 {
            do {
                try Task.checkCancellation()
                let (temporary, response) = try await URLSession.shared.download(for: request)
                defer { try? FileManager.default.removeItem(at: temporary) }
                let host = response.url?.host?.lowercased() ?? ""
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      response.url?.scheme == "https", host == "aka.ms" || host == "download.microsoft.com" || host.hasSuffix(".microsoft.com") || host.hasSuffix(".visualstudio.microsoft.com") else { throw DockError.message("Risposta inattesa dal download Microsoft.") }
                let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 1_000_000, size < 100_000_000 else { throw DockError.message("Pacchetto Visual C++ incompleto.") }
                let data = try Data(contentsOf: temporary)
                guard data.prefix(2) == Data([0x4d, 0x5a]) else { throw DockError.message("Installer Visual C++ non valido.") }
                try data.write(to: target, options: .atomic)
                try Data(SteamBridgeInstaller.sha256(data).utf8).write(to: checksum, options: .atomic)
                return target
            } catch is CancellationError { throw CancellationError() }
            catch { failure = error; if attempt < 2 { try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000) } }
        }
        throw failure
    }
}

// Wine must bootstrap with PE modules matching its Unix ntdll. An older engine
// cannot always run the wineboot left by a newer one to perform its own update.
enum WinePrefixMigration {
    static func builtin(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256), data.count >= 81,
              data.prefix(2) == Data([0x4d, 0x5a]) else { return false }
        return data.subdata(in: 64..<81) == Data("Wine builtin DLL\0".utf8)
    }
    static func refresh(prefix: URL, wine: URL, backup: URL) throws -> Int {
        var plan: [(URL, URL, String)] = []
        for (arch, folder) in [("x86_64-windows", "system32"), ("i386-windows", "syswow64")] {
            let source = wine.appendingPathComponent("lib/wine/" + arch)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where ["dll", "exe"].contains(file.pathExtension.lowercased()) {
                let relative = "drive_c/windows/" + folder + "/" + file.lastPathComponent
                let target = prefix.appendingPathComponent(relative)
                guard FileManager.default.fileExists(atPath: target.path) else { continue }
                try SteamCloudRestore.rejectSymlinks(file); try SteamCloudRestore.rejectSymlinks(target)
                guard builtin(file), builtin(target), try RuntimeAsset.hash(file) != RuntimeAsset.hash(target) else { continue }
                plan.append((file, target, relative))
            }
        }
        // Finish every backup before replacing even the first Windows component.
        for (_, target, relative) in plan {
            let saved = backup.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: target, to: saved)
        }
        try JSONEncoder().encode(plan.map { $0.2 }).write(to: backup.appendingPathComponent("wine-builtins.json"), options: .atomic)
        for (source, target, _) in plan { try Data(contentsOf: source).write(to: target, options: .atomic) }
        return plan.count
    }
}
