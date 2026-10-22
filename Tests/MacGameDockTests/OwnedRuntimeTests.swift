import XCTest
@testable import MacGameDock

@MainActor
final class OwnedRuntimeTests: XCTestCase {
    func root() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    func seed(_ engine: OwnedRuntime) throws {
        for file in engine.requiredFiles + OwnedRuntime.graphicsFiles().map({ engine.dxmtRoot.appendingPathComponent($0) }) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let module = engine.wineRoot.appendingPathComponent("lib/wine/x86_64-unix/winemac.so")
        try FileManager.default.createDirectory(at: module.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MetalExportFixture.module().write(to: module)
        let folder = engine.root.appendingPathComponent("Tools/GameEngine/wine-cxfoss-24.0.7_7-dxmt-0.80-support1")
        try JSONEncoder().encode(["wine": RuntimeAsset.wine.sha256, "dxmt": RuntimeAsset.dxmt.sha256, "support": RuntimeAsset.support.sha256]).write(to: folder.appendingPathComponent("ready.json"))
    }
    func testPinnedPackagesRejectTruncationAndChangedContents() throws {
        let root = try root(), file = root.appendingPathComponent("asset")
        try Data("original".utf8).write(to: file)
        let asset = RuntimeAsset(id: "fixture", url: URL(string: "https://example.test/file")!, sha256: try RuntimeAsset.hash(file), size: 8, directory: "fixture")
        XCTAssertNoThrow(try asset.validate(file))
        try Data("modified".utf8).write(to: file); XCTAssertThrowsError(try asset.validate(file))
        try Data("short".utf8).write(to: file); XCTAssertThrowsError(try asset.validate(file))
    }
    func testReadyRuntimeNeedsCorrectReceiptAndAllGraphicsFiles() throws {
        let engine = OwnedRuntime(root: try root()); XCTAssertNil(engine.installed)
        try seed(engine); XCTAssertNotNil(engine.installed)
        try FileManager.default.removeItem(at: engine.dxmtRoot.appendingPathComponent("x86_64-windows/dxgi.dll"))
        XCTAssertNil(engine.installed)
    }
    func testReadyRuntimeUsesOwnFilesAndDoesNotDownloadAgain() async throws {
        let engine = OwnedRuntime(root: try root()); try seed(engine)
        let first = try await engine.ensure(), second = try await engine.ensure()
        XCTAssertEqual(first, second); XCTAssertFalse(engine.busy)
        let env = engine.environment(runtime: first.path, prefix: engine.root.appendingPathComponent("prefix"), directX12: false)
        XCTAssertTrue(env["WINESERVER"]?.hasPrefix(engine.root.path) == true)
        XCTAssertEqual(env["WINEDLLPATH"], engine.wineRoot.appendingPathComponent("lib/wine").path)
        XCTAssertFalse(env.values.contains { $0.contains("CrossOver.app") })
        XCTAssertNil(WineRuntime.detect())
        let dx12 = engine.environment(runtime: first.path, prefix: engine.root, directX12: true)
        XCTAssertFalse(dx12["WINEDLLPATH"]?.contains("DXMT") == true)
    }
    func testOwnedWineAndDXMTArchivesInstallAndWineReportsItsVersion() async throws {
        guard let source = ProcessInfo.processInfo.environment["MACGAMEDECK_ENGINE_ARCHIVES"] else { throw XCTSkip("Verifica reale del runtime abilitata solo con archivi verificati.") }
        let root = try root(), cache = root.appendingPathComponent("Tools/GameEngine/Downloads")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for (asset, name) in [(RuntimeAsset.wine, "wine-cxfoss.tar.xz"), (RuntimeAsset.support, "wine-clean.tar.xz"), (RuntimeAsset.dxmt, "dxmt.tar.gz")] {
            let original = URL(fileURLWithPath: source).appendingPathComponent(name)
            try asset.validate(original)
            try FileManager.default.copyItem(at: original, to: cache.appendingPathComponent(asset.url.lastPathComponent))
        }
        let engine = OwnedRuntime(root: root), runtime = try await engine.ensure()
        XCTAssertEqual(engine.installed, runtime)
        let process = Process(); process.executableURL = runtime; process.arguments = ["--version"]
        process.environment = engine.environment(runtime: runtime.path, prefix: root.appendingPathComponent("prefix"), directX12: false)
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("9.0"), output)
    }
}

extension OwnedRuntimeTests {
    func testExternalSteamMetadataResolvesInstalledGameWithoutDownloadOrClient() async throws {
        let root = try root(), gameDirectory = root.appendingPathComponent("ExternalGame"), app = gameDirectory.appendingPathComponent("Native.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("metadata.py")
        try Data(#"""
        #!/usr/bin/python3
        import sys,pathlib,json
        a=sys.argv
        assert '-deck-launch-metadata' in a and '-validate' not in a and '-qr' not in a
        assert pathlib.Path('account.config').exists()
        target=pathlib.Path(a[a.index('-deck-launch-metadata')+1])/'.MacGameDeck';target.mkdir()
        (target/'metadata.json').write_text(json.dumps({'appID':123,'launches':[{'executable':'Native.app','arguments':'--native','oslist':'macos'}]}))
        print('MACGAMEDECK_EVENT:{"type":"account","steamID":"76561198000000000","username":"fixture"}',flush=True)
        """#.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try SessionStore.save(SteamSession(steamID: "76561198000000000", username: "fixture", account: Data("fixture".utf8)), root: root)
        let game = Game(id: UUID(), title: "External", store: .steam, executablePath: "", addedAt: Date(), steamAppID: 123, installDirectory: gameDirectory.path, launchURL: "steam://rungameid/123")
        let launch = try await ManagedSteam(root: root, helperProvider: { helper }).externalLaunch(game, expected: "76561198000000000")
        XCTAssertTrue(FileManager.default.fileExists(atPath: launch.0))
        XCTAssertEqual(launch.1.platform, .macOS)
        XCTAssertEqual(launch.1.arguments, ["--native"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: gameDirectory.appendingPathComponent(".MacGameDeck").path))
    }
    func testDefaultWindowsLaunchCannotBeMisclassifiedAsMacNative() throws {
        let folder = try root(), exe = folder.appendingPathComponent("Game.exe")
        try Data().write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exe.path)
        let meta = try JSONDecoder().decode(DeckMetadata.self, from: Data(#"{"appID":1,"launches":[{"executable":"Game.exe"}]}"#.utf8))
        XCTAssertThrowsError(try meta.select(in: folder, platform: .macOS))
        XCTAssertNoThrow(try meta.select(in: folder, platform: .windows))
    }
}

extension OwnedRuntimeTests {
    func testStandaloneUnrealRendererSelectionRespectsExplicitChoice() throws {
        let root = try root(), exe = root.appendingPathComponent("Shipping.exe")
        var bytes = Data(repeating: 0, count: 128); bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64
        bytes.replaceSubrange(64..<70, with: [0x50, 0x45, 0, 0, 0x64, 0x86]); bytes.append(Data("D3D11RHI D3D12RHI".utf8))
        try bytes.write(to: exe)
        let defaultPlan = WindowsGameLaunch(executable: exe, arguments: ["Project"], workingDirectory: root, bypassedBootstrapper: true)
        let selected = defaultPlan.standaloneCompatible()
        XCTAssertEqual(selected.arguments, ["Project", "-dx11"])
        XCTAssertFalse(selected.usesDirectX12)
        let explicit = WindowsGameLaunch(executable: exe, arguments: ["Project", "-d3d12"], workingDirectory: root, bypassedBootstrapper: true).standaloneCompatible()
        XCTAssertEqual(explicit.arguments, ["Project", "-d3d12"])
        XCTAssertTrue(explicit.usesDirectX12)
        let ordinary = WindowsGameLaunch(executable: exe, arguments: [], workingDirectory: root, bypassedBootstrapper: false).standaloneCompatible()
        XCTAssertTrue(ordinary.arguments.isEmpty)
    }
}

extension OwnedRuntimeTests {
    func testNativeOriginalSteamSDKIsRecognizedWithoutOpeningTheClient() throws {
        let root = try root(), app = root.appendingPathComponent("Game.app"), sdk = app.appendingPathComponent("Contents/MacOS/libsteam_api.dylib")
        try FileManager.default.createDirectory(at: sdk.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertFalse(NativeSteamRequirement.originalSDK(in: app))
        try Data().write(to: sdk)
        XCTAssertTrue(NativeSteamRequirement.originalSDK(in: app))
    }
}

extension OwnedRuntimeTests {
    func testRuntimeRetriesTransientNetworkErrorsOnly() {
        XCTAssertTrue(OwnedRuntime.shouldRetry(URLError(.timedOut), attempt: 1))
        XCTAssertTrue(OwnedRuntime.shouldRetry(URLError(.networkConnectionLost), attempt: 3))
        XCTAssertFalse(OwnedRuntime.shouldRetry(URLError(.timedOut), attempt: 4))
        XCTAssertFalse(OwnedRuntime.shouldRetry(URLError(.cancelled), attempt: 1))
        XCTAssertFalse(OwnedRuntime.shouldRetry(URLError(.serverCertificateUntrusted), attempt: 1))
        XCTAssertFalse(OwnedRuntime.shouldRetry(DockError.message("integrità"), attempt: 1))
    }
}

extension OwnedRuntimeTests {
    func testGraphicsOverlayInstallsBothArchitecturesAndRepairsMissingBridge() throws {
        let engine = OwnedRuntime(root: try root()); try seed(engine)
        let folder = engine.root.appendingPathComponent("Tools/GameEngine/wine-cxfoss-24.0.7_7-dxmt-0.80-support1")
        try OwnedRuntime.installGraphics(in: folder)
        let target = engine.wineRoot.appendingPathComponent("lib/wine")
        for name in OwnedRuntime.graphicsFiles() {
            XCTAssertEqual(try RuntimeAsset.hash(target.appendingPathComponent(name)), try RuntimeAsset.hash(engine.dxmtRoot.appendingPathComponent(name)))
        }
        let bridge = target.appendingPathComponent("x86_64-unix/winemetal.so")
        try FileManager.default.removeItem(at: bridge)
        try OwnedRuntime.installGraphics(in: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bridge.path))
        try Data("old".utf8).write(to: bridge)
        try OwnedRuntime.installGraphics(in: folder)
        XCTAssertEqual(try RuntimeAsset.hash(bridge), try RuntimeAsset.hash(engine.dxmtRoot.appendingPathComponent("x86_64-unix/winemetal.so")))
    }
}

extension OwnedRuntimeTests {
    func testSupportLibrariesDoNotReplaceWineModules() throws {
        let engine = OwnedRuntime(root: try root()); try seed(engine)
        let folder = engine.root.appendingPathComponent("Tools/GameEngine/wine-cxfoss-24.0.7_7-dxmt-0.80-support1")
        let source = folder.appendingPathComponent("Support/" + RuntimeAsset.support.directory + "/lib")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("wine"), withIntermediateDirectories: true)
        try Data("dependency".utf8).write(to: source.appendingPathComponent("libinotify.0.dylib"))
        try Data("incompatible".utf8).write(to: source.appendingPathComponent("wine/ntdll.so"))
        try OwnedRuntime.installSupport(in: folder)
        XCTAssertEqual(try String(contentsOf: engine.wineRoot.appendingPathComponent("lib/libinotify.0.dylib")), "dependency")
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.wineRoot.appendingPathComponent("lib/wine/ntdll.so").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Support").path))
    }
}

extension OwnedRuntimeTests {
    func testBootstrapReadinessRequiresSeparateMatchingReceipt() throws {
        let engine = OwnedRuntime(root: try root()); try seed(engine)
        XCTAssertNotNil(engine.installed)
        XCTAssertFalse(engine.bootstrapVerified)
        try engine.recordBootstrapSuccess()
        XCTAssertTrue(engine.bootstrapVerified)
        let receipt = engine.root.appendingPathComponent("Tools/GameEngine/wine-cxfoss-24.0.7_7-dxmt-0.80-support1/bootstrap-ready.json")
        try Data("{\"wine\":\"different\"}".utf8).write(to: receipt)
        XCTAssertFalse(engine.bootstrapVerified)
    }
}
