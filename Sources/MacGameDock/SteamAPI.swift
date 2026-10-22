import Foundation
import Security

struct SteamOwnedGame: Decodable {
    let appid: Int
    let name: String?
    var platforms: [String]? = nil
    var familyOwners: [String]? = nil
    var steamMinutes: Int? = nil
    var steamAchievementsUnlocked: Int? = nil
    var steamAchievementsTotal: Int? = nil
    var iconHash: String? = nil
}

final class SteamNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct SteamAPI {
    private let session: URLSession
    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        self.session = session ?? URLSession(configuration: configuration, delegate: SteamNoRedirect(), delegateQueue: nil)
    }

    func ownedGames(steamID: String, key: String) async throws -> [SteamOwnedGame] {
        guard SteamOpenID.validSteamID(steamID) else { throw DockError.message("SteamID non valido.") }
        guard key.count == 32, key.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw DockError.message("La chiave Web API Steam deve contenere 32 caratteri esadecimali.")
        }
        var components = URLComponents(string: "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/")!
        let input: [String: Any] = ["steamid": steamID, "include_appinfo": true, "include_played_free_games": true]
        let json = String(data: try JSONSerialization.data(withJSONObject: input), encoding: .utf8)!
        components.queryItems = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "input_json", value: json)]
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            // Never surface a failing URL that may contain the API key.
            throw DockError.message("Connessione a Steam non riuscita. Controlla la rete e riprova.")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DockError.message("Steam ha rifiutato la richiesta. Verifica la chiave Web API e riprova.")
        }
        return try Self.decodeOwnedGames(data)
    }

    static func decodeOwnedGames(_ data: Data) throws -> [SteamOwnedGame] {
        struct Envelope: Decodable {
            struct Body: Decodable { let game_count: Int?; let games: [SteamOwnedGame]? }
            let response: Body
        }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw DockError.message("Steam ha restituito una risposta non valida. La libreria precedente è conservata.") }
        guard let count = envelope.response.game_count, count >= 0 else {
            throw DockError.message("Steam non ha reso disponibile la libreria. Controlla Privacy → Dettagli dei giochi nel tuo profilo Steam. Il login OpenID non concede accesso ai giochi privati.")
        }
        let games = envelope.response.games ?? []
        guard games.count == count, games.allSatisfy({ $0.appid > 0 }), Set(games.map(\.appid)).count == games.count else {
            throw DockError.message("La risposta della libreria Steam è incompleta. Il catalogo precedente è conservato.")
        }
        return games
    }

    func verifyOpenID(_ parameters: [String: String]) async throws {
        var values = parameters
        values["openid.mode"] = "check_authentication"
        var form = URLComponents()
        form.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: SteamOpenID.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let body = String(data: data, encoding: .utf8),
              body.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "is_valid:true" }) else {
            throw DockError.message("Steam non ha confermato la firma del login.")
        }
    }
}

enum SteamKeychain {
    private static let service = "com.macgamedock.steam-web-api"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "personal-api-key"]
    }
    static func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw DockError.message("Impossibile leggere la chiave Steam dal Portachiavi (\(status)).")
        }
        return value
    }
    static func save(_ value: String) throws {
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DockError.message("Impossibile salvare la chiave nel Portachiavi (\(status)).") }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DockError.message("Impossibile rimuovere la chiave dal Portachiavi (\(status)).")
        }
    }
}
