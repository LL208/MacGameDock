import XCTest
@testable import MacGameDock

enum VisualCPPFixture {
    static func write(to prefix: URL, architecture: String = "x64", minor: UInt32 = 51, installed: Bool = true) throws {
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let section = "Software\\\\Wow6432Node\\\\Microsoft\\\\VisualStudio\\\\14.0\\\\VC\\\\Runtimes\\\\" + architecture
        let registry = "[" + section + "] 0\n\"Installed\"=dword:" + (installed ? "00000001" : "00000000") + "\n\"Major\"=dword:0000000e\n\"Minor\"=dword:" + String(format: "%08x", minor) + "\n\"Bld\"=dword:00008d97\n"
        let file = prefix.appendingPathComponent("system.reg")
        let old = (try? String(contentsOf: file)) ?? ""
        try Data((old + "\n" + registry).utf8).write(to: file)
        var data = Data(repeating: 0, count: 256)
        data[0] = 0x4d; data[1] = 0x5a; data[60] = 64
        data.replaceSubrange(64..<70, with: [0x50, 0x45, 0, 0, architecture == "x64" ? 0x64 : 0x4c, architecture == "x64" ? 0x86 : 0x01])
        data.replaceSubrange(128..<132, with: [0xbd, 0x04, 0xef, 0xfe])
        var version = (UInt32(14) << 16 | minor).littleEndian
        withUnsafeBytes(of: &version) { data.replaceSubrange(136..<140, with: $0) }
        for dll in WindowsPrerequisites.dlls(prefix, architecture) {
            try FileManager.default.createDirectory(at: dll.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dll)
        }
    }
}
@MainActor
final class ComponentDiagnosticsTests: XCTestCase {
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testAlreadyInstalledNewerVisualCPPIsRecognizedWithoutReceiptOrDowngrade() throws {
        let prefix = try root()
        try VisualCPPFixture.write(to: prefix)
        XCTAssertTrue(WindowsPrerequisites.isReady(prefix: prefix, architecture: "x64"))
        XCTAssertEqual(WindowsPrerequisites.registeredVersion(prefix: prefix, architecture: "x64")?.prefix(2), [14, 51])
        try VisualCPPFixture.write(to: prefix, architecture: "x86")
        XCTAssertTrue(WindowsPrerequisites.isReady(prefix: prefix, architecture: "x86"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows/syswow64/vcruntime140_1.dll").path))
    }
    func testOldUnregisteredWrongArchitectureOrMissingDLLsCannotBeAccepted() throws {
        let old = try root(), unregistered = try root(), damaged = try root()
        try VisualCPPFixture.write(to: old, minor: 28)
        try VisualCPPFixture.write(to: unregistered, installed: false)
        try VisualCPPFixture.write(to: damaged)
        XCTAssertFalse(WindowsPrerequisites.isReady(prefix: old, architecture: "x64"))
        XCTAssertFalse(WindowsPrerequisites.isReady(prefix: unregistered, architecture: "x64"))
        XCTAssertFalse(WindowsPrerequisites.isReady(prefix: damaged, architecture: "x86"))
        try FileManager.default.removeItem(at: WindowsPrerequisites.dlls(damaged, "x64")[0])
        XCTAssertFalse(WindowsPrerequisites.installedAndCompatible(prefix: damaged, architecture: "x64"))
    }
    func testLogsAreBoundedRedactedAndSurviveReload() throws {
        let root = try root(), log = AppDiagnostics(root: root)
        log.write("Test", "password=secret access_token=private token=hidden status=102")
        let text = try AppDiagnostics.tail(log.file)
        XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("private")); XCTAssertFalse(text.contains("hidden"))
        XCTAssertTrue(text.contains("status=102"))
        let privateJSON = AppDiagnostics.redact(#"{"access_token":"private-value", "password":"secret-value"} Authorization: Bearer private-header"#)
        XCTAssertFalse(privateJSON.contains("private-value")); XCTAssertFalse(privateJSON.contains("secret-value")); XCTAssertFalse(privateJSON.contains("private-header"))
        try Data(repeating: 65, count: 1_000_001).write(to: log.file)
        XCTAssertLessThanOrEqual(try AppDiagnostics.tail(log.file, limit: 100).count, 150)
        log.write("Trofei", "Evento confermato")
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.file.deletingLastPathComponent().appendingPathComponent("application.previous.log").path))
        XCTAssertTrue(try AppDiagnostics.tail(log.file).contains("Evento confermato"))
    }
    func testInstalledUserPrefixReadOnlyWhenExplicitlyProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["MACGAMEDECK_VERIFY_PREFIX"] else { throw XCTSkip("Controllo del container reale eseguito solo su percorso esplicito.") }
        let prefix = URL(fileURLWithPath: path)
        XCTAssertTrue(WindowsPrerequisites.isReady(prefix: prefix, architecture: "x64"))
        XCTAssertTrue(WindowsPrerequisites.isReady(prefix: prefix, architecture: "x86"))
    }
}

extension ComponentDiagnosticsTests {
    func testVisualCPPWaitsForDelayedRegistryAndDLLs() async throws {
        let prefix = try root()
        let writer = Task { @MainActor in
            try await Task.sleep(nanoseconds: 100_000_000)
            try VisualCPPFixture.write(to: prefix)
        }
        try await WindowsPrerequisites.waitUntilInstalled(prefix: prefix, architecture: "x64", timeout: 2)
        try await writer.value
        let missing = try root()
        do {
            try await WindowsPrerequisites.waitUntilInstalled(prefix: missing, architecture: "x64", timeout: 0)
            XCTFail("A missing runtime must fail validation")
        } catch { XCTAssertFalse(WindowsPrerequisites.installedAndCompatible(prefix: missing, architecture: "x64")) }
    }
}

extension ComponentDiagnosticsTests {
    func testMigratedContainerReadOnlyWhenExplicitlyProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["MACGAMEDECK_VERIFY_MIGRATED_PREFIX"] else { throw XCTSkip("Container migrato reale solo su percorso esplicito") }
        let prefix = URL(fileURLWithPath: path)
        XCTAssertTrue(WindowsPrerequisites.installedAndCompatible(prefix: prefix, architecture: "x64"))
        XCTAssertEqual(try SteamCloudRestore.wineUser(prefix: prefix).lastPathComponent, "builduser")
    }
}

extension ComponentDiagnosticsTests {
    func testEngineMigrationBacksUpWineModulesAndPreservesNativeDLLs() throws {
        let root = try root(), prefix = root.appendingPathComponent("prefix"), wine = root.appendingPathComponent("wine"), backup = root.appendingPathComponent("backup")
        let source = wine.appendingPathComponent("lib/wine/x86_64-windows"), target = prefix.appendingPathComponent("drive_c/windows/system32")
        for folder in [source, target, backup] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        func dll(_ value: UInt8, builtin: Bool = true) -> Data {
            var bytes = Data(repeating: value, count: 256)
            bytes[0] = 0x4d; bytes[1] = 0x5a
            if builtin { bytes.replaceSubrange(64..<81, with: Data("Wine builtin DLL\0".utf8)) }
            return bytes
        }
        try dll(1).write(to: target.appendingPathComponent("ntdll.dll"))
        try dll(2).write(to: source.appendingPathComponent("ntdll.dll"))
        try dll(3, builtin: false).write(to: target.appendingPathComponent("vcruntime140.dll"))
        try dll(4).write(to: source.appendingPathComponent("vcruntime140.dll"))
        XCTAssertEqual(try WinePrefixMigration.refresh(prefix: prefix, wine: wine, backup: backup), 1)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("ntdll.dll")), dll(2))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("vcruntime140.dll")), dll(3, builtin: false))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("drive_c/windows/system32/ntdll.dll")), dll(1))
    }
}
