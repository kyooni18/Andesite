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

private func converged(_ a: VaultSession, _ ra: URL, _ b: VaultSession, _ rb: URL) throws -> Bool {
    let left = try a.run { try snapshot($0, ra) }, right = try b.run { try snapshot($0, rb) }
    return left == right && !left.isEmpty
}

@Test func twoVaultsSyncOverAuthenticatedHTTPAndResumeAfterOutage() async throws {
    let fa = try RuntimeFixture(), fb = try RuntimeFixture(); defer { fa.clean(); fb.clean() }
    let a = try VaultSession(vaultDirectory: fa.vault.path, stateDirectory: fa.state.path)
    let b = try VaultSession(vaultDirectory: fb.vault.path, stateDirectory: fb.state.path)
    try fa.write("from-a.md", "# A\nalpha\n")
    try fb.write("from-b.md", "# B\nbeta\n")
    try b.startWatching(settings: VaultMonitorSettings(latency: 0.05, debounce: 0.05, maximumCoalescing: 0.1, polling: 0.02))
    #expect(try eventually { try b.run { try $0.status().revisions } == 1 })
    var server = try await TestServer(b)

    #expect(throws: SyncTransportError.insecureDestination) { try SyncClient(destination: URL(string: "http://example.com")!, token: server.token) }
    let stranger = try SyncClient(destination: server.url, token: String(repeating: "0", count: 64))
    await #expect(throws: SyncTransportError.self) { try await stranger.sync(a) }
    #expect(try await server.request("POST", "/v1/sync/changes", body: Data("{}".utf8), token: "").status == 401)

    let report = try await SyncClient(destination: server.url, token: server.token).sync(a)
    #expect(report.received == 1 && report.sent == 1 && report.pending == 0)
    #expect(try converged(a, fa.vault, b, fb.vault))
    #expect(try String(contentsOf: fa.vault.appendingPathComponent("from-b.md"), encoding: .utf8) == "# B\nbeta\n")

    // Offline: the peer is down while both sides keep editing.
    await server.stop()
    let offline = try SyncClient(destination: server.url, token: server.token)
    await #expect(throws: (any Error).self) { try await offline.sync(a) }
    let head = try a.run { try $0.document("from-b.md").revisionID }
    try a.run { _ = try $0.update("from-b.md", Data("# B\nbeta\nedited on a\n".utf8), revision: head) }
    try fb.write("from-b.md", "# B (renamed title)\nbeta\n")
    try a.run { _ = try $0.create("Offline/new.md", Data("written offline\n".utf8)) }
    #expect(try eventually { try b.run { try $0.status().revisions } == 3 }) // the watcher captured B's edit

    server = try await TestServer(b)
    let resumed = try await SyncClient(destination: server.url, token: server.token).sync(a)
    #expect(resumed.pending == 0 && resumed.merged >= 1)
    #expect(try converged(a, fa.vault, b, fb.vault))
    #expect(try String(contentsOf: fb.vault.appendingPathComponent("from-b.md"), encoding: .utf8) == "# B (renamed title)\nbeta\nedited on a\n")
    // Nothing new: a repeated sync is a no-op.
    let again = try await SyncClient(destination: server.url, token: server.token).sync(a)
    #expect(again.received == 0 && again.applied == 0)
    await server.stop()
    try a.close(); try b.close()
}

@Test func syncKilledWhileApplyingResumesConsistently() async throws {
    let fa = try RuntimeFixture(), fb = try RuntimeFixture(); defer { fa.clean(); fb.clean() }
    try fa.write("note.md", "one\ntwo\n")
    let b = try VaultSession(vaultDirectory: fb.vault.path, stateDirectory: fb.state.path)
    let server = try await TestServer(b)
    let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug/andesite-server")
    func syncA(killAt point: String? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["sync", fa.vault.path, server.url.absoluteString, "--state", fa.state.path]
        var environment = ["ANDESITE_API_TOKEN": server.token]
        if let point { environment["ANDESITE_TEST_FAULTS"] = "1"; environment["ANDESITE_TEST_KILL_POINT"] = point }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    #expect(try syncA() == 0)
    let head = try b.run { try $0.document("note.md").revisionID }
    try b.run { _ = try $0.update("note.md", Data("one\ntwo\nthree\n".utf8), revision: head) }
    for point in ["staged", "verified", "before-commit", "committed"] {
        #expect(try syncA(killAt: point) == 9, "\(point)") // SIGKILL while applying the remote edit
        let current = try b.run { try $0.document("note.md").revisionID }
        try b.run { _ = try $0.update("note.md", Data("one\ntwo\nthree \(point)\n".utf8), revision: current) }
    }
    #expect(try syncA() == 0)
    let a = try VaultSession(vaultDirectory: fa.vault.path, stateDirectory: fa.state.path)
    #expect(try a.run { try $0.status().unfinishedMutations } == 0)
    #expect(try String(contentsOf: fa.vault.appendingPathComponent("note.md"), encoding: .utf8) == "one\ntwo\nthree committed\n")
    #expect(try converged(a, fa.vault, b, fb.vault))
    #expect(try a.run { try $0.reconcile().revisionsCreated } == 0)
    try a.close()
    await server.stop()
    try b.close()
}
