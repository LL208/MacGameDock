import XCTest
@testable import MacGameDock

final class LocalizationTests: XCTestCase {
    func testSystemLanguageUsesPreferredSupportedLanguageAndEnglishFallback() {
        XCTAssertEqual(InterfaceLanguage.resolve(nil, preferred: ["it-IT", "en-US"]), "it")
        XCTAssertEqual(InterfaceLanguage.resolve("system", preferred: ["en_GB", "it"]), "en")
        XCTAssertEqual(InterfaceLanguage.resolve(nil, preferred: ["fr-FR", "it-CH"]), "it")
        XCTAssertEqual(InterfaceLanguage.resolve(nil, preferred: ["de-DE"]), "en")
        XCTAssertEqual(InterfaceLanguage.resolve("bad-value", preferred: []), "en")
        XCTAssertEqual(InterfaceLanguage.resolve("it", preferred: ["en"]), "it")
        XCTAssertEqual(InterfaceLanguage.resolve("en", preferred: ["it"]), "en")
    }
    func testChoicePersistsWithoutChangingSystemLanguages() {
        let name = "MacGameDeck.LocalizationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let system = Locale.preferredLanguages
        let settings = AppLanguage(defaults: defaults)
        XCTAssertEqual(settings.preference, .system)
        settings.select(.english)
        XCTAssertEqual(AppLanguage(defaults: defaults).preference, .english)
        settings.cycle()
        XCTAssertEqual(AppLanguage(defaults: defaults).preference, .system)
        XCTAssertEqual(Locale.preferredLanguages, system)
        XCTAssertNil(defaults.persistentDomain(forName: name)?["AppleLanguages"])
    }
    func testBundledCatalogAndDynamicMessagesPreserveValues() {
        XCTAssertGreaterThan(L10n.english.count, 500)
        XCTAssertEqual(L10n.translate("Impostazioni", code: "en"), "Settings")
        XCTAssertEqual(L10n.translate("Impostazioni", code: "it"), "Impostazioni")
        XCTAssertEqual(L10n.translate("Pagina 2 di 12", code: "en"), "Page 2 of 12")
        XCTAssertEqual(L10n.translate("6.5 ore su Steam", code: "en"), "6.5 hours on Steam")
        XCTAssertEqual(L10n.translate("Tema desktop: Scuro", code: "en"), "Desktop theme: Dark")
        XCTAssertEqual(L10n.translate("Cruelty Squad", code: "en"), "Cruelty Squad")
        XCTAssertEqual(L10n.translate("/Users/player/Salvataggi", code: "en"), "/Users/player/Salvataggi")
        XCTAssertEqual(L10n.translate("8 file nel cloud", code: "en"), "8 cloud files")
    }
    func testCatalogPreservesTemplateTokens() throws {
        let regex = try NSRegularExpression(pattern: #"\{\d+\}|%(?:\d+\$)?[-+0-9.]*[dfius@]"#)
        func tokens(_ value: String) -> [String] { regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { Range($0.range, in: value).map { String(value[$0]) } }.sorted() }
        for (key, value) in L10n.english { XCTAssertEqual(tokens(key), tokens(value), key) }
    }
}
