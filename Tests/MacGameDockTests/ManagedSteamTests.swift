import XCTest
@testable import MacGameDock

final class ManagedSteamTests: XCTestCase {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testAnEmptyPrefixCannotBeMarkedPrepared() throws {
        let root = try directory()
        XCTAssertThrowsError(try WineRuntime.validate(prefix: root))
    }
    func testSelectsWindowsLaunchAndPreservesQuotedArguments() throws {
        let root = try directory()
        try Data().write(to: root.appendingPathComponent("game.exe"))
        let json = #"{"appID":2851700,"launches":[{"executable":"linux","oslist":"linux"},{"executable":"game.exe","oslist":"windows","arguments":"--name \"Nasty Zombies\""}]}"#
        let metadata = try JSONDecoder().decode(DeckMetadata.self, from: Data(json.utf8))
        let (exe, args, working) = try metadata.select(in: root)
        XCTAssertEqual(exe.lastPathComponent, "game.exe")
        XCTAssertEqual(args, ["--name", "Nasty Zombies"])
        XCTAssertEqual(working.path, root.path)
    }
    func testRejectsTraversalAbsolutePathsAndEscapingSymlink() throws {
        let root = try directory(), outside = try directory()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        for path in ["../game.exe", "C:\\game.exe", "/tmp/game.exe", "escape/game.exe"] {
            XCTAssertThrowsError(try DeckMetadata.contained(path, in: root))
        }
    }
    func testMissingOrNonWindowsExecutableCannotBecomeReady() throws {
        let root = try directory()
        let metadata = try JSONDecoder().decode(DeckMetadata.self, from: Data(#"{"appID":1,"launches":[{"executable":"missing.exe","oslist":"windows"}]}"#.utf8))
        XCTAssertThrowsError(try metadata.select(in: root))
        XCTAssertThrowsError(try WindowsArguments.parse("--name \"unfinished"))
        XCTAssertThrowsError(try WindowsArguments.parse("%command%"))
        XCTAssertEqual(try WindowsArguments.parse(#""" plain "a b" "a\"b""#), ["", "plain", "a b", "a\"b"])
    }
    func testScanPreservesManagedContainerOverExternalSteamInstallation() throws {
        let root = try directory()
        var game = Game(id: UUID(), title: "Nasty Zombies", store: .steam, executablePath: root.appendingPathComponent("game.exe").path, addedAt: Date(), steamAppID: 2851700)
        game.managedLaunch = ManagedLaunch(prefix: root.path, arguments: [], workingDirectory: root.path)
        game.installDirectory = root.path
        var data = LibraryData(); data.games = [game]
        let found = Game(id: UUID(), title: "Nasty Zombies", store: .steam, executablePath: "", addedAt: Date(), steamAppID: 2851700, installDirectory: "/outside", launchURL: "steam://run/2851700", detectedByScan: true)
        let result = LibraryMerge.scan(ScanResult(games: [found], warnings: [], completedSteamApps: []), into: data)
        XCTAssertEqual(result.games[0].installDirectory, root.path)
        XCTAssertNil(result.games[0].launchURL)
    }
    func testDependenciesRemainInsideContainerAndAreNotRepeated() throws {
        let root = try directory()
        try Data().write(to: root.appendingPathComponent("vc.exe"))
        let script = #"""
        "InstallScript" { "Run Process" { "VC" { "process 1" "%INSTALLDIR%\\vc.exe" "command 1" "/quiet /norestart" } } }
        """#
        try Data(script.utf8).write(to: root.appendingPathComponent("installscript.vdf"))
        let plan = try SteamDependencies.plan(in: root)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].arguments, ["/quiet", "/norestart"])
        try FileManager.default.createDirectory(at: plan[0].marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: plan[0].marker)
        XCTAssertTrue(try SteamDependencies.plan(in: root).isEmpty)
        try Data(script.replacingOccurrences(of: "%INSTALLDIR%\\\\vc.exe", with: "%SYSTEMROOT%\\\\bad.exe").utf8).write(to: root.appendingPathComponent("installscript.vdf"))
        XCTAssertThrowsError(try SteamDependencies.plan(in: root))
    }
}
