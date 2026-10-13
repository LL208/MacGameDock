import XCTest
@testable import MacGameDock

final class WineReadinessTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testWaitsForDelayedRegistryFilesAfterKernelAppears() async throws {
        let root = try directory()
        let kernel = root.appendingPathComponent("drive_c/windows/system32/kernel32.dll")
        try FileManager.default.createDirectory(at: kernel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: kernel)
        let writer = Task {
            try await Task.sleep(nanoseconds: 100_000_000)
            try Data().write(to: root.appendingPathComponent("system.reg"))
            try await Task.sleep(nanoseconds: 100_000_000)
            try Data().write(to: root.appendingPathComponent("user.reg"))
        }
        defer { writer.cancel() }
        try await WineRuntime.waitUntilReady(prefix: root, timeout: 2, pollInterval: 10_000_000)
        try WineRuntime.validate(prefix: root)
        try await writer.value
    }
    func testTimeoutIdentifiesMissingFilesAndPreservesGame() async throws {
        let root = try directory()
        let game = root.appendingPathComponent("game.exe")
        try Data("game".utf8).write(to: game)
        do {
            try await WineRuntime.waitUntilReady(prefix: root, timeout: 0, pollInterval: 1)
            XCTFail("An empty prefix cannot become ready")
        } catch { XCTAssertTrue(error.localizedDescription.contains("system.reg")); XCTAssertTrue(error.localizedDescription.contains("kernel32.dll")) }
        XCTAssertEqual(try Data(contentsOf: game), Data("game".utf8))
    }
    func testReadinessWaitCanBeCancelled() async throws {
        let root = try directory()
        let task = Task { try await WineRuntime.waitUntilReady(prefix: root, timeout: 2, pollInterval: 10_000_000) }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
