import XCTest
@testable import MacGameDock

final class SteamCloudPlanTests: XCTestCase {
    private func version(_ hash: String?) -> CloudSaveVersion { CloudSaveVersion(hash: hash) }
    func testBothModifiedAndInitialDifferentCopiesAreConflicts() throws {
        XCTAssertEqual(try SteamCloudPlan.compare(local: ["save": version("local")], remote: ["save": version("remote")], baseline: ["save": version("base")]).first?.action, .conflict)
        XCTAssertEqual(try SteamCloudPlan.compare(local: ["save": version("local")], remote: ["save": version("remote")], baseline: [:]).first?.action, .conflict)
    }
    func testOnlyChangedSideWinsAndMatchingContentNeedsNoTransfer() throws {
        XCTAssertEqual(try SteamCloudPlan.compare(local: ["save": version("new")], remote: ["save": version("old")], baseline: ["save": version("old")]).first?.action, .upload)
        XCTAssertEqual(try SteamCloudPlan.compare(local: ["save": version("old")], remote: ["save": version("new")], baseline: ["save": version("old")]).first?.action, .download)
        XCTAssertEqual(try SteamCloudPlan.compare(local: ["save": version("same")], remote: ["save": version("same")], baseline: [:]).first?.action, .unchanged)
    }
    func testDeletionIsNeverAutomaticallyPropagated() throws {
        XCTAssertEqual(try SteamCloudPlan.compare(local: [:], remote: ["save": version("old")], baseline: ["save": version("old")]).first?.action, .conflict)
        XCTAssertEqual(try SteamCloudPlan.compare(local: ["save": version("old")], remote: [:], baseline: ["save": version("old")]).first?.action, .conflict)
        XCTAssertEqual(try SteamCloudPlan.compare(local: ["save": version("new")], remote: [:], baseline: ["save": version(nil)]).first?.action, .upload)
    }
    func testInventoriesAreBoundToAccountGameAndFullSnapshot() throws {
        let data = Data(#"{"schemaVersion":1,"steamID":"account","appID":10,"changeNumber":"9","isDelta":false,"prefixes":["%WinAppDataRoaming%"],"files":[{"name":"Game/save.dat","sha1":"0123456789012345678901234567890123456789","size":10,"timestamp":1,"state":0,"prefixIndex":0}]}"#.utf8)
        let inventory = try JSONDecoder().decode(SteamCloudInventory.self, from: data)
        try inventory.validate(expectedAccount: "account", expectedAppID: 10)
        XCTAssertThrowsError(try inventory.validate(expectedAccount: "other", expectedAppID: 10))
        XCTAssertThrowsError(try inventory.validate(expectedAccount: "account", expectedAppID: 20))
        let delta = try JSONDecoder().decode(SteamCloudInventory.self, from: Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"isDelta\":false", with: "\"isDelta\":true").utf8))
        XCTAssertThrowsError(try delta.validate(expectedAccount: "account", expectedAppID: 10))
    }
    func testRemotePathsCannotEscapeTheMapping() throws {
        for path in ["../save", "C:/save", "/save", "%Root%/../save", "save\0.dat"] { XCTAssertThrowsError(try SteamCloudInventory.safeName(path)) }
        XCTAssertEqual(try SteamCloudInventory.safeName("%WinAppDataRoaming%Game/save.dat"), "%WinAppDataRoaming%Game/save.dat")
    }
    func testCloudErrorsDoNotSuggestRedownloadingGames() {
        for code in ["partial_inventory", "steam_AccessDenied", "steam_NoMatch", "steam_Timeout", "engine_error"] {
            let message = SteamCloudDiagnostic.message(code: code, errorType: "NotImplementedException")
            XCTAssertTrue(message.contains("Nessun salvataggio"))
            XCTAssertFalse(message.contains("download"))
        }
        XCTAssertTrue(SteamCloudDiagnostic.message(code: "steam_AccessDenied").contains("non ha autorizzato"))
        XCTAssertFalse(SteamCloudDiagnostic.message(code: "engine_error", errorType: "https://private.example/token").contains("private.example"))
    }

}
