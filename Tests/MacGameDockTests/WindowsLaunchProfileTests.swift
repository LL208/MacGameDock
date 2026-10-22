import XCTest
@testable import MacGameDock

final class WindowsLaunchProfileTests: XCTestCase {
    func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func pe() -> Data {
        var data = Data(repeating: 0, count: 128)
        data[0] = 0x4d; data[1] = 0x5a; data[60] = 64
        data.replaceSubrange(64..<70, with: [0x50, 0x45, 0, 0, 0x64, 0x86])
        return data
    }
    func bootstrap(target: String, arguments: String = "Project") -> Data {
        var data = Data(repeating: 0, count: 2048)
        func put(_ value: Int, at: Int, width: Int = 4) { for i in 0..<width { data[at + i] = UInt8((value >> (8 * i)) & 255) } }
        data.replaceSubrange(0..<128, with: pe())
        put(1, at: 70, width: 2); put(240, at: 84, width: 2); put(0x20b, at: 88, width: 2)
        put(0x1000, at: 216)
        put(0x600, at: 336); put(0x1000, at: 340); put(0x600, at: 344); put(512, at: 348)
        put(1, at: 526, width: 2); put(10, at: 528); put(0x80000020, at: 532)
        put(2, at: 558, width: 2); put(201, at: 560); put(0x80000050, at: 564); put(202, at: 568); put(0x80000070, at: 572)
        put(1, at: 606, width: 2); put(1033, at: 608); put(0x90, at: 612)
        put(1, at: 638, width: 2); put(1033, at: 640); put(0xa0, at: 644)
        let path = (target + "\0").data(using: .utf16LittleEndian)!, args = (arguments + "\0").data(using: .utf16LittleEndian)!
        put(0x1100, at: 656); put(path.count, at: 660); put(0x1300, at: 672); put(args.count, at: 676)
        data.replaceSubrange(768..<768 + path.count, with: path)
        data.replaceSubrange(1280..<1280 + args.count, with: args)
        let marker = "BootstrapPackagedGame-Win64-Shipping.exe".data(using: .utf16LittleEndian)!
        data.replaceSubrange(1800..<1800 + marker.count, with: marker)
        return data
    }
    func testDeclaredUnrealTargetArgumentsAndWorkingDirectoryArePreserved() throws {
        let root = try directory(), exe = root.appendingPathComponent("Bootstrap.exe"), child = root.appendingPathComponent("Project/Binaries/Win64/Main.exe")
        try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (pe() + Data("D3D12RHI".utf8)).write(to: child)
        try bootstrap(target: "Project\\Binaries\\Win64\\Main.exe", arguments: #"Project "two words""#).write(to: exe)
        let plan = try WindowsGameLaunch.resolve(executable: exe, directory: root, arguments: ["-flag"], workingDirectory: root)
        XCTAssertTrue(plan.bypassedBootstrapper)
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: plan.executable.path, andPath: child.path))
        XCTAssertEqual(plan.arguments, ["Project", "two words", "-flag"])
        XCTAssertEqual(plan.workingDirectory, root)
        XCTAssertTrue(plan.usesDirectX12)
    }
    func testMissingTargetTraversalCorruptResourcesAndSymlinksAreRejected() throws {
        let root = try directory(), exe = root.appendingPathComponent("Bootstrap.exe")
        for target in ["../outside.exe", "Z:\\outside.exe", "Missing.exe"] {
            try bootstrap(target: target).write(to: exe)
            XCTAssertThrowsError(try WindowsGameLaunch.resolve(executable: exe, directory: root, arguments: [], workingDirectory: root))
        }
        let external = try directory(), child = external.appendingPathComponent("Game.exe")
        try pe().write(to: child)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: external)
        try bootstrap(target: "linked\\Game.exe").write(to: exe)
        XCTAssertThrowsError(try WindowsGameLaunch.resolve(executable: exe, directory: root, arguments: [], workingDirectory: root))
        var corrupt = bootstrap(target: "Game.exe"); corrupt[532] = 255; corrupt[533] = 255; corrupt[534] = 255
        try corrupt.write(to: exe)
        XCTAssertThrowsError(try WindowsGameLaunch.resolve(executable: exe, directory: root, arguments: [], workingDirectory: root))
    }
    func testOrdinaryGamesKeepOriginalLaunchAndWineErrorsAreNotSuppressed() throws {
        let root = try directory(), exe = root.appendingPathComponent("Game.exe")
        try pe().write(to: exe)
        let plan = try WindowsGameLaunch.resolve(executable: exe, directory: root, arguments: ["-test"], workingDirectory: root)
        XCTAssertFalse(plan.bypassedBootstrapper); XCTAssertEqual(plan.executable, exe); XCTAssertEqual(plan.arguments, ["-test"])
        let environment = WineRuntime.environment(prefix: root, runtime: "/custom/wine", base: ["CUSTOM": "preserved"])
        XCTAssertEqual(environment["WINEDEBUG"], "-all,err+all"); XCTAssertEqual(environment["CUSTOM"], "preserved")
        XCTAssertNil(environment["ROSETTA_ADVERTISE_AVX"])
    }
    func testCrossOverEnvironmentAddsLibrariesAVXAndPreservesExplicitDisable() throws {
        let root = try directory(), runtime = root.appendingPathComponent("lib/wine/x86_64-unix/wine").path
        let gptk = root.appendingPathComponent("lib64/apple_gptk")
        for relative in ["external/libd3dshared.dylib", "wine/x86_64-windows/d3d12.dll"] {
            let file = gptk.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let env = WineRuntime.environment(prefix: root, runtime: runtime, directX12: true, base: ["WINEDLLOVERRIDES": "steam_api64=n,b"])
        XCTAssertEqual(env["ROSETTA_ADVERTISE_AVX"], "1")
        XCTAssertTrue(env["WINEDLLPATH"]?.contains("apple_gptk/wine") == true)
        XCTAssertTrue(env["WINEDLLOVERRIDES"]?.contains("steam_api64=n,b") == true)
        XCTAssertTrue(env["WINEDLLOVERRIDES"]?.contains("d3d11,d3d12,dxgi=b") == true)
        XCTAssertEqual(env["CX_APPLEGPTK_LIBD3DSHARED_PATH"], gptk.appendingPathComponent("external/libd3dshared.dylib").path)
        let off = WineRuntime.environment(prefix: root, runtime: runtime, base: ["ROSETTA_ADVERTISE_AVX": "0"])
        XCTAssertNil(off["ROSETTA_ADVERTISE_AVX"])
        XCTAssertFalse(off["WINEDLLPATH"]?.contains("apple_gptk/wine") == true)
    }
    func testRealDenshattackLaunchPlanReadOnly() throws {
        guard let path = ProcessInfo.processInfo.environment["MACGAMEDECK_VERIFY_GAME"] else { throw XCTSkip("Verifica reale eseguita solo con cartella esplicita.") }
        let root = URL(fileURLWithPath: path)
        let plan = try WindowsGameLaunch.resolve(executable: root.appendingPathComponent("Denshattack_Proto.exe"), directory: root, arguments: [], workingDirectory: root)
        XCTAssertTrue(plan.bypassedBootstrapper)
        XCTAssertEqual(plan.executable.lastPathComponent, "Denshattack_Proto-Win64-Shipping.exe")
        XCTAssertEqual(plan.arguments, ["Denshattack_Proto"])
        XCTAssertTrue(plan.usesDirectX12)
        let env = WineRuntime.environment(prefix: root, runtime: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/wine", directX12: true)
        XCTAssertTrue(env["WINEDLLPATH"]?.contains("apple_gptk") == true)
        XCTAssertNotNil(env["CX_APPLEGPTK_LIBD3DSHARED_PATH"])
    }
}
