import XCTest
@testable import MacGameDock

final class DirectLaunchTests: XCTestCase {
    @MainActor
    func testManagedSteamGameLaunchesExecutableWithoutClientOrAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldDirectory = getenv("MACGAMEDOCK_DATA_DIRECTORY").map { String(cString: $0) }
        setenv("MACGAMEDOCK_DATA_DIRECTORY", root.path, 1)
        defer {
            if let oldDirectory { setenv("MACGAMEDOCK_DATA_DIRECTORY", oldDirectory, 1) } else { unsetenv("MACGAMEDOCK_DATA_DIRECTORY") }
            try? FileManager.default.removeItem(at: root)
        }
        let executable = root.appendingPathComponent("Game/game.exe")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        let runtime = root.appendingPathComponent("fake-wine")
        try Data("#!/bin/sh\nprintf 'GAME=%s\\nARG=%s\\n' \"$1\" \"$2\"\n".utf8).write(to: runtime)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
        let prefix = root.appendingPathComponent("Prefix")
        for relative in WineRuntime.requiredFiles {
            let file = prefix.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
        }
        let game = Game(id: UUID(), title: "Direct launch regression", store: .steam, executablePath: executable.path, addedAt: Date(), steamAppID: 123,
                        installDirectory: executable.deletingLastPathComponent().path,
                        managedLaunch: ManagedLaunch(prefix: prefix.path, arguments: ["--test"], workingDirectory: executable.deletingLastPathComponent().path, platform: .windows))
        var data = LibraryData(); data.games = [game]
        try JSONEncoder().encode(data).write(to: root.appendingPathComponent("library.json"))
        let library = Library(runtimeResolver: { runtime.path })
        library.launch(game)
        for _ in 0..<100 {
            if !library.running.contains(game.id), !library.preparingLaunch.contains(game.id) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(library.error)
        XCTAssertNil(library.installSelection)
        XCTAssertNil(library.data.steamAccount)
        let log = try String(contentsOf: library.log(for: game), encoding: .utf8)
        XCTAssertTrue(log.contains("GAME=\(executable.path)\nARG=--test"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Tools/SteamClient").path))
    }
}
