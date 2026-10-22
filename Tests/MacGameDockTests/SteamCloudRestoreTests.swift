import XCTest
@testable import MacGameDock

final class SteamCloudRestoreTests: XCTestCase {
    func fixture() throws -> (URL, Game) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let users = root.appendingPathComponent("prefix/drive_c/users/crossover/AppData/Roaming/Test")
        try FileManager.default.createDirectory(at: users, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let game = Game(id: UUID(), title: "Test", store: .steam, executablePath: root.appendingPathComponent("game.exe").path, addedAt: Date(), steamAppID: 10, installDirectory: root.path,
                        managedLaunch: ManagedLaunch(prefix: root.appendingPathComponent("prefix").path, arguments: [], workingDirectory: root.path, platform: .windows))
        return (root, game)
    }
    func inventory(_ bytes: Data, time: UInt64, name: String = "Test/save.dat", state: Int = 0) throws -> SteamCloudInventory {
        let json: [String: Any] = ["schemaVersion": 1, "steamID": "76561198000000000", "appID": 10, "changeNumber": "1", "isDelta": false, "prefixes": ["%WinAppDataRoaming%"],
            "files": [["name": name, "sha1": InsecureSHA(bytes), "size": bytes.count, "timestamp": time, "state": state, "prefixIndex": 0]],
            "ufs": ["name": "ufs", "children": [["name": "savefiles", "children": [["name": "0", "children": [["name": "root", "value": "WinAppDataRoaming", "children": []], ["name": "path", "value": "Test", "children": []], ["name": "pattern", "value": "*.dat", "children": []]]]]]]]]
        return try JSONDecoder().decode(SteamCloudInventory.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func InsecureSHA(_ data: Data) -> String {
        // Use a real file hash so these tests exercise the same streaming digest as production.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try! data.write(to: file); return try! SteamCloudRestore.hash(file)
    }
    func testNewestCopyWinsAndSameContentAvoidsDownload() throws {
        let (_, game) = try fixture(), bytes = Data("remote".utf8)
        let time = UInt64(Date().timeIntervalSince1970) - 60
        let remote = try inventory(bytes, time: time)
        let target = try SteamCloudRestore.destination("%WinAppDataRoaming%Test/save.dat", game: game, inventory: remote)
        XCTAssertEqual(try SteamCloudRestore.plan(remote, game: game).count, 1)
        try Data("local".utf8).write(to: target)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(time) + 10)], ofItemAtPath: target.path)
        XCTAssertTrue(try SteamCloudRestore.plan(remote, game: game).isEmpty)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(time) - 10)], ofItemAtPath: target.path)
        XCTAssertEqual(try SteamCloudRestore.plan(remote, game: game).count, 1)
        try bytes.write(to: target)
        XCTAssertTrue(try SteamCloudRestore.plan(remote, game: game).isEmpty)
    }
    func testSameDateDifferentContentIsAConflictAndDeletionsAreIgnored() throws {
        let (_, game) = try fixture(), time = UInt64(Date().timeIntervalSince1970) - 60
        let remote = try inventory(Data("remote".utf8), time: time)
        let target = try SteamCloudRestore.destination("%WinAppDataRoaming%Test/save.dat", game: game, inventory: remote)
        try Data("local".utf8).write(to: target)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(time))], ofItemAtPath: target.path)
        XCTAssertThrowsError(try SteamCloudRestore.plan(remote, game: game))
        XCTAssertTrue(try SteamCloudRestore.plan(inventory(Data(), time: time, state: 2), game: game).isEmpty)
    }
    func testRestorePreservesOriginalAndRemoteTimestamp() throws {
        let (root, game) = try fixture(), time = UInt64(Date().timeIntervalSince1970) - 60
        let remote = try inventory(Data("remote".utf8), time: time)
        let target = try SteamCloudRestore.destination("%WinAppDataRoaming%Test/save.dat", game: game, inventory: remote)
        try Data("old".utf8).write(to: target)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(time) - 10)], ofItemAtPath: target.path)
        let entries = try SteamCloudRestore.plan(remote, game: game)
        let staging = root.appendingPathComponent("staging"), backups = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("remote".utf8).write(to: staging.appendingPathComponent("0.save"))
        try SteamCloudRestore.apply(entries, staging: staging, backups: backups)
        XCTAssertEqual(try String(contentsOf: target), "remote")
        XCTAssertEqual(try String(contentsOf: backups.appendingPathComponent("0.save")), "old")
        XCTAssertEqual(try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970, Double(time))
    }
    func testDamagedDownloadAndLocalChangesCannotOverwriteSaves() throws {
        let (root, game) = try fixture(), time = UInt64(Date().timeIntervalSince1970) - 60
        let remote = try inventory(Data("remote".utf8), time: time)
        let entries = try SteamCloudRestore.plan(remote, game: game)
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: staging.appendingPathComponent("0.save"))
        XCTAssertThrowsError(try SteamCloudRestore.apply(entries, staging: staging, backups: root.appendingPathComponent("backup")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: entries[0].destination.path))
        try Data("remote".utf8).write(to: staging.appendingPathComponent("0.save"))
        try Data("new local".utf8).write(to: entries[0].destination)
        XCTAssertThrowsError(try SteamCloudRestore.apply(entries, staging: staging, backups: root.appendingPathComponent("backup")))
        XCTAssertEqual(try String(contentsOf: entries[0].destination), "new local")
    }
    func testPathsRequireDeclaredSavePatternAndRejectSymlinksAndUnknownRoots() throws {
        let (root, game) = try fixture(), time = UInt64(Date().timeIntervalSince1970) - 60
        XCTAssertThrowsError(try SteamCloudRestore.plan(inventory(Data(), time: time, name: "../save.dat"), game: game))
        for name in ["Another/save.dat", "Test/game.exe", "Test/sub/save.dat"] {
            XCTAssertTrue(try SteamCloudRestore.plan(inventory(Data(), time: time, name: name), game: game).isEmpty)
        }
        let remote = try inventory(Data(), time: time)
        XCTAssertThrowsError(try SteamCloudRestore.destination("%Unknown%Test/save.dat", game: game, inventory: remote))
        let target = root.appendingPathComponent("prefix/drive_c/users/crossover/AppData/Roaming/Test/save.dat")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: root.appendingPathComponent("outside"))
        XCTAssertThrowsError(try SteamCloudRestore.plan(remote, game: game))
    }
    func testBlueRevolverRootOverrideIsCaseInsensitiveAndSDKFilesAreNotGuessed() throws {
        let (_, original) = try fixture(); var game = original; game.steamAppID = 439490
        typealias Node = SteamCloudInventory.Node
        func field(_ key: String, _ value: String) -> Node { Node(name: key, value: value, children: []) }
        let ufs = Node(name: "ufs", value: nil, children: [
            Node(name: "savefiles", value: nil, children: [Node(name: "0", value: nil, children: [field("root", "gameinstall"), field("path", "blue-revolver-double-action"), field("pattern", "brda_save.sav")])]),
            Node(name: "rootoverrides", value: nil, children: [Node(name: "0", value: nil, children: [field("root", "gameinstall"), field("os", "Windows"), field("useinstead", "WinAppDataRoaming"), field("addpath", "")])])
        ])
        let remote = SteamCloudInventory(ufs: ufs, schemaVersion: 1, steamID: "76561198000000000", appID: 439490, changeNumber: "1", isDelta: false, prefixes: ["%GameInstall%blue-revolver-double-action/"], files: [
            .init(name: "brda_save.sav", sha1: InsecureSHA(Data()), size: 0, timestamp: UInt64(Date().timeIntervalSince1970) - 60, state: 0, prefixIndex: 0),
            .init(name: "replay.brd", sha1: InsecureSHA(Data()), size: 0, timestamp: UInt64(Date().timeIntervalSince1970) - 60, state: 0, prefixIndex: 0)
        ])
        let entries = try SteamCloudRestore.plan(remote, game: game)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries.allSatisfy { $0.destination.path.contains("/AppData/Roaming/blue-revolver-double-action/") })
        XCTAssertThrowsError(try SteamCloudRestore.destination("%GameInstall%blue-revolver-double-action/replays/evil.exe", game: game, inventory: remote))
    }

}

extension SteamCloudRestoreTests {
    func testMigratedPrefixUsesDeclaredActiveProfileAndPreservesOldFolder() throws {
        let (root, game) = try fixture()
        let prefix = URL(fileURLWithPath: game.managedLaunch!.prefix)
        let active = prefix.appendingPathComponent("drive_c/users/player")
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try Data(#"""
[Volatile Environment]
"USERPROFILE"="C:\\users\\player"
"""#.utf8).write(to: prefix.appendingPathComponent("user.reg"))
        XCTAssertEqual(try SteamCloudRestore.wineUser(prefix: prefix).resolvingSymlinksInPath().path, active.resolvingSymlinksInPath().path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("prefix/drive_c/users/crossover").path))
        try Data(#"""
[Volatile Environment]
"USERPROFILE"="C:\\users\\.."
"""#.utf8).write(to: prefix.appendingPathComponent("user.reg"))
        XCTAssertThrowsError(try SteamCloudRestore.wineUser(prefix: prefix))
    }
}
