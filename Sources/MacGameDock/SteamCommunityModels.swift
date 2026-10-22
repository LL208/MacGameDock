import Foundation

struct SteamAchievement: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let title: String
    let description: String
    let icon: String?
    let iconGray: String?
    let hidden: Bool
    var unlocked: Bool
    var unlockTime: UInt32
    let statID: UInt32
    let bit: Int
    var displayTitle: String { hidden && !unlocked ? "Trofeo nascosto" : (title.isEmpty ? name : title) }
    var displayDescription: String { hidden && !unlocked ? "Continua a giocare per scoprirlo." : description }
    var imageURL: URL? { SteamImageURL.make(unlocked ? icon : iconGray) }
}
enum SteamImageURL {
    static func make(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme == "https", let host = url.host,
              host == "avatars.steamstatic.com" || host.hasSuffix(".steamstatic.com") || host.hasSuffix(".steamusercontent.com") || host.hasSuffix(".akamaihd.net") || host == "steamusercontent.com" else { return nil }
        return url
    }
}
struct SteamAchievementSnapshot: Codable {
    struct Stat: Codable { let name: String; let type: String; let defaultValue: String }
    let steamID: String
    let appID: Int
    var achievements: [SteamAchievement]
    let stats: [Stat]
    func validate(owner: String, appID: Int) throws {
        guard steamID == owner, self.appID == appID, achievements.count <= 10000,
              Set(achievements.map(\.name)).count == achievements.count,
              achievements.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 256 && (0..<32).contains($0.bit) }) else { throw DockError.message("Schema dei trofei non valido o appartenente a un altro account.") }
    }
}
struct SteamWorkshopItem: Decodable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let preview: String?
    let subscriptions: UInt64
    var previewURL: URL? { SteamImageURL.make(preview) }
}
struct SteamWorkshopPage: Decodable {
    let steamID: String
    let appID: Int
    let total: Int
    let page: Int
    let items: [SteamWorkshopItem]
}
enum SteamPersona: Int, Codable, CaseIterable, Identifiable {
    case offline = 0, online, busy, away, snooze, trade, play, invisible
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .offline: return "Offline"
        case .online: return "Online"
        case .busy: return "Occupato"
        case .away: return "Assente"
        case .snooze: return "Non al computer"
        case .trade: return "Disponibile per scambi"
        case .play: return "Disponibile per giocare"
        case .invisible: return "Invisibile"
        }
    }
}
struct SteamPersonaProfile: Decodable {
    let steamID: String
    let name: String?
    let avatar: String?
    let state: Int
    let blocked: Bool
    var imageURL: URL? { SteamImageURL.make(avatar) }
    var persona: SteamPersona { SteamPersona(rawValue: state) ?? .offline }
}
