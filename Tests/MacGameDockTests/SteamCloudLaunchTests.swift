import XCTest
@testable import MacGameDock

@MainActor
final class SteamCloudLaunchTests: XCTestCase {
    func testCloudDownloadFinishesBeforeDirectGameProcessAndStatsUseSteamValues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = getenv("MACGAMEDOCK_DATA_DIRECTORY").map { String(cString: $0) }
        setenv("MACGAMEDOCK_DATA_DIRECTORY", root.path, 1)
        defer { if let previous { setenv("MACGAMEDOCK_DATA_DIRECTORY", previous, 1) } else { unsetenv("MACGAMEDOCK_DATA_DIRECTORY") }; try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("prefix/drive_c/users/crossover")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        for relative in WineRuntime.requiredFiles {
            let file = root.appendingPathComponent("prefix/" + relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
        }
        let helper = root.appendingPathComponent("helper.py")
        try Data(#"""
        #!/usr/bin/python3
        import json, hashlib, pathlib, sys, time
        args=sys.argv
        if '-qr' in args or not pathlib.Path('account.config').exists(): sys.exit(8)
        print('MACGAMEDECK_EVENT:{"type":"account","steamID":"76561198000000000","username":"fixture"}', flush=True)
        def arg(key): return args[args.index(key)+1]
        if '-deck-cloud-inventory' in args:
            marker=pathlib.Path(__file__).with_suffix('.reconnected')
            if not marker.exists():
                marker.touch()
                print('MACGAMEDECK_EVENT:{"type":"cloud_error","code":"steam_NoConnection","errorType":"DeckCloudException"}',flush=True)
                sys.exit(1)
            rule={'name':'0','children':[{'name':k,'value':v,'children':[]} for k,v in [('root','WinAppDataRoaming'),('path','Test'),('pattern','*.dat')]]}
            data={'schemaVersion':1,'steamID':'76561198000000000','appID':10,'changeNumber':'1','isDelta':False,'prefixes':['%WinAppDataRoaming%'],'files':[{'name':'Test/save.dat','sha1':hashlib.sha1(b'remote').hexdigest(),'size':6,'timestamp':int(time.time())-60,'state':0,'prefixIndex':0}],'ufs':{'name':'ufs','children':[{'name':'savefiles','children':[rule]}]}}
            pathlib.Path(arg('-deck-cloud-inventory')).write_text(json.dumps(data))
        elif '-deck-cloud-download' in args:
            request=json.loads(pathlib.Path(arg('-deck-cloud-download')).read_text())
            assert request[0]['name']=='%WinAppDataRoaming%Test/save.dat'
            pathlib.Path(arg('-deck-cloud-directory'),'0.save').write_bytes(b'remote')
        elif '-deck-player' in args:
            pathlib.Path(arg('-deck-player')).write_text(json.dumps({'steamID':'76561198000000000','appID':10,'minutes':36,'unlocked':5,'total':20,'fetchedAt':int(time.time())}))
        else: sys.exit(9)
        """#.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let runtime = root.appendingPathComponent("wine")
        try Data("#!/bin/sh\ncat \"$WINEPREFIX/drive_c/users/crossover/AppData/Roaming/Test/save.dat\"\n".utf8).write(to: runtime)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
        let executable = root.appendingPathComponent("game.exe"); try Data().write(to: executable)
        let game = Game(id: UUID(), title: "Cloud launch", store: .steam, executablePath: executable.path, addedAt: Date(), steamAppID: 10, installDirectory: root.path,
                        managedLaunch: ManagedLaunch(prefix: root.appendingPathComponent("prefix").path, arguments: [], workingDirectory: root.path, platform: .windows))
        var data = LibraryData(); data.games = [game]; data.steamAccount = SteamAccount(steamID: "76561198000000000", connectedAt: Date())
        try JSONEncoder().encode(data).write(to: root.appendingPathComponent("library.json"))
        try SessionStore.save(SteamSession(steamID: "76561198000000000", username: "fixture", account: Data("fixture".utf8)), root: root)
        let library = Library(runtimeResolver: { runtime.path }, steamHelperProvider: { helper })
        library.launch(game)
        XCTAssertTrue(library.preparingLaunch.contains(game.id))
        for _ in 0..<300 {
            if !library.preparingLaunch.contains(game.id), !library.running.contains(game.id) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(library.error)
        XCTAssertFalse(library.preparingLaunch.contains(game.id))
        XCTAssertEqual(try String(contentsOf: user.appendingPathComponent("AppData/Roaming/Test/save.dat")), "remote")
        XCTAssertTrue(try String(contentsOf: library.log(for: game)).contains("remote"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Tools/SteamClient").path))
        let snapshot = try await library.managedSteam.playerSnapshot(game, expected: "76561198000000000")
        try library.updateSteamSnapshot(snapshot)
        XCTAssertEqual(library.data.games[0].steamMinutes, 36)
        XCTAssertEqual(library.data.games[0].steamAchievementsUnlocked, 5)
        XCTAssertEqual(library.data.games[0].steamAchievementsTotal, 20)
        XCTAssertNil(LibraryMerge.disconnect(library.data).games[0].steamMinutes)
    }
}
