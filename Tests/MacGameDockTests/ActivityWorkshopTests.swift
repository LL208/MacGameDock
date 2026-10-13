import XCTest
@testable import MacGameDock

final class ActivityWorkshopTests: XCTestCase {
    @MainActor
    func testCheckpointRestartAndDuplicateLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = 100.0
        let activity = PlayActivity(root: root, uptime: { now }, automaticCheckpoint: false)
        let game = Game(id: UUID(), title: "Test", store: .local, executablePath: "/test.exe", addedAt: Date())
        activity.start(game); now = 120; activity.start(game); now = 160; activity.checkpoint()
        XCTAssertEqual(activity.seconds[game.identity], 60)
        now = 190; activity.stop(game); now = 250; activity.checkpoint()
        XCTAssertEqual(activity.seconds[game.identity], 90)
        let restarted = PlayActivity(root: root, uptime: { now }, automaticCheckpoint: false)
        now = 500; restarted.checkpoint()
        XCTAssertEqual(restarted.seconds[game.identity], 90)
    }
    @MainActor
    func testCorruptPlaytimePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("playtime.json"), bytes = Data("broken".utf8)
        try bytes.write(to: file)
        let activity = PlayActivity(root: root, automaticCheckpoint: false)
        activity.checkpoint()
        XCTAssertNotNil(activity.storageError)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testWorkshopLinksAndInvalidIDs() throws {
        XCTAssertEqual(try WorkshopInput.itemID("https://steamcommunity.com/sharedfiles/filedetails/?id=123&searchtext=test"), "123")
        XCTAssertEqual(try WorkshopInput.itemID(" 456 "), "456")
        for value in ["0", "-1", "123; rm", "https://evil.test/sharedfiles/filedetails/?id=123", "https://steamcommunity.com/app/123", "18446744073709551616"] {
            XCTAssertThrowsError(try WorkshopInput.itemID(value))
        }
    }
    func testWorkshopRejectsOtherGameCollectionAndTraversal() throws {
        func item(_ app: Int, _ type: Int, _ filename: String = "mod.zip") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["response": ["publishedfiledetails": [["publishedfileid": "123", "result": 1, "consumer_app_id": app, "file_type": type, "title": "Mod", "filename": filename]]]])
        }
        XCTAssertEqual(try WorkshopInput.validate(item(10, 0), appID: 10, itemID: "123"), "Mod")
        XCTAssertThrowsError(try WorkshopInput.validate(item(20, 0), appID: 10, itemID: "123"))
        XCTAssertThrowsError(try WorkshopInput.validate(item(10, 2), appID: 10, itemID: "123"))
        XCTAssertThrowsError(try WorkshopInput.validate(item(10, 0, "../../outside"), appID: 10, itemID: "123"))
    }
}
