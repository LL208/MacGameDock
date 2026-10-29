import XCTest
@testable import MacGameDock

final class ArtworkPolicyTests: XCTestCase {
    func testRejectsUntrustedAssetOriginsAndSelectsSafeHighestScore() throws {
        let data = Data(#"[{"id":1,"score":1000,"url":"https://cdn.steamgriddb.com.evil.test/image.png"},{"id":2,"score":100,"url":"https://cdn2.steamgriddb.com/a.png","nsfw":true},{"id":3,"score":50,"url":"https://cdn2.steamgriddb.com/b.png","humor":true},{"id":4,"score":10,"url":"https://cdn2.steamgriddb.com/c.png","author":{"name":"Artist"}},{"id":5,"score":5,"url":"https://cdn2.steamgriddb.com/d.png"}]"#.utf8)
        let images = try JSONDecoder().decode([GridDBImage].self, from: data)
        XCTAssertEqual(ArtworkPolicy.best(images)?.id, 4)
        for value in ["http://cdn2.steamgriddb.com/a.png", "file:///tmp/image.png", "https://secret@cdn2.steamgriddb.com/a.png", "https://cdn2.steamgriddb.com:444/a.png"] { XCTAssertFalse(ArtworkPolicy.trusted(URL(string: value)!)) }
    }
    func testCacheNamesCannotEscapeDirectoryAndKindsDoNotCollide() {
        let id = "../../Credentials/private"
        let cover = ArtworkPolicy.key(id, .cover), hero = ArtworkPolicy.key(id, .hero)
        XCTAssertEqual(cover.count, 64); XCTAssertFalse(cover.contains("/")); XCTAssertNotEqual(cover, hero)
        XCTAssertEqual(ArtworkPolicy.normalized("Baldur’s Gate: Édition"), ArtworkPolicy.normalized("BALDURS GATE EDITION"))
        XCTAssertTrue(ArtworkKind.cover.steamURL(123).path.hasSuffix("library_600x900.jpg"))
        XCTAssertTrue(ArtworkKind.hero.steamURL(123).path.hasSuffix("library_hero.jpg"))
    }
}
@MainActor
final class ArtworkCredentialTests: XCTestCase {
    func testCredentialPersistsPrivatelyAndInvalidInputPreservesExistingKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtworkStore(root: root), key = String(repeating: "a", count: 32)
        store.configure(key)
        XCTAssertTrue(store.configured)
        let file = root.appendingPathComponent("Credentials/steamgriddb.key")
        XCTAssertEqual(try String(contentsOf: file), key)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        store.configure("invalid\nkey")
        XCTAssertEqual(try String(contentsOf: file), key)
        XCTAssertTrue(ArtworkStore(root: root).configured)
        XCTAssertFalse(store.message.contains(key))
        store.configure("")
        XCTAssertFalse(store.configured); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

private final class ArtworkFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var offline = false
    static func reset() { lock.lock(); defer { lock.unlock() }; requests = []; offline = false }
    static func goOffline() { lock.lock(); defer { lock.unlock() }; offline = true }
    static func recorded() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); let offline = Self.offline; Self.lock.unlock()
        if offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let url = request.url!, api = url.host == "www.steamgriddb.com"
        let data = api ? Data(#"{"success":true,"data":[{"id":4,"score":10,"url":"https://cdn2.steamgriddb.com/test.png","author":{"name":"Test Artist"}}]}"#.utf8) : Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jF4sAAAAASUVORK5CYII=")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": api ? "application/json" : "image/png", "Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
@MainActor
final class ArtworkIntegrationTests: XCTestCase {
    func testAuthenticatedLookupDownloadsWithoutCredentialAndSurvivesOfflineRelaunch() async throws {
        ArtworkFixtureProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ArtworkFixtureProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = ArtworkClient(session: session), store = ArtworkStore(root: root, client: client)
        let key = String(repeating: "a", count: 32)
        store.configure(key)
        let game = Game(id: UUID(), title: "Test", store: .steam, executablePath: "", addedAt: Date(), steamAppID: 10)
        await store.ensure(game, kind: .cover)
        let requests = ArtworkFixtureProtocol.recorded()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.url?.path, "/api/v2/grids/steam/10")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(store.asset(game, kind: .cover)?.source, "SteamGridDB")
        XCTAssertEqual(store.asset(game, kind: .cover)?.author, "Test Artist")
        XCTAssertNotNil(store.image(game, kind: .cover))
        ArtworkFixtureProtocol.goOffline()
        let reopened = ArtworkStore(root: root, client: client)
        await reopened.ensure(game, kind: .cover)
        XCTAssertEqual(ArtworkFixtureProtocol.recorded().count, 2, "Cached artwork must not require network on relaunch")
        XCTAssertNotNil(reopened.image(game, kind: .cover))
        reopened.refresh()
        await reopened.ensure(game, kind: .cover)
        XCTAssertEqual(reopened.asset(game, kind: .cover)?.source, "SteamGridDB", "A failed refresh must preserve the existing artwork")
        XCTAssertNotNil(reopened.image(game, kind: .cover))
    }
}
