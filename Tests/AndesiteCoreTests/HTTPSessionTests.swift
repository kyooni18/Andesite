import Foundation
import Testing
@testable import AndesiteCore
@testable import AndesiteHTTP
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A real `serve-all` server on an ephemeral loopback port.
final class LibraryServer: @unchecked Sendable {
    let library: VaultLibrary
    let token = String(repeating: "5a", count: 32)
    private let port = Locked(0)
    private var task: Task<Void, Error>?
    private let urlSession: URLSession

    init(_ library: VaultLibrary, sessionLifetime: TimeInterval = SessionStore.defaultLifetime) async throws {
        self.library = library
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false   // the tests send Cookie themselves
        configuration.httpCookieAcceptPolicy = .never
        urlSession = URLSession(configuration: configuration)
        let (token, port) = (token, self.port)
        task = Task { try await AndesiteHTTPServer.run(library: library, token: token, port: 0, sessionLifetime: sessionLifetime) { port.set($0) } }
        for _ in 0..<400 where port.get() == 0 { try await Task.sleep(for: .milliseconds(10)) }
        guard port.get() != 0 else { throw VaultError.unsupported("server did not start") }
    }

    func stop() async {
        task?.cancel(); _ = await task?.result
        await library.close()
    }

    /// `bearer: false` sends no Authorization header; `cookie` is sent as is.
    func request(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:], token: String? = nil,
                 bearer: Bool = true, cookie: String? = nil) async throws -> (status: Int, body: Data, headers: [AnyHashable: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port.get())" + path)!)
        request.httpMethod = method
        request.httpBody = body
        if bearer { request.setValue("Bearer " + (token ?? self.token), forHTTPHeaderField: "Authorization") }
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await urlSession.data(for: request)
        let http = response as! HTTPURLResponse
        return (http.statusCode, data, http.allHeaderFields)
    }

    /// Logs in with the API token and returns the `Cookie` header a browser would send back.
    func login() async throws -> String {
        let reply = try await request("POST", "/auth/session", body: Data(#"{"token":"\#(token)"}"#.utf8), bearer: false)
        #expect(reply.status == 201)
        let setCookie = try #require(reply.headers["Set-Cookie"] as? String)
        return String(try #require(setCookie.split(separator: ";").first))
    }
}

private func field(_ reply: (status: Int, body: Data, headers: [AnyHashable: Any]), _ name: String) -> Any? {
    (try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any])?[name]
}

private func library(_ f: RuntimeFixture, vaults: [String]) throws -> VaultLibrary {
    for name in vaults {
        try FileManager.default.createDirectory(at: f.vault.appendingPathComponent(name), withIntermediateDirectories: false)
        try Data("# In \(name)\nbody of \(name)\n".utf8).write(to: f.vault.appendingPathComponent(name).appendingPathComponent("note.md"))
    }
    return VaultLibrary(root: f.vault.path, stateRoot: f.state.path)
}

/// Waits until a vault's first scan finished.
private func ready(_ server: LibraryServer, _ prefix: String) async throws {
    for _ in 0..<500 {
        if field(try await server.request("GET", prefix + "/status"), "state") as? String == "ready" { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw VaultError.unsupported("vault never became ready: \(prefix)")
}

@Test func everyV1RouteIsMountedPerVaultAndSlashV1MeansMain() async throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let server = try await LibraryServer(try library(f, vaults: ["main", "Work", "서고"]))

    #expect(field(try await server.request("GET", "/v1/vaults"), "vaults") as? [[String: String]] == [["name": "Work"], ["name": "main"], ["name": "서고"]])
    for prefix in ["/v1", "/v1/vaults/main", "/v1/vaults/Work", "/v1/vaults/%EC%84%9C%EA%B3%A0"] { try await ready(server, prefix) }

    // Each vault answers with its own notes; /v1 is the vault `main`.
    func titles(_ prefix: String) async throws -> [String] {
        let page = try await server.request("GET", prefix + "/documents")
        return (field(page, "documents") as? [[String: Any]])?.compactMap { $0["title"] as? String } ?? []
    }
    #expect(try await titles("/v1") == ["In main"])
    #expect(try await titles("/v1/vaults/main") == ["In main"])
    #expect(try await titles("/v1/vaults/Work") == ["In Work"])
    #expect(try await titles("/v1/vaults/%EC%84%9C%EA%B3%A0") == ["In 서고"])
    #expect(field(try await server.request("GET", "/v1/vaults/Work/search?q=body"), "hits") != nil)

    // The same routes, writes included, work under a vault prefix and stay in that vault.
    let created = try await server.request("PUT", "/v1/vaults/Work/file?path=Made.md", body: Data("# Made\n".utf8), headers: ["If-None-Match": "*"])
    #expect(created.status == 201)
    #expect(try await server.request("GET", "/v1/vaults/Work/file?path=Made.md").body == Data("# Made\n".utf8))
    #expect(try await server.request("GET", "/v1/file?path=Made.md").status == 404)
    #expect(FileManager.default.fileExists(atPath: f.vault.appendingPathComponent("Work/Made.md").path))
    for route in ["status", "tags", "properties", "bookmarks", "snapshots", "history?path=note.md", "links?path=note.md", "mentions?path=note.md",
                  "metadata?path=note.md"] {
        #expect(try await server.request("GET", "/v1/vaults/Work/" + route).status == 200, "\(route)")
    }

    // An unknown or invalid vault is a 404 / 400, and needs the token like any other.
    let missing = try await server.request("GET", "/v1/vaults/Nope/status")
    #expect(missing.status == 404 && field(missing, "error") as? String == "vault_not_found")
    #expect(try await server.request("GET", "/v1/vaults/.hidden/status").status == 400)
    #expect(try await server.request("GET", "/v1/vaults/Work/status", bearer: false).status == 401)
    // The sync API is untouched.
    #expect(try await server.request("GET", "/sync/vaults/Work/identity").status == 200)
    #expect(try await server.request("GET", "/sync/identity").status == 200)
    await server.stop()
}

@Test func aBrowserSessionCookieAuthenticatesV1ButNotSyncAndMutationsNeedTheClientHeader() async throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let server = try await LibraryServer(try library(f, vaults: ["main"]))
    try await ready(server, "/v1")

    // Logging in needs the right token and sets an HttpOnly, Secure, SameSite=Strict cookie scoped to /v1.
    let wrong = try await server.request("POST", "/auth/session", body: Data(#"{"token":"\#(String(repeating: "00", count: 32))"}"#.utf8), bearer: false)
    #expect(wrong.status == 401 && wrong.headers["Set-Cookie"] == nil)
    #expect(try await server.request("POST", "/auth/session", body: Data("{}".utf8), bearer: false).status == 400)
    #expect(try await server.request("POST", "/auth/session", body: Data(#"{"token":"short"}"#.utf8), bearer: false).status == 401)
    let login = try await server.request("POST", "/auth/session", body: Data(#"{"token":"\#(server.token)"}"#.utf8), bearer: false)
    #expect(login.status == 201 && field(login, "expiresIn") as? Int == Int(SessionStore.defaultLifetime))
    let attributes = try #require(login.headers["Set-Cookie"] as? String).components(separatedBy: "; ")
    #expect(attributes.first?.hasPrefix("andesite_session=") == true)
    #expect(Set(attributes.dropFirst()) == ["Max-Age=\(Int(SessionStore.defaultLifetime))", "Path=/v1", "HttpOnly", "Secure", "SameSite=Strict"])
    let id = String(try #require(attributes.first).dropFirst("andesite_session=".count))
    #expect(id.count == 64 && id.allSatisfy(\.isHexDigit))
    let cookie = "andesite_session=" + id
    #expect(!String(decoding: login.body, as: UTF8.self).contains(id))   // the ID is only in the cookie

    // The cookie reads /v1 (both forms), but nothing else.
    #expect(try await server.request("GET", "/v1/vaults", bearer: false, cookie: cookie).status == 200)
    #expect(try await server.request("GET", "/v1/status", bearer: false, cookie: cookie).status == 200)
    #expect(try await server.request("GET", "/v1/vaults/main/documents", bearer: false, cookie: cookie).status == 200)
    #expect(try await server.request("GET", "/sync/vaults", bearer: false, cookie: cookie).status == 401)
    #expect(try await server.request("GET", "/sync/identity", bearer: false, cookie: cookie).status == 401)
    #expect(try await server.request("GET", "/v1/status", bearer: false, cookie: "andesite_session=" + String(repeating: "0", count: 64)).status == 401)
    #expect(try await server.request("GET", "/v1/status", bearer: false).status == 401)

    // Mutations with the cookie need X-Andesite-Client: web; the bearer token does not.
    let put = "/v1/file?path=FromBrowser.md"
    let refused = try await server.request("PUT", put, body: Data("# b\n".utf8), headers: ["If-None-Match": "*"], bearer: false, cookie: cookie)
    #expect(refused.status == 403 && field(refused, "error") as? String == "client_header_required")
    let other = try await server.request("PUT", put, body: Data("# b\n".utf8), headers: ["If-None-Match": "*", "X-Andesite-Client": "mobile"], bearer: false, cookie: cookie)
    #expect(other.status == 403)
    #expect(!FileManager.default.fileExists(atPath: f.vault.appendingPathComponent("main/FromBrowser.md").path))
    let allowed = try await server.request("PUT", put, body: Data("# b\n".utf8), headers: ["If-None-Match": "*", "X-Andesite-Client": "web"], bearer: false, cookie: cookie)
    #expect(allowed.status == 201)
    #expect(try await server.request("PUT", "/v1/file?path=FromApp.md", body: Data("# a\n".utf8), headers: ["If-None-Match": "*"]).status == 201)
    // A wrong bearer token does not fall back to anything but a valid cookie.
    #expect(try await server.request("GET", "/v1/status", token: "nope").status == 401)

    // Logging out: the cookie goes on the server, and DELETE /auth/session expires it in the browser.
    let expired = try await server.request("DELETE", "/auth/session", bearer: false)
    #expect(expired.status == 204 && (expired.headers["Set-Cookie"] as? String)?.contains("Max-Age=0") == true)
    #expect(try await server.request("GET", "/v1/status", bearer: false, cookie: cookie).status == 200)   // a cookie the server was never told about
    #expect(try await server.request("DELETE", "/v1/session", bearer: false, cookie: cookie).status == 403)
    #expect(try await server.request("DELETE", "/v1/session", headers: ["X-Andesite-Client": "web"], bearer: false, cookie: cookie).status == 204)
    #expect(try await server.request("GET", "/v1/status", bearer: false, cookie: cookie).status == 401)
    // /auth/session also ends a session when the browser does send the cookie.
    let second = try await server.login()
    #expect(try await server.request("DELETE", "/auth/session", bearer: false, cookie: second).status == 204)
    #expect(try await server.request("GET", "/v1/status", bearer: false, cookie: second).status == 401)
    await server.stop()
}

@Test func aSessionExpiresAndTheStoreKeepsOnlyRecentSessions() async throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let server = try await LibraryServer(try library(f, vaults: ["main"]), sessionLifetime: 1)
    let cookie = try await server.login()
    #expect(try await server.request("GET", "/v1/vaults", bearer: false, cookie: cookie).status == 200)
    try await Task.sleep(for: .milliseconds(1300))
    #expect(try await server.request("GET", "/v1/vaults", bearer: false, cookie: cookie).status == 401)
    #expect(try await server.request("GET", "/v1/vaults").status == 200)
    await server.stop()

    let clock = Locked(Date(timeIntervalSince1970: 1_000))
    let store = SessionStore(lifetime: 60, now: { clock.get() })
    let first = store.create()
    #expect(store.isValid(first))
    clock.set(Date(timeIntervalSince1970: 1_061))
    #expect(!store.isValid(first))
    let ids = (0..<(SessionStore.capacity + 5)).map { _ in store.create() }
    #expect(Set(ids).count == ids.count)
    #expect(!store.isValid(ids[0]) && store.isValid(ids.last!))
    store.revoke(ids.last!)
    #expect(!store.isValid(ids.last!))
}

@Test func tokensAreComparedWithoutStoppingAtTheFirstDifference() {
    let secret = Array("a1b2c3".utf8)
    #expect(constantTimeEquals(secret, secret))
    #expect(!constantTimeEquals(secret, Array("a1b2c4".utf8)))
    #expect(!constantTimeEquals(secret, Array("a1b2c".utf8)))
    #expect(!constantTimeEquals(secret, Array("a1b2c3x".utf8)))
    #expect(!constantTimeEquals(secret, []))
}

@Test func theSingleVaultServerRejectsCookiesForUnscopedPathsAndKeepsTheBearerToken() async throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let vault = try f.open()
    try vault.reconcile()
    let server = try await TestServer(vault)
    #expect(try await server.request("POST", "/auth/session", body: Data(#"{"token":"\#(server.token)"}"#.utf8), headers: ["Authorization": ""]).status == 201)
    #expect(try await server.request("GET", "/v1/status").status == 200)
    await server.stop()
    try vault.close()
}
