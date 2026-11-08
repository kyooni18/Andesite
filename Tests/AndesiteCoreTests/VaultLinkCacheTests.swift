import Foundation
import Testing
@testable import AndesiteCore

@Test func linkCacheQueriesArePureAndRebuildOnlyChangedNotes() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("A.md", "# A\n[[B]]\n")
    try f.write("B.md", "# B\n")
    try f.write("C.md", "# C\n")
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    let docs = try runtime.documents().documents
    let idA = try #require(docs.first { $0.path == "A.md" }).id
    let idB = try #require(docs.first { $0.path == "B.md" }).id

    #expect(!runtime.linksIndexed)
    #expect(throws: VaultLinkGraphError.cacheNotReady) {
        try runtime.links(idB, direction: .incoming)
    }
    let first = try runtime.refreshLinkCache()
    #expect(first.graphChanged)
    #expect(first.parsedDocuments == 3)
    #expect(first.reusedDocuments == 0)
    #expect(runtime.linksIndexed)
    #expect(first.generation == 1)
    for _ in 0..<30 {
        #expect(try runtime.links(idB, direction: .incoming).total == 1)
        #expect(try runtime.links(idA, direction: .outgoing).total == 1)
    }
    #expect(runtime.linkCacheGeneration == 1)

    _ = try runtime.reconcile()
    #expect(!runtime.linksIndexed)
    #expect(throws: VaultLinkGraphError.cacheNotReady) {
        try runtime.links(idB, direction: .incoming)
    }
    let same = try runtime.refreshLinkCache()
    #expect(!same.graphChanged)
    #expect(same.parsedDocuments == 0)
    #expect(same.reusedDocuments == 3)
    #expect(same.generation == 1)

    try f.write("A.md", "# A\n[[C]]\n")
    #expect(try runtime.links(idB, direction: .incoming).total == 1)
    _ = try runtime.reconcile()
    #expect(throws: VaultLinkGraphError.cacheNotReady) {
        try runtime.links(idB, direction: .incoming)
    }
    let changed = try runtime.refreshLinkCache()
    #expect(changed.graphChanged)
    #expect(changed.parsedDocuments == 1)
    #expect(changed.reusedDocuments == 2)
    #expect(changed.generation == 2)
    #expect(try runtime.links(idB, direction: .incoming).total == 0)
    #expect(try runtime.links(idA, direction: .outgoing).total == 1)

    try FileManager.default.removeItem(at: f.vault.appendingPathComponent("C.md"))
    _ = try runtime.reconcile()
    _ = try runtime.refreshLinkCache()
    let missing = try runtime.links(idA, direction: .outgoing)
    #expect(missing.mentions.first?.status == "missing")
    try runtime.shutdown()
}

@Test func oversizedGraphFailureDoesNotPublishPriorGeneration() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("Target.md", "# Target\n")
    try f.write("Source.md", "[[Target]]\n")
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    _ = try runtime.refreshLinkCache()
    let target = try #require(try runtime.documents().documents.first {
        $0.path == "Target.md"
    }).id
    #expect(try runtime.links(target, direction: .incoming).total == 1)

    try f.write("Source.md", "# Oversize\n" + String(repeating: "z", count: 270_000))
    _ = try runtime.reconcile()
    #expect(throws: VaultLinkGraphError.graphTooLarge) {
        try runtime.refreshLinkCache()
    }
    #expect(!runtime.linksIndexed)
    #expect(throws: VaultLinkGraphError.graphTooLarge) {
        try runtime.links(target, direction: .incoming)
    }
    // No user content was changed by cache maintenance.
    #expect(try runtime.inspectDocument(target).path == "Target.md")
    try runtime.shutdown()
}
