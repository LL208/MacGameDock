import Foundation
import XCTest
@testable import MacGameDock

private final class SteamMockProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.respond!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class SteamAPITests: XCTestCase {
    private func api() -> SteamAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SteamMockProtocol.self]
        return SteamAPI(session: URLSession(configuration: config))
    }
    override func tearDown() { SteamMockProtocol.respond = nil; super.tearDown() }

    func testOwnedGamesRequestsWholeCatalogWithAppNamesAndPlayedFreeGames() async throws {
        SteamMockProtocol.respond = { request in
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "api.steampowered.com")
            XCTAssertEqual(request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), "IPlayerService/GetOwnedGames/v1")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first(where: { $0.name == "key" })?.value, String(repeating: "A", count: 32))
            let input = items.first(where: { $0.name == "input_json" })!.value!
            let json = try JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any]
            XCTAssertEqual(json["steamid"] as? String, "76561198000000000")
            XCTAssertEqual(json["include_appinfo"] as? Bool, true)
            XCTAssertEqual(json["include_played_free_games"] as? Bool, true)
            XCTAssertNil(json["appids_filter"])
            return (200, Data(#"{"response":{"game_count":2,"games":[{"appid":10,"name":"One"},{"appid":20,"name":"Two"}]}}"#.utf8))
        }
        let games = try await api().ownedGames(steamID: "76561198000000000", key: String(repeating: "A", count: 32))
        XCTAssertEqual(games.map(\.appid), [10, 20])
    }

    func testOpenIDPostsVerificationAndDoesNotTrustLocalIdentityAlone() async throws {
        SteamMockProtocol.respond = { request in
            XCTAssertEqual(request.url, SteamOpenID.endpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            // Decode as a web form would: '+' is a space unless percent-escaped.
            let pairs = body.split(separator: "&").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
            let fields = Dictionary(uniqueKeysWithValues: pairs.compactMap { pair -> (String, String)? in
                guard pair.count == 2 else { return nil }
                return (pair[0].removingPercentEncoding ?? "", pair[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "")
            })
            XCTAssertEqual(fields["openid.mode"], "check_authentication")
            XCTAssertEqual(fields["openid.sig"], "a+b/c")
            return (200, Data("ns:http://specs.openid.net/auth/2.0\nis_valid:true\n".utf8))
        }
        try await api().verifyOpenID(["openid.mode": "id_res", "openid.sig": "a+b/c"])
    }

    func testOpenIDInvalidSignatureFails() async {
        SteamMockProtocol.respond = { _ in (200, Data("is_valid:false\n".utf8)) }
        do {
            try await api().verifyOpenID(["openid.mode": "id_res"])
            XCTFail("Invalid Steam signature must fail")
        } catch {}
    }

    func testAPIErrorDoesNotExposeAPIKey() async {
        let key = String(repeating: "B", count: 32)
        SteamMockProtocol.respond = { request in
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                          userInfo: [NSLocalizedDescriptionKey: request.url!.absoluteString])
        }
        do {
            _ = try await api().ownedGames(steamID: "76561198000000000", key: key)
            XCTFail("Network error must fail")
        } catch { XCTAssertFalse(error.localizedDescription.contains(key)) }
    }
}
