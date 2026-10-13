import XCTest
@testable import MacGameDock

final class SteamClientServicesTests: XCTestCase {
    private func receipt(_ os: String = "windows", appID: UInt32 = 10, buildID: UInt32 = 200) -> SteamClientReceipt {
        SteamClientReceipt(appID: appID, buildID: buildID, os: os, depots: [.init(depotID: 11, manifestID: "9876543210123456789", size: 123)])
    }
    func testManifestPreservesDownloadedDepotAndEscapesTitle() throws {
        let text = SteamClientLayout.manifest(receipt: receipt(), title: "A\"B\\C\nD", folder: "MacGameDeck-10", account: "76561198000000000")
        let state = try XCTUnwrap(VDF.parse(text)["AppState"]?.fields)
        XCTAssertEqual(state["appid"]?.string, "10")
        XCTAssertEqual(state["name"]?.string, "A\"B\\C\nD")
        XCTAssertEqual(state["buildid"]?.string, "200")
        XCTAssertEqual(state["InstalledDepots"]?.fields?["11"]?.fields?["manifest"]?.string, "9876543210123456789")
    }
    func testWrongReceiptNeverAccepted() throws {
        XCTAssertThrowsError(try receipt(appID: 20).validate(appID: 10, platform: .windows))
        XCTAssertThrowsError(try receipt("macos").validate(appID: 10, platform: .windows))
        XCTAssertThrowsError(try receipt(buildID: 0).validate(appID: 10, platform: .windows))
        let duplicate = SteamClientReceipt(appID: 10, buildID: 200, os: "windows", depots: [.init(depotID: 11, manifestID: "22", size: 0), .init(depotID: 11, manifestID: "33", size: 0)])
        XCTAssertThrowsError(try duplicate.validate(appID: 10, platform: .windows))
    }
    func testRegistrationReusesFilesAndPreservesClientManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Game"), client = root.appendingPathComponent("Steam")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let exe = source.appendingPathComponent("game.exe"); try Data("game".utf8).write(to: exe)
        var game = Game(id: UUID(), title: "Test", store: .steam, executablePath: exe.path, addedAt: Date(), steamAppID: 10)
        game.installDirectory = source.path
        game.managedLaunch = ManagedLaunch(prefix: root.path, arguments: [], workingDirectory: source.path, platform: .windows)
        try SteamClientLayout.register(game: game, steamDirectory: client, receipt: receipt(), account: "76561198000000000")
        XCTAssertEqual(try Data(contentsOf: client.appendingPathComponent("steamapps/common/MacGameDeck-10/game.exe")), Data("game".utf8))
        let manifest = client.appendingPathComponent("steamapps/appmanifest_10.acf")
        let original = try Data(contentsOf: manifest)
        try SteamClientLayout.register(game: game, steamDirectory: client, receipt: receipt(buildID: 300), account: "76561198000000000")
        XCTAssertEqual(try Data(contentsOf: manifest), original, "The official client owns updates after adoption")
        let conflict = Data("\"AppState\" { \"appid\" \"10\" \"installdir\" \"OtherGame\" }".utf8)
        try conflict.write(to: manifest)
        XCTAssertThrowsError(try SteamClientLayout.register(game: game, steamDirectory: client, receipt: receipt(), account: "76561198000000000"))
        XCTAssertEqual(try Data(contentsOf: manifest), conflict)
        XCTAssertEqual(try Data(contentsOf: exe), Data("game".utf8))
    }
    func testRegistrationRejectsEscapingSteamappsSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Game"), client = root.appendingPathComponent("Steam"), outside = root.appendingPathComponent("Outside")
        for dir in [source, client, outside] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(at: client.appendingPathComponent("steamapps"), withDestinationURL: outside)
        var game = Game(id: UUID(), title: "Test", store: .steam, executablePath: source.appendingPathComponent("game.exe").path, addedAt: Date(), steamAppID: 10)
        game.installDirectory = source.path; game.managedLaunch = ManagedLaunch(prefix: root.path, arguments: [], workingDirectory: source.path, platform: .windows)
        XCTAssertThrowsError(try SteamClientLayout.register(game: game, steamDirectory: client, receipt: receipt(), account: "76561198000000000"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
    func testRecentOfficialClientAccountUsesMostRecentOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config"); try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        XCTAssertNil(try SteamClientLayout.recentAccount(at: root))
        let file = config.appendingPathComponent("loginusers.vdf")
        try Data("\"users\" { \"111\" { \"MostRecent\" \"0\" } \"222\" { \"MostRecent\" \"1\" } }".utf8).write(to: file)
        XCTAssertEqual(try SteamClientLayout.recentAccount(at: root), "222")
        try Data("\"users\" { \"111\" { \"MostRecent\" \"1\" } \"222\" { \"MostRecent\" \"1\" } }".utf8).write(to: file)
        XCTAssertThrowsError(try SteamClientLayout.recentAccount(at: root))
    }
}
