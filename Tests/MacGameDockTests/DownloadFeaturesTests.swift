import XCTest
@testable import MacGameDock

@MainActor
final class DownloadFeaturesTests: XCTestCase {
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func game(_ title: String = "Test") -> Game {
        Game(id: UUID(), title: title, store: .steam, executablePath: "", addedAt: Date(), steamAppID: 2851700)
    }
    func testSessionSurvivesRestartAndHasPrivatePermissions() throws {
        let directory = try root()
        let session = SteamSession(steamID: "76561198000000000", username: "fixture", account: Data("token-fixture".utf8))
        try SessionStore.save(session, root: directory)
        XCTAssertEqual(try SessionStore.read(root: directory)?.account, session.account)
        let attrs = try FileManager.default.attributesOfItem(atPath: SessionStore.location(root: directory).path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let parent = try FileManager.default.attributesOfItem(atPath: SessionStore.location(root: directory).deletingLastPathComponent().path)
        XCTAssertEqual((parent[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try SessionStore.delete(root: directory)
        XCTAssertNil(try SessionStore.read(root: directory))
    }
    func testRememberedSessionIsPassedToNextDownloadWithoutQR() async throws {
        let directory = try root()
        let script = directory.appendingPathComponent("helper")
        let text = #"""
        #!/bin/sh
        if [ ! -s account.config ]; then exit 9; fi
        for arg in "$@"; do
          if [ "$arg" = "-qr" ]; then exit 8; fi
        done
        printf '%s\n' 'MACGAMEDECK_EVENT:{"type":"account","steamID":"76561198000000000","username":"fixture"}'
        """#
        try Data(text.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try SessionStore.save(SteamSession(steamID: "76561198000000000", username: "fixture", account: Data("fixture".utf8)), root: directory)
        let first = ManagedSteam(root: directory, helperProvider: { script })
        let firstID = try await first.run([], expected: "76561198000000000")
        XCTAssertEqual(firstID, "76561198000000000")
        // A fresh instance models relaunching the application.
        let second = ManagedSteam(root: directory, helperProvider: { script })
        let secondID = try await second.run([], expected: "76561198000000000")
        XCTAssertEqual(secondID, "76561198000000000")
        let sessions = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Sessions"), includingPropertiesForKeys: nil)
        XCTAssertTrue(sessions.isEmpty)
    }
    func testLoginIsRememberedEvenWhenDownloadIsPausedBeforeCompletion() async throws {
        let directory = try root()
        let script = directory.appendingPathComponent("helper.py")
        let text = #"""
        #!/usr/bin/python3
        import pathlib, sys, time
        if '--cache-only' in sys.argv:
            if '-qr' in sys.argv or not pathlib.Path('account.config').exists(): sys.exit(8)
        else:
            pathlib.Path('account.config').write_bytes(b'fixture-session')
        print('MACGAMEDECK_EVENT:{"type":"account","steamID":"76561198000000000","username":"fixture"}', flush=True)
        if '--cache-only' not in sys.argv:
            time.sleep(60)
        """#
        try Data(text.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let steam = ManagedSteam(root: directory, helperProvider: { script })
        let operation = Task { try await steam.run([], expected: nil) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: SessionStore.location(root: directory).path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(try SessionStore.read(root: directory))
        steam.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let restarted = ManagedSteam(root: directory, helperProvider: { script })
        let id = try await restarted.run(["--cache-only"], expected: "76561198000000000")
        XCTAssertEqual(id, "76561198000000000")
    }
    func testIdentityWithoutSessionCannotBeReportedAsCompleteLogin() async throws {
        let directory = try root()
        let script = directory.appendingPathComponent("identity-only")
        let text = #"""
        #!/bin/sh
        printf '%s\n' 'MACGAMEDECK_EVENT:{"type":"account","steamID":"76561198000000000","username":"fixture"}'
        """#
        try Data(text.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let steam = ManagedSteam(root: directory, helperProvider: { script })
        XCTAssertFalse(steam.hasSavedSession)
        do { _ = try await steam.run([], expected: nil); XCTFail("Identity must not substitute for a saved download session") }
        catch { XCTAssertTrue(error.localizedDescription.contains("non ha salvato la sessione")) }
        XCTAssertFalse(steam.hasSavedSession)
        XCTAssertNil(try SessionStore.read(root: directory))
    }
    func testWrongAccountCannotUseRememberedSession() async throws {
        let directory = try root()
        try SessionStore.save(SteamSession(steamID: "76561198000000000", username: "fixture", account: Data("fixture".utf8)), root: directory)
        let steam = ManagedSteam(root: directory, helperProvider: { URL(fileURLWithPath: "/usr/bin/false") })
        do { _ = try await steam.run([], expected: "76561198000000001"); XCTFail("Must reject account mismatch") }
        catch { XCTAssertTrue(error.localizedDescription.contains("altro account")) }
    }
    func testQueueRunsSeriallyAndAdvancesAfterPause() async throws {
        let directory = try root(), first = game("First"), second = game("Second")
        let started = expectation(description: "first running"), finished = expectation(description: "second finished")
        var active = 0, maximumActive = 0, interrupts = 0
        let queue = DownloadQueue(root: directory, runner: { job in
            active += 1; maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            if job.game.id == first.id {
                started.fulfill()
                while true { try await Task.sleep(nanoseconds: 10_000_000) }
            } else { finished.fulfill() }
        }, interrupt: { interrupts += 1 })
        queue.enqueue(first, platform: .windows, accountID: nil)
        queue.enqueue(second, platform: .macOS, accountID: nil)
        await fulfillment(of: [started], timeout: 2)
        queue.pause(queue.jobs[0].id)
        await fulfillment(of: [finished], timeout: 2)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(maximumActive, 1)
        XCTAssertEqual(interrupts, 1)
        XCTAssertEqual(queue.jobs[0].state, .paused)
        XCTAssertEqual(queue.jobs[1].state, .completed)
        let restored = DownloadQueue(root: directory, runner: { _ in XCTFail("Must not automatically resume after restart") }, interrupt: {})
        XCTAssertEqual(restored.jobs.map(\.state), [.paused, .completed])
    }
    func testQueueDeduplicatesAndRecoversInterruptedJobAsPaused() throws {
        let directory = try root(), item = game()
        let job = DownloadJob(id: UUID(), game: item, platform: .macOS, accountID: nil, state: .active, createdAt: Date())
        try JSONEncoder().encode([job]).write(to: directory.appendingPathComponent("downloads.json"))
        let queue = DownloadQueue(root: directory, runner: { _ in XCTFail("Must await user resume") }, interrupt: {})
        XCTAssertEqual(queue.jobs[0].state, .paused)
        queue.enqueue(item, platform: .windows, accountID: nil)
        XCTAssertEqual(queue.jobs.count, 1)
    }
    func testNativeMetadataSelectsAppWithoutWine() throws {
        let directory = try root()
        let app = directory.appendingPathComponent("Native.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let bytes = Data(#"{"appID":1,"launches":[{"executable":"windows.exe","oslist":"windows"},{"executable":"Native.app","oslist":"macos"}]}"#.utf8)
        let metadata = try JSONDecoder().decode(DeckMetadata.self, from: bytes)
        let (selected, _, _) = try metadata.select(in: directory, platform: .macOS)
        XCTAssertEqual(selected.path, app.path)
        XCTAssertThrowsError(try metadata.select(in: directory, platform: .windows))
    }
    func testFamilyMetadataMergesWithoutDuplicateAndRemovesStaleSharedEntries() throws {
        let json = Data(#"[{"appid":1,"name":"Own","platforms":["windows","macos"],"familyOwners":[]},{"appid":2,"name":"Shared","familyOwners":["76561198000000001"]}]"#.utf8)
        let games = try JSONDecoder().decode([SteamOwnedGame].self, from: json)
        let result = LibraryMerge.ownedGames(games, owner: "76561198000000000", into: LibraryData())
        XCTAssertFalse(result.games[0].isFamilyShared)
        XCTAssertTrue(result.games[1].isFamilyShared)
        XCTAssertEqual(result.games[0].platforms, ["windows", "macos"])
        let again = LibraryMerge.ownedGames(games, owner: "76561198000000000", into: result)
        XCTAssertEqual(again.games.count, 2)
        XCTAssertEqual(again.games[1].id, result.games[1].id)
        XCTAssertEqual(LibraryMerge.ownedGames([games[0]], owner: "76561198000000000", into: again).games.count, 1)
    }
    func testRequirementsEstimateHandlesMBAndMissingDataWithoutInventedFPS() throws {
        let bytes = Data(#"{"1":{"success":true,"data":{"platforms":{"mac":true,"windows":true},"mac_requirements":{"minimum":"<strong>Memory:</strong> 512 MB RAM"},"pc_requirements":{"minimum":"<ul><li><strong>Memory:</strong> 4 GB RAM</li><li><strong>Graphics:</strong> GTX 960</li><li><strong>DirectX:</strong> Version 11</li></ul>"}}}}"#.utf8)
        let details = try GameInsights.decode(bytes, appID: 1)
        XCTAssertTrue(details.macAvailable)
        XCTAssertEqual(details.minimumRAM(for: .macOS), 1)
        XCTAssertEqual(details.minimumRAM(for: .windows), 4)
        XCTAssertEqual(details.requirement("Graphics", for: .windows), "GTX 960")
        XCTAssertEqual(details.requirement("DirectX", for: .windows), "Version 11")
        let machine = Machine(chip: "M1", memoryGB: 8, gpu: "M1", macOS: "15", architecture: "Apple Silicon")
        let estimate = PerformanceEstimate(machine: machine, platform: .windows, insights: details)
        XCTAssertEqual(estimate.suggestedRAM, 6)
        XCTAssertTrue(estimate.memoryStatus.contains("limite"))
        XCTAssertNil(PerformanceEstimate(machine: machine, platform: .windows, insights: nil).suggestedRAM)
    }
}
