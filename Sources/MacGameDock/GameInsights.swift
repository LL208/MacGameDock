import Foundation

struct GameInsights: Codable {
    var description = ""
    var longDescription = ""
    var developers: [String] = []
    var genres: [String] = []
    var categories: Set<Int>? = nil
    var singlePlayer: Bool? { categories.map { $0.contains(2) } }
    var localCoop: Bool? { categories.map { $0.contains(39) } }
    var localSharedScreen: Bool? { categories.map { !$0.isDisjoint(with: [24, 37, 39]) } }
    var onlineMultiplayer: Bool? { categories.map { !$0.isDisjoint(with: [36, 38]) } }
    let macAvailable: Bool
    let windowsAvailable: Bool
    let macRequirements: String
    let windowsRequirements: String
    static func plain(_ value: String) -> String {
        value.replacingOccurrences(of: "(?i)<br\\s*/?>|</li>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "’").replacingOccurrences(of: "&#039;", with: "’")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
    func requirement(_ label: String, for platform: InstallPlatform) -> String? {
        let text = Self.plain(platform == .macOS ? macRequirements : windowsRequirements)
        let escaped = NSRegularExpression.escapedPattern(for: label)
        guard let regex = try? NSRegularExpression(pattern: "(?i)" + escaped + ":\\s*([^\n]+)"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return text[range].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func minimumRAM(for platform: InstallPlatform) -> Int? {
        let text = Self.plain(platform == .macOS ? macRequirements : windowsRequirements)
        let regex = try! NSRegularExpression(pattern: #"(?i)(?:memory|memoria)\s*:\s*(\d+(?:[.,]\d+)?)\s*(GB|MB)"#)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let number = Range(match.range(at: 1), in: text), let unit = Range(match.range(at: 2), in: text),
              let amount = Double(text[number].replacingOccurrences(of: ",", with: ".")) else { return nil }
        return Int(ceil(text[unit].uppercased() == "MB" ? amount / 1024 : amount))
    }
    static func decode(_ data: Data, appID: Int) throws -> GameInsights {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = json[String(appID)] as? [String: Any], entry["success"] as? Bool == true,
              let body = entry["data"] as? [String: Any], let platforms = body["platforms"] as? [String: Bool] else {
            throw DockError.message("Informazioni dello store non disponibili.")
        }
        let mac = (body["mac_requirements"] as? [String: Any])?["minimum"] as? String ?? ""
        let windows = (body["pc_requirements"] as? [String: Any])?["minimum"] as? String ?? ""
        var result = GameInsights(macAvailable: platforms["mac"] == true, windowsAvailable: platforms["windows"] == true,
                            macRequirements: mac, windowsRequirements: windows)
        let short = body["short_description"] as? String ?? ""
        result.description = String(plain(short.isEmpty ? (body["about_the_game"] as? String ?? "") : short).trimmingCharacters(in: .whitespacesAndNewlines).prefix(6000))
        result.longDescription = String(plain(body["about_the_game"] as? String ?? body["detailed_description"] as? String ?? short).trimmingCharacters(in: .whitespacesAndNewlines).prefix(18000))
        result.developers = body["developers"] as? [String] ?? []
        result.genres = (body["genres"] as? [[String: Any]] ?? []).compactMap { $0["description"] as? String }
        result.categories = (body["categories"] as? [[String: Any]]).map { Set($0.compactMap { $0["id"] as? Int }) }
        return result
    }
    static func fetch(appID: Int, language: String = "english") async throws -> GameInsights {
        let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&l=\(language == "italian" ? "italian" : "english")")!
        var request = URLRequest(url: url); request.timeoutInterval = 20
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, bytes.count < 8_000_000 else { throw DockError.message("Informazioni dello store non disponibili.") }
        return try decode(bytes, appID: appID)
    }
}
struct PerformanceEstimate {
    let minimumRAM: Int?
    let suggestedRAM: Int?
    let memoryStatus: String
    let startingResolution: String
    let confidence: String
    init(machine: Machine, platform: InstallPlatform, insights: GameInsights?) {
        minimumRAM = insights?.minimumRAM(for: platform)
        suggestedRAM = minimumRAM.map { $0 + (platform == .windows ? 2 : 0) }
        if let suggestedRAM {
            memoryStatus = machine.memoryGB >= suggestedRAM + 4 ? "Margine RAM disponibile" :
                (machine.memoryGB >= suggestedRAM ? "RAM al limite: chiudi le altre app" : "RAM sotto la stima consigliata")
        } else { memoryStatus = "Requisiti RAM non disponibili" }
        startingResolution = machine.memoryGB <= 8 && platform == .windows ? "1280 × 720 · qualità bassa" : "1920 × 1080 · qualità bassa"
        confidence = "Stima prudente, non misurata. La RAM non determina da sola gli FPS."
    }
}
