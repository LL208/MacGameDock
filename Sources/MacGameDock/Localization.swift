import Foundation
import Combine

enum InterfaceLanguage: String, CaseIterable {
    case system, italian = "it", english = "en"
    var title: String {
        switch self { case .system: return L10n.text("Automatico (lingua del Mac)"); case .italian: return "Italiano"; case .english: return "English" }
    }
    static func resolve(_ preference: String?, preferred: [String]) -> String {
        if preference == "it" || preference == "en" { return preference! }
        for language in preferred {
            let code = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
            if code == "it" || code == "en" { return code! }
        }
        return "en"
    }
}

final class AppLanguage: ObservableObject {
    static let shared = AppLanguage()
    private static let key = "MacGameDeck.interfaceLanguage"
    private let defaults: UserDefaults
    @Published private(set) var preference: InterfaceLanguage
    @Published private var systemRevision = 0
    private var notification: NSObjectProtocol?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preference = InterfaceLanguage(rawValue: defaults.string(forKey: Self.key) ?? "system") ?? .system
        notification = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.systemRevision += 1 }
    }
    deinit { if let notification { NotificationCenter.default.removeObserver(notification) } }
    var code: String { InterfaceLanguage.resolve(preference.rawValue, preferred: Locale.preferredLanguages) }
    var locale: Locale { Locale(identifier: code) }
    var steamLanguage: String { code == "it" ? "italian" : "english" }
    func select(_ value: InterfaceLanguage) { defaults.set(value.rawValue, forKey: Self.key); preference = value }
    func cycle() { let values = InterfaceLanguage.allCases; select(values[((values.firstIndex(of: preference) ?? 0) + 1) % values.count]) }
}

enum L10n {
    private static let cache: NSCache<NSString, NSString> = {
        let value = NSCache<NSString, NSString>(); value.countLimit = 1024; value.totalCostLimit = 1_048_576; return value
    }()
    static let english: [String: String] = {
        var roots: [URL] = []
        if let url = Bundle.main.resourceURL { roots += [url.appendingPathComponent("Resources"), url] }
        #if SWIFT_PACKAGE
        if let url = Bundle.module.resourceURL { roots += [url.appendingPathComponent("Resources"), url] }
        #endif
        for root in roots {
            if let bytes = try? Data(contentsOf: root.appendingPathComponent("Localization/en.json")), let values = try? JSONDecoder().decode([String: String].self, from: bytes) { return values }
        }
        return [:]
    }()
    private struct Template {
        let pattern: NSRegularExpression
        let output: String
        let tokens: [String]
    }
    private static let token = try! NSRegularExpression(pattern: #"\{\d+\}|%(?:\d+\$)?[-+0-9.]*[dfius@]"#)
    private static let templates: [Template] = english.keys.sorted { $0.count > $1.count }.compactMap { key in
        let matches = token.matches(in: key, range: NSRange(key.startIndex..., in: key))
        guard !matches.isEmpty else { return nil }
        // Never match arbitrary titles or user text with a placeholder-only key.
        let staticText = token.stringByReplacingMatches(in: key, range: NSRange(key.startIndex..., in: key), withTemplate: "")
        guard staticText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { return nil }
        var expression = "^", cursor = key.startIndex, tokens: [String] = []
        for match in matches {
            guard let range = Range(match.range, in: key) else { return nil }
            expression += NSRegularExpression.escapedPattern(for: String(key[cursor..<range.lowerBound])) + "(.+?)"
            tokens.append(String(key[range])); cursor = range.upperBound
        }
        expression += NSRegularExpression.escapedPattern(for: String(key[cursor...])) + "$"
        guard let regex = try? NSRegularExpression(pattern: expression, options: [.dotMatchesLineSeparators]), let output = english[key] else { return nil }
        return Template(pattern: regex, output: output, tokens: tokens)
    }
    static func text(_ source: String) -> String { translate(source, code: AppLanguage.shared.code) }
    static func translate(_ source: String, code: String) -> String {
        guard code == "en", !source.isEmpty else { return source }
        let key = source as NSString
        if let cached = cache.object(forKey: key) { return cached as String }
        let result = renderEnglish(source)
        if source.utf8.count < 4096 { cache.setObject(result as NSString, forKey: key, cost: source.utf8.count + result.utf8.count) }
        return result
    }
    private static let prefixes = english.keys.filter { $0.hasSuffix(": ") }.sorted { $0.count > $1.count }
    private static func renderEnglish(_ source: String) -> String {
        let code = "en"
        if let value = english[source] { return value }
        let preservedSaves = " Nessun salvataggio è stato modificato."
        if source.hasSuffix(preservedSaves), source != preservedSaves {
            return translate(String(source.dropLast(preservedSaves.count)), code: code) + (english[preservedSaves] ?? preservedSaves)
        }
        for template in templates {
            guard let match = template.pattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { continue }
            var output = template.output
            // Replace tokens in one pass so captured user text cannot be interpreted as a token.
            let matches = token.matches(in: output, range: NSRange(output.startIndex..., in: output))
            for replacement in matches.reversed() {
                guard let range = Range(replacement.range, in: output), let index = template.tokens.firstIndex(of: String(output[range])), let capture = Range(match.range(at: index + 1), in: source) else { continue }
                output.replaceSubrange(range, with: source[capture])
            }
            return output
        }
        // Composite labels use stable separators; translate each label, preserving data.
        for separator in ["\n", " · "] where source.contains(separator) {
            return source.components(separatedBy: separator).map { translate($0, code: code) }.joined(separator: separator)
        }
        for key in prefixes where source.hasPrefix(key) {
            return english[key]! + translate(String(source.dropFirst(key.count)), code: code)
        }
        return source
    }
}
