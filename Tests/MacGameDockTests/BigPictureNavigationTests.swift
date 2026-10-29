import XCTest
@testable import MacGameDock

final class BigPictureInputTests: XCTestCase {
    func testSwappingOnlyExchangesConfirmAndBackAndKeepsOtherCommands() {
        for command in DeckCommand.allCases {
            XCTAssertEqual(DeckButtonMapping.face(command, swapped: false), command)
            let mapped = DeckButtonMapping.face(command, swapped: true)
            XCTAssertEqual(mapped, command == .confirm ? .back : command == .back ? .confirm : command)
            XCTAssertEqual(DeckButtonMapping.face(mapped, swapped: true), command)
        }
    }
    func testOldPreferencesDecodeAndSwappedChoiceSurvivesRoundTrip() throws {
        let old = Data(#"{"theme":"Sistema","resumeDownloads":false,"pauseWhilePlaying":false,"largeInterface":false,"onboardingComplete":false}"#.utf8)
        var prefs = try JSONDecoder().decode(DeckPreferences.self, from: old)
        XCTAssertNil(prefs.swapControllerConfirmBack)
        prefs.swapControllerConfirmBack = true
        let saved = try JSONDecoder().decode(DeckPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(saved.swapControllerConfirmBack, true)
    }
    func testFaceButtonsAreEdgesAndOnlyDirectionsRepeat() {
        var input = DeckInputRepeater()
        XCTAssertEqual(input.poll([.confirm, .right], now: 0), [.right, .confirm])
        XCTAssertEqual(input.poll([.confirm, .right], now: 0.2), [])
        XCTAssertEqual(input.poll([.confirm, .right], now: 0.39), [.right])
        XCTAssertEqual(input.poll([.confirm, .right], now: 0.42), [])
        XCTAssertEqual(input.poll([.confirm, .right], now: 0.51), [.right])
        XCTAssertEqual(input.poll([], now: 0.6), [])
        XCTAssertEqual(input.poll([.confirm], now: 0.7), [.confirm])
        XCTAssertEqual(input.poll([.confirm], now: 100), [])
    }
    func testReconnectAndBackgroundResetDoNotActivateHeldButtons() {
        var input = DeckInputRepeater()
        input.reset([.confirm, .menu])
        XCTAssertEqual(input.poll([.confirm, .menu], now: 1), [])
        _ = input.poll([], now: 2)
        XCTAssertEqual(input.poll([.menu], now: 3), [.menu])
    }
    func testDiagonalProducesOneDeterministicDirectionAndRepeatDoesNotFlood() {
        var input = DeckInputRepeater()
        XCTAssertEqual(input.poll([.left, .up], now: 0), [.up])
        XCTAssertEqual(input.poll([.left, .up], now: 20), [.up])
    }
    func testFocusCrossesTabsFiltersGamesAndPaginationWithDifferentRowWidths() {
        let counts = [7, 8, 7, 2], widths = [7, 4, 3, 2]
        XCTAssertEqual(DeckFocusNavigation.moveSections(.up, current: 7, counts: counts, columns: widths), 0)
        XCTAssertEqual(DeckFocusNavigation.moveSections(.down, current: 11, counts: counts, columns: widths), 15)
        XCTAssertEqual(DeckFocusNavigation.moveSections(.up, current: 15, counts: counts, columns: widths), 11)
        XCTAssertEqual(DeckFocusNavigation.moveSections(.down, current: 14, counts: counts, columns: widths), 17)
        XCTAssertEqual(DeckFocusNavigation.moveSections(.down, current: 21, counts: counts, columns: widths), 22)
        XCTAssertEqual(DeckFocusNavigation.moveSections(.up, current: 22, counts: counts, columns: widths), 21)
        XCTAssertEqual(DeckFocusNavigation.moveSections(.down, current: 11, counts: [7, 8, 0, 2], columns: widths), 15)
        XCTAssertEqual(DeckFocusNavigation.moveSections(.down, current: 0, counts: [], columns: []), 0)
    }
    func testFocusClampsAtEdgesAndHandlesAnIncompleteGridRow() {
        XCTAssertEqual(DeckFocusNavigation.move(.left, current: 0, count: 11, columns: 4), 0)
        XCTAssertEqual(DeckFocusNavigation.move(.down, current: 7, count: 11, columns: 4), 10)
        XCTAssertEqual(DeckFocusNavigation.move(.up, current: 10, count: 11, columns: 4), 6)
        XCTAssertEqual(DeckFocusNavigation.move(.right, current: 10, count: 11, columns: 4), 10)
        XCTAssertEqual(DeckFocusNavigation.move(.down, current: 2, count: 0, columns: 0), 0)
    }
}
@MainActor
final class BigPicturePageTests: XCTestCase {
    func testBackPreservesLibraryPageAndFocusAndDismissesKeyboardFirst() {
        let model = BigPictureModel()
        model.navigate(.library)
        model.pageNumber = 3; model.selected[DeckPage.library.key] = "last-game"
        model.navigate(.game(UUID()))
        model.keyboard = DeckKeyboard(title: "Cerca", text: "") { _ in XCTFail("Back must not submit") }
        model.back()
        XCTAssertNil(model.keyboard)
        XCTAssertNotEqual(model.page, .library)
        model.back()
        XCTAssertEqual(model.page, .library)
        XCTAssertEqual(model.pageNumber, 3)
        XCTAssertEqual(model.selected[DeckPage.library.key], "last-game")
    }
    func testDestructiveConfirmationStartsOnCancelAndBackDoesNotRunAction() {
        let model = BigPictureModel(); var changed = false
        model.ask("Disinstallare?") { changed = true }
        XCTAssertEqual(model.selected["dialog"], "cancel")
        model.back()
        XCTAssertNil(model.confirmation)
        XCTAssertFalse(changed)
    }
    func testInterfaceChoicePersistsAcrossRelaunches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = GameExperience(root: root)
        first.settings { $0.bigPicture = false }
        let second = GameExperience(root: root)
        XCTAssertEqual(second.preferences.bigPicture, false)
        second.settings { $0.bigPicture = true }
        XCTAssertEqual(GameExperience(root: root).preferences.bigPicture, true)
    }
    func testAllRootSectionsAreReachableWithoutPointerAndWrapAround() {
        let model = BigPictureModel()
        var visited: Set<String> = []
        for _ in DeckPage.sections { visited.insert(model.page.key); model.section(1) }
        XCTAssertEqual(visited.count, DeckPage.sections.count)
        XCTAssertEqual(model.page, .home)
        model.section(-1)
        XCTAssertEqual(model.page, .logs)
    }
}
