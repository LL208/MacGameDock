import XCTest
@testable import MacGameDock

final class DependencyAutomationTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func script(_ process: String, command: String = "", at folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func quote(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let text = "\"InstallScript\" { \"Run Process\" { \"4.0\" { \"process 1\" \(quote(process)) \"command 1\" \(quote(command)) } } }"
        try Data(text.utf8).write(to: folder.appendingPathComponent("installscript.vdf"))
    }
    func testSteamCmdWrapperResolvesExistingPayloadAndQuietArguments() throws {
        let root = try directory(), folder = root.appendingPathComponent("_CommonRedist/DotNet/4.0")
        try script("%INSTALLDIR%\\_CommonRedist\\DotNet\\4.0\\Microsoft .NET Framework 4.0.cmd", at: folder)
        try Data("@ECHO OFF\r\nstart /w \"\" \"%~dp0\\dotNetFx40_Full_x86_x64.exe\" /q /norestart\r\nIF %ERRORLEVEL% == 3010 EXIT /B 0\r\nEXIT /B %ERRORLEVEL%\r\n".utf8).write(to: folder.appendingPathComponent("Microsoft .NET Framework 4.0.cmd"))
        try Data().write(to: folder.appendingPathComponent("dotNetFx40_Full_x86_x64.exe"))
        let plan = try SteamDependencies.plan(in: root)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].executable.lastPathComponent, "dotNetFx40_Full_x86_x64.exe")
        XCTAssertEqual(plan[0].arguments, ["/q", "/norestart"])
        XCTAssertEqual(plan[0].wineArguments.first, SteamDependency.windowsPath(plan[0].executable))
        XCTAssertTrue(plan[0].name.contains("DotNet 4.0"))
        XCTAssertTrue(try SteamDependencies.missingGroups(plan).isEmpty)
        try FileManager.default.removeItem(at: plan[0].executable)
        XCTAssertEqual(try SteamDependencies.missingGroups(SteamDependencies.plan(in: root, allowMissing: true)), ["_CommonRedist/DotNet/4.0"])
    }
    func testXnaMsiexecMacroAndDependencyOrder() throws {
        let root = try directory(), xna = root.appendingPathComponent("_CommonRedist/XNA/4.0"), dotnet = root.appendingPathComponent("_CommonRedist/DotNet/4.0")
        try script("msiexec", command: "/i \"%INSTALLDIR%\\_CommonRedist\\XNA\\4.0\\xnafx40_redist.msi\" /quiet /norestart", at: xna)
        try Data().write(to: xna.appendingPathComponent("xnafx40_redist.msi"))
        try script("%INSTALLDIR%\\_CommonRedist\\DotNet\\4.0\\setup.exe", at: dotnet)
        try Data().write(to: dotnet.appendingPathComponent("setup.exe"))
        let plan = try SteamDependencies.plan(in: root)
        XCTAssertEqual(plan.count, 2)
        XCTAssertTrue(plan[0].name.contains("DotNet"))
        XCTAssertEqual(plan[1].wineArguments, ["msiexec", "/i", SteamDependency.windowsPath(xna.appendingPathComponent("xnafx40_redist.msi")), "/quiet", "/norestart"])
    }
    func testMissingPackagesAreFetchedByGroupAndCopiedWithoutReplacingScripts() throws {
        let root = try directory(), cache = try directory(), group = "_CommonRedist/vcredist/2022"
        let folder = root.appendingPathComponent(group)
        try script("%INSTALLDIR%\\_CommonRedist\\vcredist\\2022\\VC_redist.x64.exe", at: folder)
        let original = try Data(contentsOf: folder.appendingPathComponent("installscript.vdf"))
        let plan = try SteamDependencies.plan(in: root, allowMissing: true)
        XCTAssertEqual(try SteamDependencies.missingGroups(plan), [group])
        let cached = cache.appendingPathComponent("vcredist/2022")
        try FileManager.default.createDirectory(at: cached, withIntermediateDirectories: true)
        try Data("installer".utf8).write(to: cached.appendingPathComponent("VC_redist.x64.exe"))
        try Data("different".utf8).write(to: cached.appendingPathComponent("installscript.vdf"))
        try SteamDependencies.copyGroups([group], from: cache, to: root)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("installscript.vdf")), original)
        XCTAssertTrue(try SteamDependencies.missingGroups(SteamDependencies.plan(in: root)).isEmpty)
        let list = SteamDependencies.fileList(groups: [group])
        let expression = String(list.dropFirst("regex:".count)).trimmingCharacters(in: .newlines)
        let regex = try NSRegularExpression(pattern: expression, options: .caseInsensitive)
        for path in ["_CommonRedist/vcredist/2022/VC_redist.x64.exe", "vcredist/2022/VC_redist.x86.exe"] { XCTAssertNotNil(regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path))) }
        let unrelated = "DotNet/4.0/setup.exe"
        XCTAssertNil(regex.firstMatch(in: unrelated, range: NSRange(unrelated.startIndex..., in: unrelated)))
    }
    func testRejectsExternalMsiexecAndSymlinksInCachedRedists() throws {
        let root = try directory(), cache = try directory(), outside = try directory()
        try script("msiexec", command: "/i C:\\outside\\setup.msi", at: root)
        XCTAssertThrowsError(try SteamDependencies.plan(in: root, allowMissing: true))
        let group = "_CommonRedist/XNA/4.0", source = cache.appendingPathComponent(group)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertThrowsError(try SteamDependencies.copyGroups([group], from: cache, to: root))
    }
    @MainActor
    func testAutomaticFetchInstallRetryAndMarkersWithMockProcesses() async throws {
        let root = try directory(), id = "123"
        let prefix = root.appendingPathComponent("Containers/Steam/" + id + "/prefix")
        let gameDirectory = prefix.appendingPathComponent("drive_c/Program Files/MacGameDeck/Games/" + id)
        let redist = gameDirectory.appendingPathComponent("_CommonRedist/vcredist/2022")
        try script("%INSTALLDIR%\\_CommonRedist\\vcredist\\2022\\VC_redist.x64.exe", command: "/quiet /norestart", at: redist)
        try Data().write(to: gameDirectory.appendingPathComponent("game.exe"))
        let metadata = gameDirectory.appendingPathComponent(".MacGameDeck")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data(#"{"appID":123,"launches":[{"executable":"game.exe","oslist":"windows"}]}"#.utf8).write(to: metadata.appendingPathComponent("metadata.json"))
        let helper = root.appendingPathComponent("helper"), runtime = root.appendingPathComponent("runtime")
        let helperScript = #"""
        #!/bin/sh
        app=""; dir=""; list=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -app) app="$2"; shift;;
            -dir) dir="$2"; shift;;
            -filelist) list="$2"; shift;;
          esac
          shift
        done
        test -s account.config || exit 7
        if [ "$app" = "228980" ]; then
          test -s "$list" || exit 8
          mkdir -p "$dir/vcredist/2022"
          printf 'fixture' > "$dir/vcredist/2022/VC_redist.x64.exe"
        fi
        printf '%s\n' 'MACGAMEDECK_EVENT:{"type":"account","steamID":"76561198000000000","username":"fixture"}'
        """#
        let runtimeScript = #"""
        #!/bin/sh
        if [ "$1" = "wineboot" ]; then
          mkdir -p "$WINEPREFIX/drive_c/windows/system32"
          touch "$WINEPREFIX/system.reg" "$WINEPREFIX/user.reg" "$WINEPREFIX/drive_c/windows/system32/kernel32.dll"
        else
          test ! -f "$WINEPREFIX/fail-install" || exit 1
          printf '%s\n' "$1" "$2" "$3" >> "$WINEPREFIX/installed"
          pwd >> "$WINEPREFIX/installed"
        fi
        """#
        for (file, text) in [(helper, helperScript), (runtime, runtimeScript)] {
            try Data(text.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        try SessionStore.save(SteamSession(steamID: "76561198000000000", username: "fixture", account: Data("fixture".utf8)), root: root)
        let managed = ManagedSteam(root: root, helperProvider: { helper })
        let game = Game(id: UUID(), title: "Dependency test", store: .steam, executablePath: "", addedAt: Date(), steamAppID: 123)
        let failing = prefix.appendingPathComponent("fail-install")
        try Data().write(to: failing)
        do {
            _ = try await managed.install(game, runtime: runtime.path, expected: "76561198000000000")
            XCTFail("Installer failure must not become a completed installation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("vcredist")) }
        XCTAssertEqual(try SteamDependencies.plan(in: gameDirectory).count, 1)
        try FileManager.default.removeItem(at: failing)
        _ = try await managed.install(game, runtime: runtime.path, expected: "76561198000000000")
        XCTAssertTrue(try SteamDependencies.plan(in: gameDirectory).isEmpty)
        let installed = try String(contentsOf: prefix.appendingPathComponent("installed"), encoding: .utf8)
        XCTAssertTrue(installed.contains("VC_redist.x64.exe"))
        XCTAssertTrue(installed.contains("/quiet\n/norestart"))
        XCTAssertTrue(installed.contains("_CommonRedist/vcredist/2022"))
        _ = try await managed.install(game, runtime: runtime.path, expected: "76561198000000000")
        XCTAssertEqual(try String(contentsOf: prefix.appendingPathComponent("installed"), encoding: .utf8), installed)
    }

}
