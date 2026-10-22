import Foundation
import Metal
import Darwin

enum GameStore: String, Codable, CaseIterable, Identifiable {
    case steam = "Steam", epic = "Epic", gog = "GOG", local = "Locale"
    var id: String { rawValue }
}

struct Game: Identifiable, Codable {
    let id: UUID
    var title: String
    var store: GameStore
    var executablePath: String
    var addedAt: Date
    var steamAppID: Int?
    var externalID: String?
    var installDirectory: String?
    var launchURL: String?
    var detectedByScan: Bool?
    var catalogOwner: String?
    var managedLaunch: ManagedLaunch?
    var platforms: [String]?
    var familyOwners: [String]?
    var steamMinutes: Int? = nil
    var steamAchievementsUnlocked: Int? = nil
    var steamAchievementsTotal: Int? = nil
    var iconHash: String?
    var isFamilyShared: Bool { !(familyOwners ?? []).isEmpty }
    var isInstalled: Bool {
        let path = managedLaunch == nil ? (installDirectory ?? executablePath) : executablePath
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }
    var identity: String {
        if let steamAppID { return "Steam:\(steamAppID)" }
        if let externalID { return "\(store.rawValue):\(externalID)" }
        return "path:\(URL(fileURLWithPath: executablePath).standardizedFileURL.path)"
    }
    var isNative: Bool { managedLaunch?.platform == .macOS || executablePath.lowercased().hasSuffix(".app") }
}

struct SteamAccount: Codable, Equatable {
    let steamID: String
    let connectedAt: Date
}

struct LibraryData: Codable {
    var schemaVersion = 1
    var games: [Game] = []
    var winePath = ""
    var steamAccount: SteamAccount?
    var steamLibrarySyncedAt: Date?
    var extraScanRoots: [String]?
}

struct Machine {
    let chip: String
    let memoryGB: Int
    let gpu: String
    let macOS: String
    let architecture: String

    static func detect() -> Machine {
        var length = 0
        let name = "machdep.cpu.brand_string"
        var chip = "Mac"
        if sysctlbyname(name, nil, &length, nil, 0) == 0, length > 0 {
            var bytes = [CChar](repeating: 0, count: length)
            let result = bytes.withUnsafeMutableBytes {
                sysctlbyname(name, $0.baseAddress, &length, nil, 0)
            }
            if result == 0 { chip = String(cString: bytes) }
        }
        #if arch(arm64)
        let architecture = "Apple Silicon"
        #else
        let architecture = "Intel / processo Rosetta"
        #endif
        return Machine(
            chip: chip,
            memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            gpu: MTLCreateSystemDefaultDevice()?.name ?? "GPU non rilevata",
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture
        )
    }

    var guidance: String {
        memoryGB <= 8
            ? "Per le prime prove scegli indie leggeri e chiudi le app che usano molta memoria."
            : "Inizia dagli indie e verifica ogni gioco prima di adottare impostazioni più esigenti."
    }
}

enum DockError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}
