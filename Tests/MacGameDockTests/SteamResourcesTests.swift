import XCTest
@testable import MacGameDock

final class SteamResourcesTests: XCTestCase {
    func testFlatSwiftPMAndPackagedBundle() throws { try check(layout: "Resources") }
    func testStructuredXcodeBundle() throws { try check(layout: "Contents/Resources/Resources") }
    private func check(layout: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(layout)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("SteamRuntime"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("helper-files.json"))
        try Data().write(to: directory.appendingPathComponent("SteamRuntime/DepotDownloader"))
        XCTAssertEqual(try SteamResources.locate(bundleRoots: [root]).path, directory.path)
    }
    func testMissingExecutableDoesNotSelectIncompleteBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("Resources/helper-files.json"))
        XCTAssertThrowsError(try SteamResources.locate(bundleRoots: [root]))
    }
    func testActualPackageIncludesSteamEngine() throws {
        let resources = try SteamResources.current()
        let manifest = try Data(contentsOf: resources.appendingPathComponent("helper-files.json"))
        XCTAssertFalse(try JSONDecoder().decode([String: String].self, from: manifest).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("SteamRuntime/DepotDownloader").path))
    }
}
