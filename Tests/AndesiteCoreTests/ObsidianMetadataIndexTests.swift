import Foundation
import Testing
@testable import AndesiteCore

@Test func frontmatterTagsAndPropertiesAreRevisionAlignedAndQueryable() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("alpha.md", """
    ---
    title: "Alpha"
    priority: 42
    completed: true
    created: 2026-11-08
    category: "Rocket"
    aliases: ["알파", "A note"]
    tags: [Project/Work, Korean/한글]
    ---
    # Alpha
    special-index-marker
    #inbox/today #PROJECT/work
    """)
    try f.write("beta.md", "# Beta\nspecial-index-marker #project/other\n")
    try f.write("gamma.md", """
    ---
    category: rocket
    tags: [personal]
    ---
    # Gamma
    """)
    try f.write("broken.md", """
    ---
    tags: [invalid
    ---
    #bad-inline
    """)
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    #expect(try runtime.documents().total == 4)
    let alpha = try #require(try runtime.documents().documents.first(where: { $0.path == "alpha.md" }))
    let metadata = try runtime.documentMetadata(alpha.id)
    #expect(metadata["state"] as? String == "valid")
    let props = try #require(metadata["properties"] as? [[String: Any]])
    #expect(props.contains(where: {
        $0["name"] as? String == "priority" && $0["type"] as? String == "number"
    }))
    #expect(props.contains(where: {
        $0["name"] as? String == "created" && $0["type"] as? String == "date"
    }))
    let tags = try #require(metadata["tags"] as? [[String: String]])
    #expect(tags.contains { $0["canonical"] == "project/work" && $0["origin"] == "frontmatter" })
    #expect(tags.contains { $0["canonical"] == "project/work" && $0["origin"] == "inline" })

    let parent = try ObsidianFilter(tag: "PROJECT")
    let nested = try runtime.documents(filter: parent)
    #expect(nested.total == 2)
    #expect(nested.documents.map(\.path) == ["alpha.md", "beta.md"])
    let exact = try runtime.documents(filter: ObsidianFilter(tag: "#Project/Work"))
    #expect(exact.total == 1 && exact.documents.first?.id == alpha.id)
    let missing = try runtime.documents(filter: ObsidianFilter(tag: "projectile"))
    #expect(missing.total == 0)
    let scalarFilter = try ObsidianFilter(property: "PRIORITY", value: "42")
    #expect(try runtime.documents(filter: scalarFilter).documents.map(\.path) == ["alpha.md"])
    let existence = try ObsidianFilter(property: "aliases")
    #expect(try runtime.documents(filter: existence).total == 1)
    #expect(try runtime.documents(filter: ObsidianFilter(property: "category", value: "ROCKET")).total == 2)
    #expect(try runtime.documents(filter: ObsidianFilter(tag: "project",
                  property: "category", value: "rocket")).total == 1)
    #expect(try runtime.searchIndexed("special-index-marker",
                                      filter: ObsidianFilter(tag: "#project")).count == 2)

    let tagSummary = try runtime.tags(limit: 30)
    let labels = try #require(tagSummary["tags"] as? [[String: Any]])
    #expect(labels.contains(where: {
        $0["canonical"] as? String == "project/work" && $0["documents"] as? Int64 == 1
    }))
    let propSummary = try runtime.properties(limit: 50)
    let keys = try #require(propSummary["properties"] as? [[String: Any]])
    #expect(keys.contains { $0["canonical"] as? String == "priority" })
    #expect(keys.contains { $0["canonical"] as? String == "tags" })
    let broken = try #require(try runtime.documents().documents.first(where: { $0.path == "broken.md" }))
    #expect(try runtime.documentMetadata(broken.id)["state"] as? String == "invalid")
    #expect(try runtime.documents(filter: ObsidianFilter(tag: "bad-inline")).total == 1)

    // A changed head atomically replaces its old tag/property projections.
    try f.write("alpha.md", """
    ---
    priority: 5
    tags: [Archive]
    ---
    # New Alpha
    #new-tag
    """)
    _ = try runtime.reconcile()
    #expect(try runtime.inspectDocument(alpha.id).path == "alpha.md")
    #expect(try runtime.documents(filter: ObsidianFilter(tag: "project/work")).total == 0)
    #expect(try runtime.documents(filter: ObsidianFilter(tag: "archive")).total == 1)
    #expect(try runtime.documents(filter: ObsidianFilter(property: "priority", value: "42")).total == 0)
    #expect(try runtime.documents(filter: ObsidianFilter(property: "priority", value: "5")).total == 1)
    try runtime.shutdown()
}

@Test func metadataRebuildsFromImmutableHeadsAfterVersionEightUpgrade() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let source = """
    ---
    date: 2026-11-08
    tags: [Legacy/Note]
    ---
    # Legacy
    #obsolete
    """
    try f.write("note.md", source)
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    let initial = try #require(try runtime.documents().documents.first)
    try runtime.shutdown()

    // Emulate a real v8 catalog whose FTS and revision data already exist
    // but which has no metadata tables at all.
    let db = try SQLiteConnection(path: f.state.appendingPathComponent("catalog.sqlite").path)
    for name in ["document_property_values", "document_property_keys",
                 "document_tags", "document_properties"] {
        try db.execute("DROP TABLE \(name)")
    }
    try db.execute("PRAGMA user_version=8")
    let reopened = try VaultRuntime(configuration: f.configuration)
    #expect(try reopened.reconcile().revisionsCreated == 0)
    #expect(try reopened.inspectDocument(initial.id).revisionID == initial.revisionID)
    #expect(try reopened.documents(filter: ObsidianFilter(tag: "#legacy")).total == 1)
    #expect(try reopened.documentMetadata(initial.id)["state"] as? String == "valid")
    #expect(try Data(contentsOf: f.vault.appendingPathComponent("note.md")) == Data(source.utf8))
    try reopened.shutdown()
}

#if os(macOS)
@Test func metadataHTTPHandlesPropertiesTagsFiltersAndInvalidRequests() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("one.md", """
    ---
    tags: [Korean/한글, program]
    rating: 5
    ---
    # One
    search-for-property-uniquely
    """)
    try f.write("two.md", "# Two\n#program/Swift\n")
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    let id = try #require(try runtime.documents().documents.first(where: { $0.path == "one.md" }))
        .id.map { String(format: "%02x", $0) }.joined()
    let api = try VaultLocalHTTP(runtime: runtime, stateDirectory: f.state.path)
    func request(_ path: String, ready: Bool = true) -> VaultHTTPResponse {
        api.handle(request: Data("GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8),
                   indexReady: ready)
    }
    let detail = request("/v1/documents/\(id)/properties")
    #expect(detail.status == 200)
    let info = try #require(JSONSerialization.jsonObject(with: detail.body) as? [String: Any])
    #expect(info["state"] as? String == "valid")
    #expect((info["properties"] as? [[String: Any]])?.count == 2)
    #expect(request("/v1/tags").status == 200)
    #expect(request("/v1/properties").status == 200)
    let match = request("/v1/documents?tag=program&property=rating&value=5")
    #expect(match.status == 200)
    let listing = try #require(JSONSerialization.jsonObject(with: match.body) as? [String: Any])
    #expect(listing["total"] as? Int == 1)
    let operatorSearch = request("/v1/search?q=tag:%23program")
    #expect(operatorSearch.status == 200)
    let operatorJSON = try #require(
        JSONSerialization.jsonObject(with: operatorSearch.body) as? [String: Any])
    #expect((operatorJSON["hits"] as? [[String: Any]])?.count == 2)
    let propertySearch = request("/v1/search?q=%5Brating:5%5D")
    #expect(propertySearch.status == 200)
    let propertyJSON = try #require(
        JSONSerialization.jsonObject(with: propertySearch.body) as? [String: Any])
    #expect((propertyJSON["hits"] as? [[String: Any]])?.count == 1)
    #expect(request("/v1/search?q=%5Brating:%3E5%5D").status == 400)
    let search = request("/v1/search?q=search-for-property-uniquely&tag=program")
    #expect(search.status == 200)
    #expect(String(data: search.body, encoding: .utf8)?.contains("one.md") == true)
    #expect(request("/v1/documents?tag=1984").status == 400)
    #expect(request("/v1/documents?value=5").status == 400)
    #expect(request("/v1/documents?property=rating&value=5&tag=program",
                    ready: false).status == 503)
    #expect(request("/v1/tags?offset=-1").status == 400)
    #expect(request("/v1/documents/\(id)/properties?evil=1").status == 400)
    try runtime.shutdown()
}
#endif
