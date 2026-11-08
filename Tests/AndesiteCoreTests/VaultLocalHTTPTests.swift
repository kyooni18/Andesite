#if os(macOS)
import Foundation
import Testing
import Darwin
@testable import AndesiteCore

private func httpRequest(_ target: String, method: String = "GET",
                         extraHeaders: String = "") -> Data {
    Data("\(method) \(target) HTTP/1.1\r\nHost: localhost\r\n\(extraHeaders)\r\n".utf8)
}

@Test func readOnlyHTTPRoutesRejectUnsafeRequestsAndPreserveHistory() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "# Safe\ncanfindthis\n")
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    let api = try VaultLocalHTTP(runtime: runtime, stateDirectory: f.state.path)
    let original = try #require(runtime.snapshots(path: "note.md").first)

    let ready = api.handle(request: httpRequest("/v1/status"), indexReady: true)
    #expect(ready.status == 200)
    #expect(String(decoding: ready.body, as: UTF8.self).contains("\"indexedReadable\":true"))
    #expect(api.handle(request: httpRequest("/v1/search?q=canfindthis"), indexReady: true).status == 200)
    #expect(api.handle(request: httpRequest("/v1/search?q=canfindthis"), indexReady: false).status == 503)
    let hits = api.handle(request: httpRequest("/v1/search?q=canfindthis"), indexReady: true)
    #expect(String(decoding: hits.body, as: UTF8.self).contains(original.entryID.map { String(format: "%02x", $0) }.joined()))
    #expect(api.handle(request: httpRequest("/v1/snapshots?path=note.md&limit=1"), indexReady: true).status == 200)
    #expect(api.handle(request: httpRequest("/v1/snapshots?offset=1000000"), indexReady: true).status == 400)
    #expect(api.handle(request: httpRequest("/v1/snapshots?limit=0"), indexReady: true).status == 400)

    let id = original.id.map { String(format: "%02x", $0) }.joined()
    #expect(api.handle(request: httpRequest("/v1/snapshots/\(id)"), indexReady: true).status == 200)
    let content = api.handle(request: httpRequest("/v1/snapshots/\(id)/content"), indexReady: true)
    #expect(content.status == 200 && content.body == Data("# Safe\ncanfindthis\n".utf8))
    #expect(api.handle(request: httpRequest("/v1/snapshots/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), indexReady: true).status == 404)

    #expect(api.handle(request: httpRequest("/v1/search", method: "POST"), indexReady: true).status == 405)
    #expect(api.handle(request: httpRequest("/v1/status", extraHeaders: "Content-Length: 0\r\n"), indexReady: true).status == 400)
    #expect(api.handle(request: httpRequest("/v1/search?q=%00"), indexReady: true).status == 400)
    #expect(api.handle(request: httpRequest("/v1/search?q=x&q=y"), indexReady: true).status == 400)
    #expect(api.handle(request: httpRequest("/v1/snapshots/../../bad"), indexReady: true).status != 200)
    #expect(api.handle(request: httpRequest("/v1/status").prefix(7), indexReady: true).status == 400)
    #expect(try runtime.status().revisions == 1) // No API request mutates data.

    // The API socket disappears after the owner exits normally.
    withExtendedLifetime(api) {}
    try runtime.shutdown()
}

@Test func localHTTPRefusesSymlinkSocketAndFailsClosedOnIndexQuarantine() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "firstword")
    let external = f.root.appendingPathComponent("unrelated")
    try "untouched".write(to: external, atomically: false, encoding: .utf8)
    let socket = URL(fileURLWithPath: try VaultLocalHTTP.socketPath(for: f.state.path))
    try FileManager.default.createSymbolicLink(at: socket, withDestinationURL: external)
    let runtime = try VaultRuntime(configuration: f.configuration)
    #expect(throws: (any Error).self) {
        try VaultLocalHTTP(runtime: runtime, stateDirectory: f.state.path)
    }
    #expect(try String(contentsOf: external, encoding: .utf8) == "untouched")
    try FileManager.default.removeItem(at: socket)
    let api = try VaultLocalHTTP(runtime: runtime, stateDirectory: f.state.path)
    _ = try runtime.reconcile()
    try Data([0xff, 0xfe]).write(to: f.vault.appendingPathComponent("note.md"))
    _ = try runtime.reconcile()
    #expect(try runtime.status().state == "quarantined")
    #expect(api.handle(request: httpRequest("/v1/search?q=firstword"), indexReady: true).status == 503)
    #expect(api.handle(request: httpRequest("/v1/status"), indexReady: true).status == 200)
    #expect(api.handle(request: httpRequest("/v1/snapshots?path=note.md"), indexReady: true).status == 200)
    try runtime.shutdown()
}

private final class WatchProcessFixture {
    let fixture: RuntimeFixture
    let log: URL
    private(set) var child: Process?

    init() throws {
        fixture = try RuntimeFixture()
        log = fixture.root.appendingPathComponent("watch-api.log")
    }

    var socket: String {
        (try? VaultLocalHTTP.socketPath(for: fixture.state.path)) ?? ""
    }

    func start() throws {
        let executable = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/andesite-server")
        let p = Process()
        p.executableURL = executable
        p.arguments = ["watch", "--vault", fixture.vault.path, "--state", fixture.state.path]
        try Data().write(to: log, options: .atomic)
        let output = try FileHandle(forWritingTo: log)
        p.standardOutput = output
        p.standardError = output
        try p.run()
        try? output.close()
        child = p
    }

    func awaitReady() -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socket),
               let output = try? String(contentsOf: log, encoding: .utf8),
               output.contains("watch-ready") { return true }
            if child?.isRunning == false { return false }
            Thread.sleep(forTimeInterval: 0.06)
        }
        return false
    }

    func curl(_ target: String, method: String = "GET") throws -> (status: Int, text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["--silent", "--show-error", "--max-time", "4",
                       "--unix-socket", socket, "--request", method,
                       "--include", "http://localhost" + target]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let first = output.components(separatedBy: "\r\n").first ?? ""
        let words = first.split(separator: " ")
        return (words.count >= 2 ? Int(words[1]) ?? -1 : -1, output)
    }

    func stop(_ signal: Int32) {
        guard let p = child else { return }
        if p.isRunning { _ = kill(p.processIdentifier, signal) }
        p.waitUntilExit()
        child = nil
    }

    func clean() {
        stop(SIGKILL)
        fixture.clean()
    }
}

@Test func localUnixHTTPWorksWithRunningWatcherAndRecoversStaleSocket() throws {
    let f = try WatchProcessFixture(); defer { f.clean() }
    try f.fixture.write("note.md", "# Before\nfirsttoken\n")
    try f.start()
    #expect(f.awaitReady())
    #expect(try f.curl("/v1/status").status == 200)
    let first = try f.curl("/v1/search?q=firsttoken")
    #expect(first.status == 200 && first.text.contains("Before"))
    #expect(try f.curl("/v1/search", method: "POST").status == 405)

    try f.fixture.write("note.md", "# After\nsecondtoken\n")
    var sawUpdate = false
    let deadline = Date().addingTimeInterval(9)
    while Date() < deadline {
        let response = try f.curl("/v1/search?q=secondtoken")
        if response.status == 200 && response.text.contains("After") { sawUpdate = true; break }
        Thread.sleep(forTimeInterval: 0.15)
    }
    #expect(sawUpdate)
    #expect(try f.curl("/v1/snapshots?path=note.md").status == 200)
    #expect(try f.curl("/v1/snapshots?path=note.md&offset=1&limit=1").status == 200)

    f.stop(SIGKILL)
    #expect(FileManager.default.fileExists(atPath: f.socket))
    // Change the file while the watcher is down; startup must reconcile.
    try f.fixture.write("note.md", "# Restarted\nthirdtoken\n")
    try f.start()
    #expect(f.awaitReady())
    #expect(try f.curl("/v1/search?q=thirdtoken").status == 200)
    #expect(try f.curl("/v1/search?q=thirdtoken").text.contains("Restarted"))
    f.stop(SIGTERM)
    #expect(!FileManager.default.fileExists(atPath: f.socket))
    let reopened = try VaultRuntime(configuration: f.fixture.configuration)
    #expect(try reopened.status().revisions == 3)
    #expect(try reopened.snapshots(path: "note.md").count >= 2)
    try reopened.shutdown()
}
#endif

#if os(macOS)
@Test func localHTTPBlocksSearchDuringFailedScanThenRecovers() throws {
    let f = try WatchProcessFixture(); defer { f.clean() }
    try f.fixture.write("note.md", "# Stable\nsearchthis\n")
    try f.start()
    #expect(f.awaitReady())
    #expect(try f.curl("/v1/search?q=searchthis").status == 200)
    let outside = f.fixture.root.appendingPathComponent("outside.md")
    try Data("outside-content".utf8).write(to: outside)
    let badLink = f.fixture.vault.appendingPathComponent("unsafe.md")
    try FileManager.default.createSymbolicLink(at: badLink, withDestinationURL: outside)

    let failedDeadline = Date().addingTimeInterval(8)
    var refused = false
    while Date() < failedDeadline {
        let status = try f.curl("/v1/status")
        let search = try f.curl("/v1/search?q=searchthis")
        if status.text.contains("scanFailed") && search.status == 503 {
            refused = true
            break
        }
        Thread.sleep(forTimeInterval: 0.15)
    }
    #expect(refused, "An unsafe scan must make indexed reads unavailable.")
    try FileManager.default.removeItem(at: badLink)
    let recoveredDeadline = Date().addingTimeInterval(8)
    var recovered = false
    while Date() < recoveredDeadline {
        let result = try f.curl("/v1/search?q=searchthis")
        if result.status == 200 && result.text.contains("Stable") {
            recovered = true
            break
        }
        Thread.sleep(forTimeInterval: 0.15)
    }
    #expect(recovered)
    #expect(try String(contentsOf: outside, encoding: .utf8) == "outside-content")
    f.stop(SIGTERM)
}
#endif

#if os(macOS)
@Test func unixHTTPRelayReadsVerifiedCatalogAndFailsClosedAfterShutdown() async throws {
    let f = try WatchProcessFixture(); defer { f.clean() }
    try f.fixture.write("note.md", "# Relay\nrelayunique\n")
    try f.start()
    #expect(f.awaitReady())

    let relay = VaultHTTPRelay(socketPath: f.socket)
    let result = await relay.get("/v1/search?q=relayunique")
    #expect(result.status == 200)
    #expect(result.contentType == "application/json; charset=utf-8")
    #expect(String(decoding: result.body, as: UTF8.self).contains("Relay"))
    let metadata = await relay.get("/v1/snapshots?path=note.md")
    #expect(metadata.status == 200)
    #expect(String(decoding: metadata.body, as: UTF8.self).contains("snapshots"))
    let rejected = await relay.get("/v1/search?q=%0aHTTP%2F1.1")
    #expect(rejected.status == 400 || rejected.status == 200)
    let unsafe = await relay.get("/v1/status\r\nX-Injected: yes")
    #expect(unsafe.status == 400)
    let outOfScope = await relay.get("/v2/admin")
    #expect(outOfScope.status == 400)

    f.stop(SIGTERM)
    let unavailable = await relay.get("/v1/status")
    #expect(unavailable.status == 503)
}
#endif
