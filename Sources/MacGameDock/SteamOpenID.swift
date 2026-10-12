import Foundation

enum SteamOpenID {
    static let endpoint = URL(string: "https://steamcommunity.com/openid/login")!
    static let namespace = "http://specs.openid.net/auth/2.0"
    static let identifierSelect = "http://specs.openid.net/auth/2.0/identifier_select"

    static func loginURL(returnTo: URL) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let realm = "http://127.0.0.1:\(returnTo.port!)/"
        components.queryItems = [
            URLQueryItem(name: "openid.ns", value: namespace),
            URLQueryItem(name: "openid.mode", value: "checkid_setup"),
            URLQueryItem(name: "openid.return_to", value: returnTo.absoluteString),
            URLQueryItem(name: "openid.realm", value: realm),
            URLQueryItem(name: "openid.identity", value: identifierSelect),
            URLQueryItem(name: "openid.claimed_id", value: identifierSelect)
        ]
        return components.url!
    }

    static func validSteamID(_ value: String) -> Bool {
        value.count == 17 && value.allSatisfy({ $0.isASCII && $0.isNumber }) && UInt64(value) != nil
    }

    /// Local checks complement, but never replace, Steam's check_authentication call.
    static func validate(callback: URL, expectedReturnTo: URL, startedAt: Date, now: Date = Date()) throws -> (String, [String: String]) {
        guard callback.scheme == expectedReturnTo.scheme, callback.host == expectedReturnTo.host,
              callback.port == expectedReturnTo.port, callback.path == expectedReturnTo.path,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw DockError.message("Callback Steam non valido.")
        }
        var values: [String: String] = [:]
        for item in items {
            guard let value = item.value, values[item.name] == nil else { throw DockError.message("Parametri Steam duplicati o incompleti.") }
            values[item.name] = value
        }
        if values["openid.mode"] == "cancel" { throw DockError.message("Accesso Steam annullato.") }
        guard values["openid.ns"] == namespace, values["openid.mode"] == "id_res",
              values["openid.op_endpoint"] == endpoint.absoluteString,
              values["openid.return_to"] == expectedReturnTo.absoluteString,
              let claimed = values["openid.claimed_id"], values["openid.identity"] == claimed,
              let url = URLComponents(string: claimed), ["http", "https"].contains(url.scheme ?? ""),
              url.host == "steamcommunity.com", url.port == nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw DockError.message("Identità Steam non valida.") }
        let parts = url.path.split(separator: "/")
        guard parts.count == 3, parts[0] == "openid", parts[1] == "id", validSteamID(String(parts[2])),
              url.path == "/openid/id/\(parts[2])" else { throw DockError.message("SteamID restituito non valido.") }
        let signed = Set((values["openid.signed"] ?? "").split(separator: ",").map(String.init))
        let mandatory: Set<String> = ["op_endpoint", "claimed_id", "identity", "return_to", "response_nonce", "assoc_handle"]
        guard mandatory.isSubset(of: signed), !(values["openid.sig"] ?? "").isEmpty,
              !(values["openid.assoc_handle"] ?? "").isEmpty,
              let nonce = values["openid.response_nonce"], nonce.count > 20 else {
            throw DockError.message("Firma Steam incompleta.")
        }
        let formatter = ISO8601DateFormatter()
        guard let timestamp = formatter.date(from: String(nonce.prefix(20))),
              timestamp >= startedAt.addingTimeInterval(-30), abs(now.timeIntervalSince(timestamp)) <= 300 else {
            throw DockError.message("La risposta Steam è scaduta. Ripeti l'accesso.")
        }
        return (String(parts[2]), values.filter { $0.key.hasPrefix("openid.") })
    }
}
