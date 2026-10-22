import XCTest
@testable import MacGameDock

final class AutomaticPreparationTests: XCTestCase {
    func testExternalSteamBundleCanLaunchWithoutDownloading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("steamapps")
        let app = apps.appendingPathComponent("common/Indie/Indie.app").standardizedFileURL
        let binary = app.appendingPathComponent("Contents/MacOS/Indie")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Indie"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data(#"""
        "AppState" { "appid" "123" "name" "Indie" "installdir" "Indie" "StateFlags" "4" }
        """#.utf8).write(to: apps.appendingPathComponent("appmanifest_123.acf"))
        var result = ScanResult()
        InstalledGamesScanner(home: root).scanSteam(apps, into: &result)
        let game = try XCTUnwrap(result.games.first)
        XCTAssertTrue(game.isInstalled)
        XCTAssertTrue(game.isNative)
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: game.executablePath, andPath: app.path))
        XCTAssertNil(game.launchURL)
        var catalog = LibraryData()
        catalog.games = [Game(id: UUID(), title: "Indie", store: .steam, executablePath: "", addedAt: Date(), steamAppID: 123)]
        let merged = LibraryMerge.scan(result, into: catalog)
        XCTAssertEqual(merged.games.count, 1)
        XCTAssertTrue(merged.games[0].isInstalled)
        XCTAssertEqual(merged.games[0].executablePath, game.executablePath)
    }
    func testRuntimeReceiptDoesNotHideMissingOrModifiedDLLs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(WindowsPrerequisites.isReady(prefix: root, architecture: "x64"))
        try VisualCPPFixture.write(to: root)
        try WindowsPrerequisites.record(prefix: root, architecture: "x64")
        XCTAssertTrue(WindowsPrerequisites.isReady(prefix: root, architecture: "x64"))
        let dll = WindowsPrerequisites.dlls(root, "x64")[0]
        try Data("changed".utf8).write(to: dll)
        XCTAssertFalse(WindowsPrerequisites.isReady(prefix: root, architecture: "x64"))
        try FileManager.default.removeItem(at: dll)
        XCTAssertThrowsError(try WindowsPrerequisites.record(prefix: root, architecture: "x64"))
    }
}
