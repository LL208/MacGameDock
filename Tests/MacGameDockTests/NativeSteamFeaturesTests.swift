import XCTest
@testable import MacGameDock

@MainActor
final class NativeSteamFeaturesTests: XCTestCase {
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func game(_ root: URL) -> Game { Game(id: UUID(), title: "Fixture", store: .steam, executablePath: root.appendingPathComponent("game.exe").path, addedAt: Date(), steamAppID: 10, installDirectory: root.appendingPathComponent("Game").path, managedLaunch: ManagedLaunch(prefix: root.appendingPathComponent("Prefix").path, arguments: [], workingDirectory: root.path, platform: .windows)) }
    func snapshot() -> SteamAchievementSnapshot {
        SteamAchievementSnapshot(steamID: "76561198000000000", appID: 10, achievements: [
            SteamAchievement(name: "REAL_EVENT", title: "Real event", description: "Fixture", icon: nil, iconGray: nil, hidden: false, unlocked: false, unlockTime: 0, statID: 1, bit: 0),
            SteamAchievement(name: "ALREADY_EARNED", title: "Old", description: "Fixture", icon: nil, iconGray: nil, hidden: false, unlocked: true, unlockTime: 100, statID: 1, bit: 1)
        ], stats: [])
    }
    func testCompletedDownloadsMoveToRemovableHistoryAndKeepGameFiles() async throws {
        let root = try root(); let game = game(root)
        try Data("game files".utf8).write(to: URL(fileURLWithPath: game.executablePath))
        let queue = DownloadQueue(root: root, runner: { _ in }, interrupt: {})
        queue.enqueue(game, platform: .windows, accountID: nil)
        for _ in 0..<100 where !queue.pending.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(queue.pending.isEmpty); XCTAssertEqual(queue.history.count, 1)
        XCTAssertNotNil(queue.history.first?.finishedAt)
        queue.remove(queue.history[0].id)
        XCTAssertTrue(queue.jobs.isEmpty)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: game.executablePath)), "game files")
        let restored = DownloadQueue(root: root, runner: { _ in XCTFail() }, interrupt: {})
        XCTAssertTrue(restored.history.isEmpty)
    }
    func testCancelKeepsActiveJobUntilWorkerActuallyStops() async throws {
        let root = try root(); let game = game(root)
        var finish: CheckedContinuation<Void, Never>?
        var interrupted = 0
        let queue = DownloadQueue(root: root, runner: { _ in await withCheckedContinuation { finish = $0 } }, interrupt: { interrupted += 1 })
        queue.enqueue(game, platform: .windows, accountID: nil)
        for _ in 0..<100 where finish == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let id = queue.jobs[0].id; queue.cancel(id)
        XCTAssertEqual(interrupted, 1); XCTAssertEqual(queue.history[0].state, .cancelled)
        XCTAssertFalse(queue.canRemove(id)); queue.clearHistory(); XCTAssertEqual(queue.jobs.count, 1)
        finish?.resume(); finish = nil
        for _ in 0..<100 where !queue.canRemove(id) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(queue.canRemove(id)); queue.remove(id); XCTAssertTrue(queue.jobs.isEmpty)
    }
    func testQueuedCancellationDoesNotInterruptOtherWork() async throws {
        let root = try root(); var first = game(root); let second = game(root); first.title = "First"
        var finish: CheckedContinuation<Void, Never>?
        var interrupted = 0
        let queue = DownloadQueue(root: root, runner: { _ in await withCheckedContinuation { finish = $0 } }, interrupt: { interrupted += 1 })
        queue.enqueue(first, platform: .windows, accountID: nil); queue.enqueue(second, platform: .windows, accountID: nil)
        for _ in 0..<100 where finish == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let queued = queue.jobs.first { $0.game.id == second.id }!; queue.cancel(queued.id)
        XCTAssertEqual(interrupted, 0); XCTAssertTrue(queue.canRemove(queued.id))
        finish?.resume(); finish = nil
        for _ in 0..<100 where queue.pending.contains(where: { $0.state == .active }) { try await Task.sleep(nanoseconds: 10_000_000) }
        queue.clearHistory(); XCTAssertTrue(queue.jobs.isEmpty)
    }
    func testOnlyNewEarnedKnownTrophiesInsideGameSessionAreCaptured() throws {
        let now = Date(timeIntervalSince1970: 2000)
        let bytes = Data(#"{"REAL_EVENT":{"earned":true,"earned_time":2000},"ALREADY_EARNED":{"earned":true,"earned_time":2000},"UNKNOWN":{"earned":true,"earned_time":2000}}"#.utf8)
        let events = try AchievementCapture.newlyEarned(bytes: bytes, baseline: ["ALREADY_EARNED"], snapshot: snapshot(), startedAt: now, now: now)
        XCTAssertEqual(events.map(\.name), ["REAL_EVENT"])
        XCTAssertEqual(events.first?.owner, snapshot().steamID)
        XCTAssertTrue(try AchievementCapture.newlyEarned(bytes: bytes, baseline: ["REAL_EVENT", "ALREADY_EARNED"], snapshot: snapshot(), startedAt: now, now: now).isEmpty)
        for timestamp in [100, 3000] {
            let data = Data("{\"REAL_EVENT\":{\"earned\":true,\"earned_time\":\(timestamp)}}".utf8)
            XCTAssertTrue(try AchievementCapture.newlyEarned(bytes: data, baseline: [], snapshot: snapshot(), startedAt: now, now: now).isEmpty)
        }
        XCTAssertTrue(try AchievementCapture.newlyEarned(bytes: Data(#"{"REAL_EVENT":{"earned":false,"earned_time":2000}}"#.utf8), baseline: [], snapshot: snapshot(), startedAt: now, now: now).isEmpty)
    }
    func testStoredOfflineUnlocksAreRetriedWithoutResubmittingRemoteTrophies() throws {
        let bytes = Data(#"{"REAL_EVENT":{"earned":true,"earned_time":1500},"ALREADY_EARNED":{"earned":true,"earned_time":100}}"#.utf8)
        let events = try AchievementCapture.unsyncedStored(bytes: bytes, snapshot: snapshot(), now: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(events.map(\.name), ["REAL_EVENT"])
        XCTAssertEqual(events.first?.earnedTime, 1500)
    }
    func testSteamImagesCannotOpenFilesAndPersonaHasAllEightSupportedStates() {
        for url in ["file:///private/data", "http://avatars.steamstatic.com/x.jpg", "https://evil.example/image", "https://steamstatic.com.evil.example/image"] { XCTAssertNil(SteamImageURL.make(url)) }
        XCTAssertNotNil(SteamImageURL.make("https://avatars.steamstatic.com/fixture_full.jpg"))
        XCTAssertEqual(SteamPersona.allCases.map(\.rawValue), Array(0...7))
        XCTAssertNil(SteamPersona(rawValue: 8))
    }
    func testPersistentSocialSessionChangesPersonaWithoutQRAndKeepsOwner() async throws {
        let root = try root(), helper = root.appendingPathComponent("social.py")
        try SessionStore.save(SteamSession(steamID: "76561198000000000", username: "fixture", account: Data("fixture".utf8)), root: root)
        try Data(#"""
        #!/usr/bin/python3
        import pathlib,json,sys,time
        args=sys.argv
        assert '-qr' not in args and pathlib.Path('account.config').exists()
        assert args[args.index('-loginid')+1]=='1296516166'
        folder=pathlib.Path(args[args.index('-deck-service')+1])
        print('MACGAMEDECK_EVENT:{"type":"account","steamID":"76561198000000000","username":"fixture"}',flush=True)
        profile={'steamID':'76561198000000000','name':'Fixture','avatar':'https://avatars.steamstatic.com/fixture.jpg','state':0,'blocked':False}
        def write(file,value):
            tmp=folder/'temp.json';tmp.write_text(json.dumps(value));tmp.replace(file)
        while not (folder/'stop').exists():
            write(folder/'result-profile.json',profile)
            for file in folder.glob('command-*.json'):
                request=json.loads(file.read_text());assert request['steamID']==profile['steamID']
                if request['kind']=='presence':profile['state']=request['state']
                write(folder/file.name.replace('command-','result-'),{'ok':True});file.unlink()
            time.sleep(.02)
        """#.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let service = SteamSocial(root: root, helperProvider: { helper }); service.start(owner: "76561198000000000")
        defer { service.stop() }
        for _ in 0..<200 { if service.connected && !service.changingPresence { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(service.connected)
        service.setPresence(.invisible)
        for _ in 0..<200 { if service.profile?.persona == .invisible && !service.changingPresence { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(service.profile?.persona, .invisible)
        XCTAssertEqual(service.profile?.steamID, "76561198000000000")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Account/presence.json"))) as? [String: Any]
        XCTAssertEqual(saved?["state"] as? Int, 7)
        XCTAssertEqual(saved?["steamID"] as? String, "76561198000000000")
    }
    func pe(_ marker: String) -> Data {
        var data = Data(repeating: 0, count: 128); data[0] = 0x4d; data[1] = 0x5a; data[60] = 64
        data.replaceSubrange(64..<70, with: [0x50, 0x45, 0, 0, 0x64, 0x86]); data.append(Data(marker.utf8)); return data
    }
    func testBridgeUsesBackupsPreservesEarnedStateAndRestoresOriginalAPI() throws {
        let root = try root(); let game = game(root)
        let base = URL(fileURLWithPath: game.installDirectory!), api = base.appendingPathComponent("steam_api64.dll")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("steam_settings"), withIntermediateDirectories: true)
        let original = pe("original"), payload = pe("bridge")
        try original.write(to: api)
        let config = base.appendingPathComponent("steam_settings/configs.user.ini"); try Data("original settings".utf8).write(to: config)
        let resources = root.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("x64"), withIntermediateDirectories: true)
        try payload.write(to: resources.appendingPathComponent("x64/steam_api64.dll"))
        try JSONSerialization.data(withJSONObject: ["files": ["x64/steam_api64.dll": SteamBridgeInstaller.sha256(payload)]]).write(to: resources.appendingPathComponent("manifest.json"))
        let first = try XCTUnwrap(SteamBridgeInstaller.install(game, snapshot: snapshot(), root: root, resources: resources))
        XCTAssertEqual(try Data(contentsOf: api), payload)
        XCTAssertTrue(try String(contentsOf: config).contains("account_steamid=76561198000000000"))
        let baseline = AchievementCapture.baseline(first.eventFile, snapshot: snapshot())
        XCTAssertTrue(baseline.contains("ALREADY_EARNED")); XCTAssertFalse(baseline.contains("REAL_EVENT"))
        // A second preparation must retain the original backup, not back up the bridge as an original.
        _ = try SteamBridgeInstaller.install(game, snapshot: snapshot(), root: root, resources: resources)
        try SteamBridgeInstaller.restore(game, root: root)
        XCTAssertEqual(try Data(contentsOf: api), original)
        XCTAssertEqual(try String(contentsOf: config), "original settings")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("steam_appid.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.eventFile.path))
    }
    func testUnsupportedOrDamagedBridgeCannotReplaceGameAPI() throws {
        let root = try root(), game = game(root), api = URL(fileURLWithPath: game.installDirectory!).appendingPathComponent("steam_api64.dll")
        try FileManager.default.createDirectory(at: api.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = pe("original"); try original.write(to: api)
        let resources = root.appendingPathComponent("Bad")
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("x64"), withIntermediateDirectories: true)
        try pe("tampered").write(to: resources.appendingPathComponent("x64/steam_api64.dll"))
        try JSONSerialization.data(withJSONObject: ["files": ["x64/steam_api64.dll": "wrong"]]).write(to: resources.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try SteamBridgeInstaller.install(game, snapshot: snapshot(), root: root, resources: resources))
        XCTAssertEqual(try Data(contentsOf: api), original)
        XCTAssertThrowsError(try SteamBridgeInstaller.architecture(Data("not PE".utf8)))
    }
}

extension NativeSteamFeaturesTests {
    func testLiveCaptureRequestsOneNotificationAndJournalsOfflineWithoutDuplicateOrFakeUnlock() throws {
        let root = try root(), game = game(root), social = SteamSocial(root: root)
        let api = URL(fileURLWithPath: game.installDirectory!).appendingPathComponent("steam_api64.dll")
        try FileManager.default.createDirectory(at: api.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pe("original").write(to: api)
        let resources = root.appendingPathComponent("TestBridge")
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("x64"), withIntermediateDirectories: true)
        let payload = pe("bridge"); try payload.write(to: resources.appendingPathComponent("x64/steam_api64.dll"))
        try JSONSerialization.data(withJSONObject: ["files": ["x64/steam_api64.dll": SteamBridgeInstaller.sha256(payload)]]).write(to: resources.appendingPathComponent("manifest.json"))
        var notified: [String] = []
        let monitor = AchievementMonitor(root: root, social: social, onSnapshot: { _ in XCTFail("No Steam confirmation while offline") }, notification: { _, achievement in notified.append(achievement.name) })
        try monitor.prepare(game, snapshot: snapshot(), resources: resources)
        monitor.start(game, processID: 999999)
        defer { monitor.stop(game) }
        let eventFile = URL(fileURLWithPath: game.managedLaunch!.prefix).appendingPathComponent("drive_c/ProgramData/MacGameDeck/SteamBridge/76561198000000000/10/achievements.json")
        let now = UInt32(Date().timeIntervalSince1970)
        try JSONSerialization.data(withJSONObject: ["REAL_EVENT": ["earned": true, "earned_time": now], "ALREADY_EARNED": ["earned": true, "earned_time": now], "UNKNOWN": ["earned": true, "earned_time": now]]).write(to: eventFile, options: .atomic)
        monitor.poll(); monitor.poll()
        XCTAssertEqual(notified, ["REAL_EVENT"])
        let events = try JSONDecoder().decode([AchievementEvent].self, from: Data(contentsOf: root.appendingPathComponent("SteamBridge/events.json")))
        XCTAssertEqual(events.map(\.name), ["REAL_EVENT"])
        XCTAssertEqual(monitor.status[game.id], "Sblocco rilevato · conferma Steam in attesa")
        XCTAssertTrue(try AppDiagnostics.tail(AppDiagnostics(root: root).file).contains("REAL_EVENT"))
        monitor.testNotification()
        XCTAssertEqual(notified.last, "LOCAL_NOTIFICATION_TEST")
        XCTAssertEqual(try JSONDecoder().decode([AchievementEvent].self, from: Data(contentsOf: root.appendingPathComponent("SteamBridge/events.json"))), events)
    }
}

extension NativeSteamFeaturesTests {
    func testSteamworksBridgeCanRunWithoutAchievementsAndKeepsOriginalBackup() throws {
        let root = try root(), game = game(root), base = URL(fileURLWithPath: game.installDirectory!), api = base.appendingPathComponent("steam_api64.dll")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let original = pe("original"); try original.write(to: api)
        let resources = root.appendingPathComponent("EmptySchemaBridge")
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("x64"), withIntermediateDirectories: true)
        let payload = pe("bridge"); try payload.write(to: resources.appendingPathComponent("x64/steam_api64.dll"))
        try JSONSerialization.data(withJSONObject: ["files": ["x64/steam_api64.dll": SteamBridgeInstaller.sha256(payload)]]).write(to: resources.appendingPathComponent("manifest.json"))
        let empty = SteamAchievementSnapshot(steamID: snapshot().steamID, appID: 10, achievements: [], stats: [])
        XCTAssertNotNil(try SteamBridgeInstaller.install(game, snapshot: empty, root: root, resources: resources))
        XCTAssertEqual(try Data(contentsOf: api), payload)
        try SteamBridgeInstaller.restore(game, root: root)
        XCTAssertEqual(try Data(contentsOf: api), original)
    }
}
