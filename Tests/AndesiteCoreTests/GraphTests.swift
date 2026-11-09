import Foundation
import Testing
@testable import AndesiteCore

@Test func graphHasNotesLinkedAttachmentsAndResolvedEdgesOnly() async throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let vault = try f.open()
    defer { try? vault.close() }
    try vault.reconcile()
    let plan = try await vault.create("Projects/Plan.md", "---\ntags: [work]\n---\n# Plan\n#Work/Q3 [[Daily]]\n")
    try await vault.create("Other/Plan.md", "# Another plan\n")
    try await vault.create("assets/photo.png", Data([1, 2, 3]))
    try await vault.create("unlinked.png", Data([4]))
    let daily = try await vault.create("Daily.md", """
        [[Projects/Plan]] [[Projects/Plan#Goals|again]] ![[photo.png]] [[Plan]] [[Nowhere]]
        [md](Projects/Plan.md) [self](#top) [[Daily]] [web](https://example.com)
        """)
    let near = try await vault.create("Projects/Near.md", "[[Plan]] resolves next to it. [up](../Daily.md)\n")

    let graph = try await vault.graph()
    #expect(graph.nodes.map(\.path) == ["Daily.md", "Other/Plan.md", "Projects/Near.md", "Projects/Plan.md", "assets/photo.png"])
    let node = try #require(graph.nodes.first { $0.id == plan.id })
    #expect(node.name == "Plan" && node.folder == "Projects" && node.kind == "markdown")
    #expect(node.tags == ["work", "work/q3"])
    let photo = try #require(graph.nodes.first { $0.kind == "attachment" })
    // Three links from Daily to Plan are one edge; self-links and external links are none.
    let edges = Set(graph.edges.map { [$0.source, $0.target, Data([UInt8($0.count)])] })
    #expect(edges == [[daily.id, plan.id, Data([3])], [daily.id, photo.id, Data([1])],
                      [plan.id, daily.id, Data([1])], [near.id, plan.id, Data([1])], [near.id, daily.id, Data([1])]])
    #expect(Set(graph.unresolved.map { "\($0.target):\($0.status)" }) == ["Plan:ambiguous", "Nowhere:missing"])
    #expect(graph.unresolved.allSatisfy { $0.source == daily.id })

    // The graph agrees with the per-document link queries.
    let outgoing = try await vault.links("Daily.md").mentions.filter { $0.status == "resolved" && $0.documentID != daily.id }
    #expect(outgoing.count == graph.edges.filter { $0.source == daily.id }.map(\.count).reduce(0, +))
}

@Test func graphKeepsNodeIdentityAcrossRenamesAndFollowsLinkEdits() async throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let vault = try f.open()
    defer { try? vault.close() }
    try vault.reconcile()
    let target = try await vault.create("Target.md", "# Target\n")
    var source = try await vault.create("Source.md", "[[Target]]\n")

    let moved = try await vault.move("Target.md", to: "Archive/Renamed.md", revision: target.revisionID)
    var graph = try await vault.graph()
    #expect(moved.id == target.id)
    #expect(graph.nodes.first { $0.id == target.id }?.path == "Archive/Renamed.md")
    #expect(graph.edges.map(\.target) == [target.id])  // the link was rewritten to follow

    source = try await vault.read("Source.md").document
    try await vault.update("Source.md", "no links now [[Gone]]\n", revision: source.revisionID)
    graph = try await vault.graph()
    #expect(graph.edges.isEmpty && graph.unresolved.map(\.target) == ["Gone"])

    // Outside edits reach the graph once the index catches up.
    try f.write("Outside.md", "[[Renamed]]\n")
    try vault.reconcile()
    graph = try await vault.graph()
    #expect(graph.edges.count == 1 && graph.nodes.count == 3)
}

@Test func largeGraphIsReadInStepsAndMatchesEveryLink() async throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    // Written outside the API and indexed by one scan, like an existing vault.
    let count = 1500
    for index in 0..<count {
        let links = (1...4).map { "[[Note \((index + $0 * 37) % count)]]" }.joined(separator: " ")
        try f.write("Note \(index).md", "# Note \(index)\n\(links) [[Missing \(index % 10)]]\n")
    }
    let vault = try f.open()
    defer { try? vault.close() }
    try vault.reconcile()
    let started = Date()
    let graph = try await vault.graph()
    let elapsed = Date().timeIntervalSince(started)
    #expect(graph.nodes.count == count)
    // 6000 resolved links span more than one read step.
    #expect(graph.edges.map(\.count).reduce(0, +) == count * 4)
    #expect(graph.unresolved.count == count)
    print("graph of \(count) notes: \(elapsed)s")
    #expect(elapsed < 2, "graph took \(elapsed)s")
}

@Test func backlinkExcerptsShowTheLineAroundEachLink() async throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let vault = try f.open()
    defer { try? vault.close() }
    try vault.reconcile()
    try await vault.create("Plan.md", "# Plan\n")
    try await vault.create("Daily.md", "# Daily\n\nToday I reviewed the [[Plan|roadmap]] with the team.\n")
    let mentions = try await vault.links("Plan.md", direction: .incoming, excerpts: true).mentions
    #expect(mentions.count == 1)
    #expect(mentions[0].line == 3)
    #expect(mentions[0].excerpt == "Today I reviewed the [[Plan|roadmap]] with the team.")
    #expect(try await vault.links("Plan.md", direction: .incoming).mentions[0].excerpt == nil)
}

@Test func frontmatterEditsApplyToUnsavedTextAndDatesStayDates() throws {
    let text = Data("---\ntitle: Keep  # comment\ntags: [a]\n---\nBody #inline\n".utf8)
    var edited = try Frontmatter.setting("due", to: .date("2026-11-10"), in: text)
    edited = try Frontmatter.addingTag("project/sub", to: edited)
    edited = try Frontmatter.removingTag("a", from: edited)
    let result = String(decoding: edited, as: UTF8.self)
    #expect(result.hasPrefix("---\ntitle: Keep  # comment\n"))
    #expect(result.hasSuffix("---\nBody #inline\n"))
    let parsed = try ObsidianMetadataParser.parse(edited)
    let due = parsed.properties.first { $0["name"] as? String == "due" }
    #expect(due?["type"] as? String == "date" && due?["value"] as? String == "2026-11-10")
    #expect(parsed.tags.map(\.canonical) == ["project/sub", "inline"])
    #expect(throws: VaultError.self) { try Frontmatter.setting("due", to: .date("next week"), in: text) }
}
