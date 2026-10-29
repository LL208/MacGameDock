import XCTest
@testable import MacGameDock

final class GameDetailMetadataTests: XCTestCase {
    func testDescriptionAndLocalModesAreDecodedWithoutInventingPlayerLimits() throws {
        let bytes = Data(#"{"10":{"success":true,"data":{"platforms":{"windows":true},"short_description":"A &amp; B<br>Co-op &quot;game&quot;","developers":["Studio"],"genres":[{"description":"Action"}],"categories":[{"id":2},{"id":39},{"id":24}]}}}"#.utf8)
        let value = try GameInsights.decode(bytes, appID: 10)
        XCTAssertTrue(value.description.contains("A & B\nCo-op \"game\""))
        XCTAssertEqual(value.localCoop, true); XCTAssertEqual(value.localSharedScreen, true)
        XCTAssertEqual(value.singlePlayer, true); XCTAssertEqual(value.onlineMultiplayer, false)
        XCTAssertEqual(value.developers, ["Studio"])
        let missing = try GameInsights.decode(Data(#"{"10":{"success":true,"data":{"platforms":{"windows":true}}}}"#.utf8), appID: 10)
        XCTAssertNil(missing.localSharedScreen); XCTAssertNil(missing.localCoop)
    }
    func testCurrentPlayerCountDistinguishesZeroFromUnavailable() throws {
        XCTAssertEqual(try CurrentPlayers.decode(Data(#"{"response":{"result":1,"player_count":0}}"#.utf8)).count, 0)
        for text in [#"{"response":{"result":42,"player_count":50}}"#, #"{"response":{"result":1}}"#, #"{"response":{"result":1,"player_count":-1}}"#] { XCTAssertThrowsError(try CurrentPlayers.decode(Data(text.utf8))) }
    }
}
@MainActor
final class GameDetailLoadingTests: XCTestCase {
    private func snapshot(_ app: Int, owner: String) -> SteamAchievementSnapshot {
        SteamAchievementSnapshot(steamID: owner, appID: app, achievements: [SteamAchievement(name: "earned-\(app)", title: "First", description: "Earn it", icon: nil, iconGray: nil, hidden: false, unlocked: true, unlockTime: 100, statID: 1, bit: 0)], stats: [])
    }
    private func game(_ app: Int) -> Game { Game(id: UUID(), title: "Test", store: .steam, executablePath: "", addedAt: Date(), steamAppID: app) }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<100 { if condition() { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Detail did not finish loading")
    }
    func testAutomaticTrophiesAndPlayerCountSurviveMetadataFailureAndCacheIsAccountScoped() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let model = GameDetailModel(metadata: { _ in throw URLError(.notConnectedToInternet) }, playerCount: { _ in CurrentPlayers(count: 12, date: Date()) })
        let value = game(10), result = snapshot(10, owner: "owner-a")
        model.load(game: value, owner: "owner-a", root: root) { result }
        await settle { !model.metadataLoading && !model.trophiesLoading && model.players != nil }
        XCTAssertTrue(model.trophiesLoaded); XCTAssertEqual(model.unlocked, 1); XCTAssertEqual(model.players?.count, 12)
        XCTAssertNil(model.insights)
        model.load(game: value, owner: "owner-b", root: root, cached: result) { throw URLError(.notConnectedToInternet) }
        XCTAssertFalse(model.trophiesLoaded); XCTAssertTrue(model.trophies.isEmpty)
        await settle { !model.trophiesLoading }
        model.accept(result)
        XCTAssertTrue(model.trophies.isEmpty, "Another account's live snapshot must be ignored")
        model.load(game: value, owner: "owner-a", root: root) { throw URLError(.notConnectedToInternet) }
        XCTAssertTrue(model.trophiesLoaded, "Previously loaded trophies must be visible immediately offline")
        XCTAssertEqual(model.unlocked, 1)
        await settle { !model.trophiesLoading }
        XCTAssertEqual(model.unlocked, 1)
        model.cancel()
    }
    func testNavigatingToAnotherGameDropsLateResponses() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let model = GameDetailModel(metadata: { app in
            if app == 10 { try? await Task.sleep(nanoseconds: 150_000_000) }
            var info = GameInsights(macAvailable: false, windowsAvailable: true, macRequirements: "", windowsRequirements: ""); info.description = String(app); return info
        }, playerCount: { app in CurrentPlayers(count: app, date: Date()) })
        let first = snapshot(10, owner: "owner"), second = snapshot(20, owner: "owner")
        model.load(game: game(10), owner: "owner", root: root) { try? await Task.sleep(nanoseconds: 150_000_000); return first }
        let secondGame = game(20)
        model.load(game: secondGame, owner: "owner", root: root) { second }
        await settle { model.insights?.description == "20" && model.trophiesLoaded }
        try? await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(model.insights?.description, "20"); XCTAssertEqual(model.players?.count, 20)
        XCTAssertEqual(model.gameID, secondGame.id); XCTAssertEqual(model.unlocked, 1)
        XCTAssertEqual(model.trophies.first?.name, "earned-20")
        model.cancel()
    }
}
