import Foundation

struct WindowsGameLaunch {
    let executable: URL
    let arguments: [String]
    let workingDirectory: URL
    let bypassedBootstrapper: Bool
    static func resolve(executable: URL, directory: URL, arguments: [String], workingDirectory: URL) throws -> WindowsGameLaunch {
        let original = WindowsGameLaunch(executable: executable, arguments: arguments, workingDirectory: workingDirectory, bypassedBootstrapper: false)
        // Unreal's packaged bootstrapper explicitly stores the target and its arguments in RCDATA.
        // Never guess a target by picking the first EXE in the installation.
        let size = (try? executable.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= 16_000_000 else { return original }
        let data = try Data(contentsOf: executable)
        guard data.range(of: Data("BootstrapPackagedGame".utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })) != nil else { return original }
        let pe = try PEResources(data)
        guard let target = try pe.text(type: 10, id: 201), !target.isEmpty else { throw DockError.message("Bootstrapper Unreal privo del percorso di avvio.") }
        let resolved = try DeckMetadata.contained(target, in: directory)
        guard resolved.pathExtension.lowercased() == "exe", resolved.standardizedFileURL != executable.standardizedFileURL,
              FileManager.default.fileExists(atPath: resolved.path) else { throw DockError.message("Eseguibile Unreal dichiarato dal gioco mancante. Verifica i file del gioco.") }
        let handle = try FileHandle(forReadingFrom: resolved); defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 65536), (try? SteamBridgeInstaller.architecture(header)) == (try? SteamBridgeInstaller.architecture(data)) else { throw DockError.message("Architettura dell'eseguibile Unreal non valida.") }
        let extra = try WindowsArguments.parse(try pe.text(type: 10, id: 202) ?? "")
        return WindowsGameLaunch(executable: resolved, arguments: extra + arguments, workingDirectory: workingDirectory, bypassedBootstrapper: true)
    }
    func standaloneCompatible() -> WindowsGameLaunch {
        let explicit = ["-dx11", "-d3d11", "-dx12", "-d3d12", "-vulkan", "-opengl"]
        guard bypassedBootstrapper, !arguments.contains(where: { explicit.contains($0.lowercased()) }),
              let data = try? Data(contentsOf: executable, options: .mappedIfSafe), data.count <= 512_000_000,
              data.range(of: Data("D3D11RHI".utf8)) != nil else { return self }
        return WindowsGameLaunch(executable: executable, arguments: arguments + ["-dx11"], workingDirectory: workingDirectory, bypassedBootstrapper: true)
    }
    var usesDirectX12: Bool {
        if arguments.contains(where: { ["-dx11", "-d3d11"].contains($0.lowercased()) }) { return false }
        guard let data = try? Data(contentsOf: executable, options: .mappedIfSafe), data.count <= 512_000_000, (try? SteamBridgeInstaller.architecture(data)) == "x64" else { return false }
        return ["D3D12RHI", "d3d12.dll", "D3D12.dll"].contains { data.range(of: Data($0.utf8)) != nil }
    }
}

private struct PEResources {
    let data: Data
    let base: Int
    let sections: [(rva: Int, size: Int, offset: Int)]
    static func uint(_ data: Data, _ at: Int, width: Int = 4) throws -> Int {
        guard at >= 0, at <= data.count - width else { throw DockError.message("Risorse dell'eseguibile Windows incomplete.") }
        return (0..<width).reduce(0) { $0 | Int(data[at + $1]) << (8 * $1) }
    }
    init(_ data: Data) throws {
        _ = try SteamBridgeInstaller.architecture(data)
        self.data = data
        let nt = try Self.uint(data, 60), count = try Self.uint(data, nt + 6, width: 2), size = try Self.uint(data, nt + 20, width: 2), optional = nt + 24
        guard count > 0, count <= 96, size >= 120 else { throw DockError.message("Sezioni dell'eseguibile Windows non valide.") }
        let magic = try Self.uint(data, optional, width: 2)
        guard [0x10b, 0x20b].contains(magic) else { throw DockError.message("Formato Windows non supportato.") }
        let directories = optional + (magic == 0x20b ? 112 : 96)
        guard directories + 24 <= optional + size else { throw DockError.message("Tabella risorse Windows incompleta.") }
        let resourceRVA = try Self.uint(data, directories + 16)
        var sections: [(Int, Int, Int)] = []
        for i in 0..<count {
            let header = optional + size + 40 * i
            sections.append((try Self.uint(data, header + 12), try Self.uint(data, header + 16), try Self.uint(data, header + 20)))
        }
        self.sections = sections
        guard let section = sections.first(where: { resourceRVA >= $0.0 && resourceRVA - $0.0 < $0.1 }) else { throw DockError.message("Risorse bootstrapper Windows mancanti.") }
        base = section.2 + resourceRVA - section.0
    }
    private func entry(directory: Int, id: Int?) throws -> Int? {
        let at = base + directory
        let named = try Self.uint(data, at + 12, width: 2), numbered = try Self.uint(data, at + 14, width: 2)
        guard named + numbered <= 256 else { throw DockError.message("Troppe risorse nel bootstrapper Windows.") }
        for index in 0..<(named + numbered) {
            let name = try Self.uint(data, at + 16 + 8 * index), value = try Self.uint(data, at + 20 + 8 * index)
            if id == nil || name == id { return value }
        }
        return nil
    }
    func text(type: Int, id: Int) throws -> String? {
        guard let typeEntry = try entry(directory: 0, id: type), typeEntry & 0x80000000 != 0,
              let nameEntry = try entry(directory: typeEntry & 0x7fffffff, id: id), nameEntry & 0x80000000 != 0,
              let language = try entry(directory: nameEntry & 0x7fffffff, id: nil), language & 0x80000000 == 0 else { return nil }
        let rva = try Self.uint(data, base + language), length = try Self.uint(data, base + language + 4)
        guard length > 0, length <= 65536, length % 2 == 0,
              let section = sections.first(where: { rva >= $0.rva && rva - $0.rva < $0.size }),
              length <= section.size - (rva - section.rva) else { throw DockError.message("Testo delle risorse Windows non valido.") }
        let at = section.offset + rva - section.rva
        guard at >= 0, at <= data.count - length, let text = String(data: data.subdata(in: at..<at + length), encoding: .utf16LittleEndian) else { throw DockError.message("Testo bootstrapper Windows non leggibile.") }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
}
