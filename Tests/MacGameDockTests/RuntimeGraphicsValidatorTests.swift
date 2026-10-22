import XCTest
@testable import MacGameDock

enum MetalExportFixture {
    static func module(symbol: String = "_macdrv_functions", flags: UInt8 = 0) -> Data {
        let edge = Array(symbol.utf8)
        let trie = Data([0, 1] + edge + [0, UInt8(edge.count + 4), 2, flags, 1, 0])
        var data = Data(repeating: 0, count: 48)
        func put(_ offset: Int, _ value: UInt32) {
            for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        put(0, 0xfeedfacf); put(16, 1); put(20, 16)
        put(32, 0x80000033); put(36, 16); put(40, 48); put(44, UInt32(trie.count))
        data.append(trie); return data
    }
}
final class RuntimeGraphicsValidatorTests: XCTestCase {
    func testOnlyDynamicExportsCountNotStringsOrReexports() throws {
        XCTAssertEqual(try RuntimeGraphicsValidator.exports(MetalExportFixture.module()), ["_macdrv_functions"])
        XCTAssertTrue(try RuntimeGraphicsValidator.exports(MetalExportFixture.module(flags: 8)).isEmpty)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try MetalExportFixture.module().write(to: file)
        XCTAssertNoThrow(try RuntimeGraphicsValidator.validate(file))
        var incompatible = MetalExportFixture.module(symbol: "_unrelated")
        incompatible.append(Data("_macdrv_functions".utf8))
        try incompatible.write(to: file)
        XCTAssertThrowsError(try RuntimeGraphicsValidator.validate(file))
        XCTAssertThrowsError(try RuntimeGraphicsValidator.exports(Data([0, 1, 2])))
        var malformed = MetalExportFixture.module(); malformed[40] = 255
        XCTAssertThrowsError(try RuntimeGraphicsValidator.exports(malformed))
    }
}

extension RuntimeGraphicsValidatorTests {
    func testPreviousIncompatibleWineModuleIsRejectedReadOnly() throws {
        guard let path = ProcessInfo.processInfo.environment["MACGAMEDECK_VERIFY_OLD_GRAPHICS"] else { throw XCTSkip("Modulo Wine precedente solo su percorso esplicito") }
        XCTAssertThrowsError(try RuntimeGraphicsValidator.validate(URL(fileURLWithPath: path)))
    }
}
