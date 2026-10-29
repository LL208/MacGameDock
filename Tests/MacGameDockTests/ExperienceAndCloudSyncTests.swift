import XCTest
@testable import MacGameDock

@MainActor
final class ExperienceAndCloudSyncTests: XCTestCase {
    func testPreferencesSurviveCatalogRefreshAndRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = Game(id: UUID(), title: "Test", store: .steam, executablePath: "", addedAt: Date(), steamAppID: 10)
        let experience = GameExperience(root: root)
        experience.update(game) { $0.favorite = true; $0.collection = "Indie"; $0.confirmedWorking = true }
        experience.settings { $0.resumeDownloads = true; $0.theme = "Sistema" }
        var refreshed = game; refreshed = Game(id: UUID(), title: "Updated", store: .steam, executablePath: "", addedAt: Date(), steamAppID: 10)
        let loaded = GameExperience(root: root)
        XCTAssertTrue(loaded.game(refreshed).favorite)
        XCTAssertEqual(loaded.collections, ["Indie"])
        XCTAssertTrue(loaded.preferences.resumeDownloads)
        XCTAssertEqual(loaded.compatibility(refreshed), "Funzionamento confermato da te")
    }
    func testUnreadablePreferencesArePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("experience.json")
        try Data("invalid".utf8).write(to: file)
        let experience = GameExperience(root: root)
        experience.settings { $0.theme = "Scuro" }
        XCTAssertNotNil(experience.error)
        XCTAssertEqual(try String(contentsOf: file), "invalid")
    }
    func testUploadNeverOverwritesConcurrentRemoteChangesOrDeletions() throws {
        XCTAssertEqual(try CloudSyncFiles.uploads(local: ["save":"new"], remote: ["save":"old"], baseline: ["save":"old"]), ["save"])
        XCTAssertEqual(try CloudSyncFiles.uploads(local: ["new":"hash"], remote: [:], baseline: [:]), ["new"])
        XCTAssertEqual(try CloudSyncFiles.uploads(local: ["save":"same"], remote: ["save":"same"], baseline: ["save":"old"]), [])
        XCTAssertThrowsError(try CloudSyncFiles.uploads(local: ["save":"local"], remote: ["save":"other-device"], baseline: ["save":"old"]))
        XCTAssertThrowsError(try CloudSyncFiles.uploads(local: ["save":"local"], remote: [:], baseline: ["save":"old"]))
        XCTAssertEqual(try CloudSyncFiles.uploads(local: [:], remote: ["save":"old"], baseline: ["save":"old"]), [])
        XCTAssertThrowsError(try CloudSyncFiles.uploads(local: ["../outside":"hash"], remote: [:], baseline: [:]))
    }
    func testCloudEnumerationOnlyIncludesDeclaredPatternsAndRejectsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let saves = root.appendingPathComponent("Saves")
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("save".utf8).write(to: saves.appendingPathComponent("slot.dat"))
        try Data("private".utf8).write(to: saves.appendingPathComponent("private.txt"))
        let json = #"{"schemaVersion":1,"steamID":"76561198000000000","appID":10,"changeNumber":"0","isDelta":false,"prefixes":[],"files":[],"ufs":{"name":"ufs","children":[{"name":"savefiles","children":[{"name":"0","children":[{"name":"root","value":"GameInstall","children":[]},{"name":"path","value":"Saves","children":[]},{"name":"pattern","value":"*.dat","children":[]}]}]}]}}"#
        let inventory = try JSONDecoder().decode(SteamCloudInventory.self, from: Data(json.utf8))
        let game = Game(id: UUID(), title: "Test", store: .steam, executablePath: root.appendingPathComponent("game.app").path, addedAt: Date(), steamAppID: 10, installDirectory: root.path, managedLaunch: ManagedLaunch(prefix: "", arguments: [], workingDirectory: root.path, platform: .macOS))
        let local = try CloudSyncFiles.local(inventory, game: game)
        XCTAssertEqual(Set(local.keys), ["%GameInstall%Saves/slot.dat"])
        try FileManager.default.createSymbolicLink(at: saves.appendingPathComponent("linked.dat"), withDestinationURL: saves.appendingPathComponent("private.txt"))
        XCTAssertThrowsError(try CloudSyncFiles.local(inventory, game: game))
    }
    func testCloudUploadUsesVerifiedSnapshotAndRetainsPendingOnNetworkFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let saves = root.appendingPathComponent("Game/Saves")
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("server.json")
        try Data(#"{"content":"remote","change":1}"#.utf8).write(to: state)
        let helper = root.appendingPathComponent("helper.py")
        let script = #"""
        #!/usr/bin/python3
        import json, pathlib, hashlib, sys, time
        root=pathlib.Path(ROOT_PATH)
        server=root/'server.json'
        data=json.loads(server.read_text())
        args=sys.argv
        def arg(key): return args[args.index(key)+1]
        print('MACGAMEDECK_EVENT:{"type":"account","steamID":"76561198000000000","username":"fixture"}',flush=True)
        name='%GameInstall%Saves/slot.dat'
        content=data['content'].encode()
        if '-deck-cloud-inventory' in args:
            rule={'name':'0','children':[{'name':k,'value':v,'children':[]} for k,v in [('root','GameInstall'),('path','Saves'),('pattern','*.dat')]]}
            inventory={'schemaVersion':1,'steamID':'76561198000000000','appID':10,'changeNumber':str(data['change']),'isDelta':False,'prefixes':[],'files':[{'name':name,'sha1':hashlib.sha1(content).hexdigest(),'size':len(content),'timestamp':int(time.time())-60,'state':0,'prefixIndex':0}],'ufs':{'name':'ufs','children':[{'name':'savefiles','children':[rule]}]}}
            pathlib.Path(arg('-deck-cloud-inventory')).write_text(json.dumps(inventory))
        elif '-deck-cloud-upload' in args:
            if (root/'offline').exists():
                print('MACGAMEDECK_EVENT:{"type":"cloud_error","code":"steam_NoConnection"}',flush=True)
                sys.exit(1)
            requestFile=pathlib.Path(arg('-deck-cloud-upload'))
            request=json.loads(requestFile.read_text())
            assert request['changeNumber']==str(data['change'])
            assert request['steamID']=='76561198000000000'
            assert len(request['files'])==1
            entry=request['files'][0]
            copy=(requestFile.parent/entry['source']).read_bytes()
            assert hashlib.sha1(copy).hexdigest()==entry['sha1']
            assert len(copy)==entry['size']
            assert entry['name']==name
            data={'content':copy.decode(),'change':data['change']+1}
            server.write_text(json.dumps(data))
            (root/'uploaded').write_text('verified')
        else: sys.exit(9)
        """#
        let pathEncoder = JSONEncoder(); pathEncoder.outputFormatting = [.withoutEscapingSlashes]
        let encodedRoot = String(data: try pathEncoder.encode(root.path), encoding: .utf8)!
        try Data(script.replacingOccurrences(of: "ROOT_PATH", with: encodedRoot).utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let game = Game(id: UUID(), title: "Upload", store: .steam, executablePath: root.appendingPathComponent("Game/game.app").path, addedAt: Date(), steamAppID: 10, installDirectory: root.appendingPathComponent("Game").path, managedLaunch: ManagedLaunch(prefix: "", arguments: [], workingDirectory: root.appendingPathComponent("Game").path, platform: .macOS))
        let owner = "76561198000000000"
        try SessionStore.save(SteamSession(steamID: owner, username: "fixture", account: Data("fixture".utf8)), root: root)
        let steam = ManagedSteam(root: root, helperProvider: { helper })
        let inventory = try await steam.cloudInventory(game, expected: owner)
        try steam.captureCloudSession(inventory, game: game)
        let save = saves.appendingPathComponent("slot.dat")
        try Data("new-progress".utf8).write(to: save)
        try Data().write(to: root.appendingPathComponent("offline"))
        do { _ = try await steam.uploadCloudAfterPlay(game, expected: owner); XCTFail("Expected offline failure") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: steam.cloudSessionURL(owner: owner, appID: 10).path))
        XCTAssertEqual(try String(contentsOf: save), "new-progress")
        try FileManager.default.removeItem(at: root.appendingPathComponent("offline"))
        let count = try await steam.uploadCloudAfterPlay(game, expected: owner)
        XCTAssertEqual(count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: steam.cloudSessionURL(owner: owner, appID: 10).path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("uploaded")), "verified")
        let server = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as! [String: Any]
        XCTAssertEqual(server["content"] as? String, "new-progress")
        let next = try await steam.cloudInventory(game, expected: owner)
        try steam.captureCloudSession(next, game: game)
        try Data("another-local".utf8).write(to: save)
        try Data(#"{"content":"other-device","change":3}"#.utf8).write(to: state)
        do { _ = try await steam.uploadCloudAfterPlay(game, expected: owner); XCTFail("Expected conflict") } catch {}
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as! [String: Any])["content"] as? String, "other-device")
        XCTAssertEqual(try String(contentsOf: save), "another-local")
    }

}

@MainActor
final class StorageAndModLibraryTests: XCTestCase {
    func testVerifiedMovePreservesOriginalAndWineLinksAndRejectsExistingDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Original"), target = root.appendingPathComponent("OtherDisk/Game")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: source.appendingPathComponent("game.exe"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("z:").path, withDestinationPath: "/")
        try GameStorage.copyVerified(from: source, to: target)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("game.exe")), "payload")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("game.exe")), "payload")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("z:").path), "/")
        XCTAssertThrowsError(try GameStorage.copyVerified(from: source, to: target))
        XCTAssertThrowsError(try GameStorage.remap(root.appendingPathComponent("outside").path, from: source, to: target))
    }
    func testModCanBeDisabledAndRestoredWithoutOverwritingAnExistingFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Game/Mods/One")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("mod".utf8).write(to: folder.appendingPathComponent("mod.dat"))
        let game = Game(id: UUID(), title: "Test", store: .steam, executablePath: "", addedAt: Date(), steamAppID: 10)
        let mods = WorkshopLibrary(root: root)
        try mods.register(game: game, itemID: "123", title: "Test mod", destination: folder)
        try mods.toggle(mods.installed[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(mods.installed[0].enabled)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try mods.toggle(mods.installed[0]))
        try FileManager.default.removeItem(at: folder)
        try mods.toggle(mods.installed[0])
        XCTAssertTrue(mods.installed[0].enabled)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("mod.dat")), "mod")
        XCTAssertEqual(WorkshopLibrary(root: root).mods(for: game).count, 1)
    }
}
