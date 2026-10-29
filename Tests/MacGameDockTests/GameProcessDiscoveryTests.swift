import XCTest
@testable import MacGameDock

final class GameProcessDiscoveryTests: XCTestCase {
    func testProcessArgumentsDecodeKeepsOnlyWinePrefix() throws {
        var count: Int32 = 3
        var bytes = withUnsafeBytes(of: &count) { Data($0) }
        bytes.append(Data("/runtime/wine64-preloader\0\0\0wine64\0C:\\Games\\Sektori.exe\0-windowed\0TOKEN=do-not-retain\0WINEPREFIX=/containers/one\0OTHER=ignored\0\0".utf8))
        let result = try XCTUnwrap(GameProcessArguments.decode(bytes))
        XCTAssertEqual(result.executable, "/runtime/wine64-preloader")
        XCTAssertEqual(result.arguments, ["wine64", "C:\\Games\\Sektori.exe", "-windowed"])
        XCTAssertEqual(result.winePrefix, "/containers/one")
        XCTAssertNil(GameProcessArguments.decode(Data([0,0,0,0])))
        XCTAssertNil(GameProcessArguments.decode(bytes.prefix(12)))
    }
    func testReparentedWineWindowMatchesExactContainerAndWindowsPath() {
        let args = GameProcessArguments(executable: "/runtime/wine64-preloader", arguments: ["C:\\Games\\Sektori.exe"], winePrefix: "/containers/one")
        XCTAssertTrue(args.matches(prefix: "/containers/one", executable: "/containers/one/drive_c/Games/Sektori.exe"))
        XCTAssertFalse(args.matches(prefix: "/containers/two", executable: "/containers/one/drive_c/Games/Sektori.exe"))
        XCTAssertFalse(args.matches(prefix: "/containers/one", executable: "/containers/one/drive_c/Games/Another.exe"))
    }
    func testZDriveAndBasenameMatchWithoutAdmittingOtherPrograms() {
        let args = GameProcessArguments(executable: "/runtime/wine64-preloader", arguments: ["Z:\\Users\\fixture\\Game.exe"], winePrefix: "/containers/one")
        XCTAssertTrue(args.matches(prefix: "/containers/one", executable: "/Users/fixture/Game.exe"))
        XCTAssertFalse(GameProcessArguments(executable: "/runtime/wineserver", arguments: args.arguments, winePrefix: args.winePrefix).matches(prefix: "/containers/one", executable: "/Users/fixture/Game.exe"))
        XCTAssertFalse(GameProcessArguments(executable: "/usr/bin/other", arguments: args.arguments, winePrefix: args.winePrefix).matches(prefix: "/containers/one", executable: "/Users/fixture/Game.exe"))
        XCTAssertFalse(GameProcessArguments(executable: args.executable, arguments: args.arguments, winePrefix: nil).matches(prefix: "/containers/one", executable: "/Users/fixture/Game.exe"))
        XCTAssertTrue(GameProcessArguments(executable: args.executable, arguments: ["Game.exe"], winePrefix: args.winePrefix).matches(prefix: "/containers/one", executable: "/Users/fixture/Game.exe"))
    }
    func testFocusMustRemainContinuousAndSplashReplacementResetsIt() {
        var state = GameFocusStability()
        XCTAssertFalse(state.observe(window: 10, isFront: true, now: 0))
        XCTAssertFalse(state.observe(window: 10, isFront: false, now: 2))
        XCTAssertFalse(state.observe(window: 10, isFront: true, now: 3))
        XCTAssertFalse(state.observe(window: 11, isFront: true, now: 5))
        XCTAssertFalse(state.observe(window: 11, isFront: true, now: 7))
        XCTAssertTrue(state.observe(window: 11, isFront: true, now: 7.6))
    }
}
