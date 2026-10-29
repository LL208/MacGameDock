import XCTest
@testable import MacGameDock

final class GameSessionTests: XCTestCase {
    func testFullscreenSurfaceAboveNormalWindowLevelCanReceiveFocus() {
        XCTAssertTrue(GameWindowPlacement.isGameSurface(layer: 3, width: 1920, height: 1080))
        XCTAssertTrue(GameWindowPlacement.isGameSurface(layer: 0, width: 1280, height: 720))
        XCTAssertFalse(GameWindowPlacement.isGameSurface(layer: -1, width: 1920, height: 1080))
        XCTAssertFalse(GameWindowPlacement.isGameSurface(layer: 0, width: 64, height: 64))
    }
    func testPlacementUsesUpperAndLeftDisplaysWithNegativeCoordinates() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(GameWindowPlacement.frame(size: CGSize(width: 1280, height: 720), visible: left, primaryTop: 1080), CGRect(x: -1600, y: 180, width: 1280, height: 720))
        let upper = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        XCTAssertEqual(GameWindowPlacement.frame(size: CGSize(width: 1280, height: 720), visible: upper, primaryTop: 1080).origin.y, -900)
    }
    func testLargeWindowFitsVisibleArea() {
        let area = CGRect(x: 1920, y: 30, width: 1440, height: 870)
        let result = GameWindowPlacement.frame(size: CGSize(width: 3840, height: 2160), visible: area, primaryTop: 1080)
        XCTAssertEqual(result.size, CGSize(width: 1440, height: 810))
        XCTAssertEqual(result.origin, CGPoint(x: 1920, y: 210))
    }
    func testDescendantDiscoveryNeverSelectsOtherGameOrServer() {
        let parents: [Int32: Int32] = [101: 100, 102: 101, 103: 102, 200: 1, 201: 200, 300: 1]
        XCTAssertEqual(GameWindowPlacement.descendants(of: [100], parents: parents), [100, 101, 102, 103])
    }
    func testHomeIsEdgeTriggeredAndMenuRequiresDeliberateHold() {
        var gesture = DeckHomeGesture()
        XCTAssertTrue(gesture.poll(home: true, menu: false, eligible: true, now: 0))
        XCTAssertFalse(gesture.poll(home: true, menu: false, eligible: true, now: 2))
        XCTAssertFalse(gesture.poll(home: false, menu: true, eligible: true, now: 3))
        XCTAssertFalse(gesture.poll(home: false, menu: true, eligible: true, now: 4))
        XCTAssertTrue(gesture.poll(home: false, menu: true, eligible: true, now: 4.3))
        XCTAssertFalse(gesture.poll(home: false, menu: true, eligible: true, now: 6))
        XCTAssertFalse(gesture.poll(home: false, menu: false, eligible: true, now: 7))
        XCTAssertTrue(gesture.poll(home: true, menu: false, eligible: true, now: 8))
    }
    func testHeldGameplayButtonsDoNotActivateMenuActionsUntilReleased() {
        var input = DeckInputRepeater()
        input.reset([.confirm, .menu])
        XCTAssertTrue(input.poll([.confirm, .menu], now: 10).isEmpty)
        XCTAssertTrue(input.poll([], now: 11).isEmpty)
        XCTAssertEqual(input.poll([.confirm], now: 12), [.confirm])
    }
    func testMenuDoesNotOpenDuringNormalLibraryUse() {
        var gesture = DeckHomeGesture()
        XCTAssertFalse(gesture.poll(home: false, menu: true, eligible: false, now: 0))
        XCTAssertFalse(gesture.poll(home: false, menu: true, eligible: false, now: 3))
        XCTAssertFalse(gesture.poll(home: false, menu: true, eligible: true, now: 4))
        XCTAssertFalse(gesture.poll(home: false, menu: false, eligible: true, now: 4.5))
        XCTAssertFalse(gesture.poll(home: false, menu: true, eligible: true, now: 5))
        XCTAssertTrue(gesture.poll(home: false, menu: true, eligible: true, now: 6.3))
    }
}
