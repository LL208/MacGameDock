import Foundation
import XCTest
@testable import MacGameDock

final class SteamIntegrationTests: XCTestCase {
    let steamID = "76561198000000000"

    func testVDFParsesNestedLibrariesCommentsAndEscapedPaths() throws {
        let source = #"""
        // Steam libraries
        "libraryfolders" {
            "0" { "path" "/Volumes/Games/SteamLibrary" "apps" { "123" "456" } }
            "1" "C:\\Games\\Steam"
        }
        "name" "A \"quoted\" title"
        "unicode" "Città e 日本語"
        """#
        let parsed = try VDF.parse(source)
        XCTAssertEqual(parsed["libraryfolders"]?.fields?["0"]?.fields?["path"]?.string, "/Volumes/Games/SteamLibrary")
        XCTAssertEqual(parsed["libraryfolders"]?.fields?["1"]?.string, #"C:\Games\Steam"#)
        XCTAssertEqual(parsed["name"]?.string, "A \"quoted\" title")
        XCTAssertEqual(parsed["unicode"]?.string, "Città e 日本語")
        XCTAssertThrowsError(try VDF.parse("\"AppState\" { \"name\" \"Broken\""))
        XCTAssertThrowsError(try VDF.parse("\"name\" \"unterminated"))
    }

    func testScannerUsesInstalledFlagAndRejectsTraversal() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("steamapps")
        let installed = apps.appendingPathComponent("common/Indie")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try manifest(id: 123, title: "Indie", directory: "Indie", flags: 4).write(to: apps.appendingPathComponent("appmanifest_123.acf"), atomically: true, encoding: .utf8)
        try manifest(id: 124, title: "Downloading", directory: "Indie", flags: 1026).write(to: apps.appendingPathComponent("appmanifest_124.acf"), atomically: true, encoding: .utf8)
        try manifest(id: 125, title: "Unsafe", directory: "../../Elsewhere", flags: 4).write(to: apps.appendingPathComponent("appmanifest_125.acf"), atomically: true, encoding: .utf8)
        var result = ScanResult()
        InstalledGamesScanner(home: root).scanSteam(apps, into: &result)
        XCTAssertEqual(result.games.map(\.steamAppID), [123])
        XCTAssertEqual(result.games.first?.launchURL, "steam://rungameid/123")
        XCTAssertTrue(result.games.first?.isInstalled == true)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.completedSteamApps.isEmpty, "A partially failed scan must not erase old installations")
    }

    func testScanMergesExistingCatalogWithoutChangingID() {
        let originalGame = Game(id: UUID(), title: "Old name", store: .steam, executablePath: "", addedAt: Date(), steamAppID: 123, catalogOwner: steamID)
        var data = LibraryData()
        data.games = [originalGame]
        let found = Game(id: UUID(), title: "New name", store: .steam, executablePath: "", addedAt: Date(), steamAppID: 123,
                         installDirectory: "/Volumes/Games/steamapps/common/Indie", launchURL: "steam://rungameid/123", detectedByScan: true)
        let result = ScanResult(games: [found])
        let merged = LibraryMerge.scan(result, into: data)
        XCTAssertEqual(merged.games.count, 1)
        XCTAssertEqual(merged.games.first?.id, originalGame.id)
        XCTAssertEqual(merged.games.first?.catalogOwner, steamID)
        XCTAssertEqual(merged.games.first?.title, "New name")
        XCTAssertEqual(LibraryMerge.scan(result, into: merged).games.count, 1)
    }

    func testEpicManifestLaunchIdentifierAndIncompleteInstall() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("Indie")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        var json: [String: Any] = ["DisplayName": "Epic Indie", "InstallLocation": game.path, "AppName": "Indie",
                                   "CatalogNamespace": "space", "CatalogItemId": "catalog", "bIsIncompleteInstall": false]
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("installed.item"))
        json["bIsIncompleteInstall"] = true
        json["AppName"] = "NotReady"
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("incomplete.item"))
        var result = ScanResult()
        InstalledGamesScanner(home: root).scanEpic(root, into: &result)
        XCTAssertEqual(result.games.count, 1)
        XCTAssertEqual(result.games.first?.launchURL, "com.epicgames.launcher://apps/space%3Acatalog%3AIndie?action=launch&silent=true")
        XCTAssertEqual(result.games.first?.store, .epic)
        XCTAssertTrue(result.games.first?.isInstalled == true)
    }

    func testSuccessfulScanReconcilesUninstalledGamesButUnreadableRootPreservesThem() {
        let game = Game(id: UUID(), title: "Indie", store: .steam, executablePath: "", addedAt: Date(), steamAppID: 123,
                        installDirectory: "/Volumes/Games/steamapps/common/Indie", launchURL: "steam://rungameid/123", detectedByScan: true, catalogOwner: steamID)
        var data = LibraryData(); data.games = [game]
        XCTAssertEqual(LibraryMerge.scan(ScanResult(), into: data).games.first?.installDirectory, game.installDirectory)
        let result = ScanResult(completedSteamApps: ["/Volumes/Games/steamapps"])
        let updated = LibraryMerge.scan(result, into: data)
        XCTAssertNil(updated.games.first?.installDirectory)
        XCTAssertNil(updated.games.first?.launchURL)
        XCTAssertEqual(updated.games.first?.steamAppID, 123)
        XCTAssertEqual(updated.games.first?.catalogOwner, steamID)
        XCTAssertTrue(LibraryMerge.disconnect(updated).games.isEmpty)
    }

    func testOwnedGamesDecodeDistinguishesEmptyAndPrivate() throws {
        XCTAssertEqual(try SteamAPI.decodeOwnedGames(Data(#"{"response":{"game_count":0}}"#.utf8)).count, 0)
        XCTAssertThrowsError(try SteamAPI.decodeOwnedGames(Data(#"{"response":{}}"#.utf8)))
        XCTAssertThrowsError(try SteamAPI.decodeOwnedGames(Data(#"{"response":{"game_count":2,"games":[{"appid":123}]}}"#.utf8)))
        XCTAssertThrowsError(try SteamAPI.decodeOwnedGames(Data(#"{"response":{"game_count":2,"games":[{"appid":123},{"appid":123}]}}"#.utf8)))
        let games = try SteamAPI.decodeOwnedGames(Data(#"{"response":{"game_count":1,"games":[{"appid":123,"name":"Indie"}]}}"#.utf8))
        XCTAssertEqual(games.first?.name, "Indie")
    }

    func testAccountSwitchAndDisconnectDoNotLeakOldCloudCatalog() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = Game(id: UUID(), title: "Local", store: .steam, executablePath: "", addedAt: Date(), steamAppID: 10,
                         installDirectory: root.path, detectedByScan: true, catalogOwner: steamID)
        let cloud = Game(id: UUID(), title: "Cloud", store: .steam, executablePath: "", addedAt: Date(), steamAppID: 20, catalogOwner: steamID)
        var data = LibraryData(); data.games = [local, cloud]
        data.steamAccount = SteamAccount(steamID: steamID, connectedAt: Date())
        let switched = LibraryMerge.ownedGames([SteamOwnedGame(appid: 30, name: "New account")], owner: "76561198000000001", into: data)
        XCTAssertEqual(Set(switched.games.compactMap(\.steamAppID)), [10, 30])
        XCTAssertNil(switched.games.first(where: { $0.steamAppID == 10 })?.catalogOwner)
        let disconnected = LibraryMerge.disconnect(switched)
        XCTAssertEqual(disconnected.games.map(\.id), [local.id])
        XCTAssertNil(disconnected.steamAccount)
    }

    func testLegacyLibraryMigration() throws {
        let legacy = #"{"schemaVersion":1,"winePath":"/path/wine","games":[{"id":"00000000-0000-0000-0000-000000000001","title":"Legacy","store":"Locale","executablePath":"/tmp/game.exe","addedAt":0}]}"#
        let data = try JSONDecoder().decode(LibraryData.self, from: Data(legacy.utf8))
        XCTAssertEqual(data.games.first?.title, "Legacy")
        XCTAssertNil(data.steamAccount)
        XCTAssertNil(data.games.first?.steamAppID)
        XCTAssertNil(data.extraScanRoots)
    }

    func testOpenIDAcceptsExpectedSignedFieldsBeforeServerVerification() throws {
        let now = Date()
        let expected = URL(string: "http://127.0.0.1:45678/steam/random/callback")!
        let callback = callbackURL(expected: expected, now: now)
        let (id, values) = try SteamOpenID.validate(callback: callback, expectedReturnTo: expected, startedAt: now.addingTimeInterval(-5), now: now)
        XCTAssertEqual(id, steamID)
        XCTAssertEqual(values["openid.mode"], "id_res")
        // A successful local validation is not an authenticated account; the app
        // must still call Steam's check_authentication endpoint.
    }

    func testOpenIDRejectsSpoofingReplayUnsignedIdentityAndDuplicates() {
        let now = Date()
        let expected = URL(string: "http://127.0.0.1:45678/steam/random/callback")!
        let badReturn = callbackURL(expected: expected, now: now, replacing: ["openid.return_to": "http://127.0.0.1:45678/steam/other/callback"])
        XCTAssertThrowsError(try SteamOpenID.validate(callback: badReturn, expectedReturnTo: expected, startedAt: now, now: now))
        let fake = callbackURL(expected: expected, now: now, replacing: ["openid.op_endpoint": "https://attacker.invalid/openid/login"])
        XCTAssertThrowsError(try SteamOpenID.validate(callback: fake, expectedReturnTo: expected, startedAt: now, now: now))
        let unsigned = callbackURL(expected: expected, now: now, replacing: ["openid.signed": "return_to,response_nonce"])
        XCTAssertThrowsError(try SteamOpenID.validate(callback: unsigned, expectedReturnTo: expected, startedAt: now, now: now))
        let old = callbackURL(expected: expected, now: now.addingTimeInterval(-600))
        XCTAssertThrowsError(try SteamOpenID.validate(callback: old, expectedReturnTo: expected, startedAt: now, now: now))
        let duplicate = URL(string: callbackURL(expected: expected, now: now).absoluteString + "&openid.mode=id_res")!
        XCTAssertThrowsError(try SteamOpenID.validate(callback: duplicate, expectedReturnTo: expected, startedAt: now, now: now))
    }

    private func callbackURL(expected: URL, now: Date, replacing: [String: String] = [:]) -> URL {
        var values = [
            "openid.ns": SteamOpenID.namespace, "openid.mode": "id_res",
            "openid.op_endpoint": SteamOpenID.endpoint.absoluteString,
            "openid.claimed_id": "https://steamcommunity.com/openid/id/\(steamID)",
            "openid.identity": "https://steamcommunity.com/openid/id/\(steamID)",
            "openid.return_to": expected.absoluteString,
            "openid.response_nonce": ISO8601DateFormatter().string(from: now) + "uniqueNonce",
            "openid.assoc_handle": "association", "openid.sig": "placeholder-signature",
            "openid.signed": "op_endpoint,claimed_id,identity,return_to,response_nonce,assoc_handle"
        ]
        values.merge(replacing) { _, new in new }
        var components = URLComponents(url: expected, resolvingAgainstBaseURL: false)!
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacGameDockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func manifest(id: Int, title: String, directory: String, flags: Int) -> String {
        "\"AppState\" { \"appid\" \"\(id)\" \"name\" \"\(title)\" \"installdir\" \"\(directory)\" \"StateFlags\" \"\(flags)\" }"
    }
}
