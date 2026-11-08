import Foundation
import Testing
@testable import AndesiteCore
@testable import AndesiteHTTP
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A real Hummingbird server on an ephemeral loopback port.
final class TestServer: @unchecked Sendable {
    let session: VaultSession
    let token: String
    private(set) var port = 0
    private var task: Task<Void, Error>?
    private let lock = NSLock()

    init(_ session: VaultSession, token: String = String(repeating: "5a", count: 32)) async throws {
        self.session = session
        self.token = token
        task = Task { [session, token] in
            try await AndesiteHTTPServer.run(session: session, token: token, port: 0) { bound in
                self.lock.withLock { self.port = bound }
            }
        }
        for _ in 0..<400 {
            let ready = lock.withLock { port != 0 }
            if ready { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw VaultError.unsupported("server did not start")
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func stop() async { task?.cancel(); _ = await task?.result }

    func request(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:],
                 token: String? = nil) async throws -> (status: Int, body: Data, headers: [AnyHashable: Any]) {
        var request = URLRequest(url: URL(string: url.absoluteString + path)!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer " + (token ?? self.token), forHTTPHeaderField: "Authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        return (http.statusCode, data, http.allHeaderFields)
    }

    func json(_ method: String, _ path: String, _ object: [String: String]? = nil,
              headers: [String: String] = [:]) async throws -> (status: Int, value: [String: Any]) {
        let body = try object.map { try JSONSerialization.data(withJSONObject: $0) }
        let reply = try await request(method, path, body: body, headers: headers)
        return (reply.status, (try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any]) ?? [:])
    }
}

@Test func httpAPIServesDocumentLifecycleWithAuthenticationAndPreconditions() async throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let session = try VaultSession(vaultDirectory: f.vault.path, stateDirectory: f.state.path)
    try session.reconcile()
    let server = try await TestServer(session)

    #expect(try await server.request("GET", "/v1/status", token: "").status == 401)
    #expect(try await server.request("GET", "/v1/status", token: String(repeating: "00", count: 32)).status == 401)
    #expect(try await server.json("GET", "/v1/status").value["state"] as? String == "ready")

    let path = "/v1/file?path=Inbox/%ED%95%9C%EA%B8%80.md" // "Inbox/한글.md"
    let created = try await server.request("PUT", path, body: Data("# Hello\nworld\n".utf8), headers: ["If-None-Match": "*"])
    #expect(created.status == 201)
    let first = try #require((try JSONSerialization.jsonObject(with: created.body) as? [String: Any])?["revision"] as? String)
    #expect(try await server.request("PUT", path, body: Data("again".utf8), headers: ["If-None-Match": "*"]).status == 409)
    #expect(try String(contentsOf: f.vault.appendingPathComponent("Inbox/한글.md"), encoding: .utf8) == "# Hello\nworld\n")

    let read = try await server.request("GET", path)
    #expect(read.status == 200 && read.body == Data("# Hello\nworld\n".utf8))
    #expect(read.headers["Etag"] as? String == "\"\(first)\"")

    #expect(try await server.request("PUT", path, body: Data("x".utf8)).status == 428)
    let updated = try await server.json("PUT", path, headers: ["If-Match": "\"\(first)\""])
    #expect(updated.status == 200)
    let second = try #require(updated.value["revision"] as? String)
    let stale = try await server.json("PUT", path, headers: ["If-Match": "\"\(first)\""])
    #expect(stale.status == 412 && stale.value["current"] as? String == second)

    let moved = try await server.json("POST", "/v1/move", ["path": "Inbox/한글.md", "to": "Archive/moved.md", "revision": second])
    #expect(moved.status == 200 && moved.value["path"] as? String == "Archive/moved.md")
    #expect(try await server.json("POST", "/v1/move", ["path": "../x.md", "to": "y.md", "revision": second]).status == 400)
    let third = try #require(moved.value["revision"] as? String)
    #expect(try await server.request("DELETE", "/v1/file?path=Archive/moved.md", headers: ["If-Match": "\"\(third)\""]).status == 200)
    #expect(try await server.request("GET", "/v1/file?path=Archive/moved.md").status == 404)

    let history = try await server.json("GET", "/v1/history?path=Archive/moved.md")
    #expect((history.value["revisions"] as? [[String: Any]])?.count == 4)
    let restored = try await server.json("POST", "/v1/restore", ["path": "Archive/moved.md", "revision": first])
    #expect(restored.status == 200)
    #expect(try await server.request("GET", "/v1/file?path=Archive/moved.md").body == Data("# Hello\nworld\n".utf8))
    let search = try await server.json("GET", "/v1/search?q=world")
    #expect((search.value["hits"] as? [[String: Any]])?.first?["path"] as? String == "Archive/moved.md")

    await server.stop()
    try session.close()
}
