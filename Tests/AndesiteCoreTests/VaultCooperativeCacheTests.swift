import Foundation
import Testing
@testable import AndesiteCore

@Test func cooperativeCacheYieldsBetweenDocumentBatchesAndPublishesOnce() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    for i in 0..<32 {
        let text = "# Note \(i)\n" + (i > 0 ? "[[Note-0]]\n" : "")
        try f.write("Note-\(i).md", text)
    }
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    let target = try #require(try runtime.documents(limit: 50).documents.first {
        $0.path == "Note-0.md"
    }).id
    #expect(!runtime.linksIndexed)
    var yields = 0
    var final: VaultRuntime.LinkCacheReport?
    while final == nil && yields < 100 {
        final = try runtime.advanceLinkCache(maxDocuments: 2, maxBytes: 4096)
        yields += 1
        if final == nil {
            #expect(!runtime.linksIndexed)
            #expect(runtime.linkCacheGeneration == 0)
            #expect(throws: VaultLinkGraphError.cacheNotReady) {
                try runtime.links(target, direction: .incoming)
            }
        }
    }
    #expect(yields >= 20)
    #expect(final?.parsedDocuments == 32)
    #expect(final?.reusedDocuments == 0)
    #expect(runtime.linksIndexed)
    #expect(try runtime.links(target, direction: .incoming).total == 31)
    #expect(runtime.linkCacheGeneration == 1)
    try runtime.shutdown()
}

@Test func midBuildEditAbortsUnpublishedCacheAndStartsNewGeneration() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    for i in 0..<14 {
        try f.write("Note-\(i).md", "# Original\n[[Note-0]]")
    }
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    #expect(try runtime.advanceLinkCache(maxDocuments: 1, maxBytes: 1000) == nil)
    try f.write("Note-0.md", "# New\n[[Nothing]]")
    _ = try runtime.reconcile()
    #expect(!runtime.linksIndexed)
    let result = try runtime.refreshLinkCache()
    #expect(result.parsedDocuments == 14)
    let target = try #require(try runtime.documents(limit: 50).documents.first {
        $0.path == "Note-0.md"
    }).id
    #expect(try runtime.links(target, direction: .outgoing).mentions.first?.status == "missing")
    try runtime.shutdown()
}

@Test func localStatusReportsPendingCacheProgressWithoutServingPartialBacklinks() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    for i in 0..<18 { try f.write("Note-\(i).md", "# Note \(i)\n[[Note-0]]") }
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    let document = try #require(try runtime.documents(limit: 50).documents.first {
        $0.path == "Note-0.md"
    }).id
    let id = document.map { String(format: "%02x", $0) }.joined()
    let api = try VaultLocalHTTP(runtime: runtime, stateDirectory: f.state.path)

    #expect(try runtime.advanceLinkCache(maxDocuments: 3, maxBytes: 1024) == nil)
    let response = api.handle(request: Data(
        "GET /v1/status HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8), indexReady: true)
    #expect(response.status == 200)
    let status = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    let progress = try #require(status["linkCacheProgress"] as? [String: Int])
    #expect(progress["processedHeads"] == 3)
    #expect(progress["totalHeads"] == 18)
    #expect(progress["resolvedHeads"] == 0)
    #expect(status["linksIndexed"] as? Bool == false)
    let links = api.handle(request: Data(
        "GET /v1/documents/\(id)/backlinks HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8),
        indexReady: true)
    #expect(links.status == 503)

    _ = try runtime.refreshLinkCache()
    let ready = api.handle(request: Data(
        "GET /v1/status HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8), indexReady: true)
    let readyStatus = try #require(JSONSerialization.jsonObject(with: ready.body) as? [String: Any])
    #expect(readyStatus["linksIndexed"] as? Bool == true)
    #expect(readyStatus["linkCacheProgress"] is NSNull)
    try runtime.shutdown()
}
