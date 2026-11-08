import Foundation
import Testing
@testable import AndesiteCore

@Test func resolvedLinksBacklinksAndConservativeAmbiguity() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    for folder in ["Folder", "Other"] {
        try FileManager.default.createDirectory(
            at: f.vault.appendingPathComponent(folder),
            withIntermediateDirectories: false)
    }
    try f.write("Folder/Intro.md", """
    # Head
    First paragraph ^b-123
    ## Another heading
    """)
    try f.write("Other/Intro.md", "# Alternate\n")
    try f.write("Artificial Intelligence.md", """
    ---
    aliases:
      - AI
      - "머신 지능"
    ---
    # Canonical
    """)
    try f.write("Main.md", """
    # Main
    [[Folder/Intro]]
    [[Folder/Intro.md#Head|Display]]
    [[Folder/Intro#^b-123]]
    [[Folder/Intro#Absent]]
    [Markdown](Folder/Intro.md#Head)
    [[Intro]]
    [[AI]]
    [[Artificial Intelligence|AI]]
    [[#Main]]
    [[Missing]]
    [External](https://example.com/#foo)
    ![[graphic.png]]
    `[[code excluded]]`
    ```md
    [[fenced excluded]]
    ```
    """)

    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    _ = try runtime.refreshLinkCache()
    let docs = try runtime.documents(limit: 20).documents
    let source = try #require(docs.first(where: { $0.path == "Main.md" }))
    let intro = try #require(docs.first(where: { $0.path == "Folder/Intro.md" }))
    let other = try #require(docs.first(where: { $0.path == "Other/Intro.md" }))

    let outgoing = try runtime.links(source.id, direction: .outgoing, limit: 50)
    #expect(outgoing.total == 12)
    let references = outgoing.mentions
    #expect(references.filter { $0.status == "resolved" }.count == 7)
    #expect(references.contains(where: {
        $0.target == "Folder/Intro" && $0.documentID == intro.id
    }))
    #expect(references.contains(where: {
        $0.fragment == "Head" && $0.fragmentStatus == "resolved"
    }))
    #expect(references.contains(where: {
        $0.fragment == "^b-123" && $0.fragmentStatus == "resolved"
    }))
    #expect(references.contains(where: {
        $0.fragment == "Absent" && $0.fragmentStatus == "missing" &&
        $0.documentID == intro.id
    }))
    #expect(references.contains(where: {
        $0.target == "Intro" && $0.status == "ambiguous" && $0.documentID == nil
    }))
    #expect(references.contains(where: {
        $0.target == "AI" && $0.status == "missing" &&
        $0.aliasSuggestions == ["Artificial Intelligence.md"]
    }))
    #expect(references.contains(where: {
        $0.target == "Artificial Intelligence" && $0.status == "resolved" &&
        $0.display == "AI"
    }))
    let selfMention = references.first(where: { $0.target == "" && $0.fragment == "Main" })
    let selfMentionMatches = selfMention?.documentID == source.id
    #expect(selfMentionMatches)
    #expect(selfMention?.fragmentStatus == "resolved")
    #expect(references.contains(where: {
        $0.target == "https://example.com/" && $0.status == "external"
    }))
    #expect(references.contains(where: {
        $0.target == "graphic.png" && $0.status == "unsupported" && $0.embed
    }))
    #expect(!references.contains(where: { $0.target.contains("excluded") }))

    let incoming = try runtime.links(intro.id, direction: .incoming)
    #expect(incoming.total == 5)
    #expect(incoming.mentions.allSatisfy({
        $0.documentID == intro.id && $0.sourceID == source.id
    }))
    #expect(try runtime.links(other.id, direction: .incoming).total == 0)
    let first = try runtime.links(intro.id, direction: .incoming, limit: 2)
    #expect(first.mentions.count == 2 && first.nextOffset == 2)
    let later = try runtime.links(intro.id, direction: .incoming, limit: 2, offset: 2)
    #expect(later.mentions.count == 2 && later.nextOffset == 4)

    #expect(throws: VaultLinkGraphError.invalidQuery) {
        try runtime.links(intro.id, direction: .incoming, limit: 0)
    }
    #expect(throws: VaultLinkGraphError.invalidQuery) {
        try runtime.links(intro.id, direction: .incoming, offset: -1)
    }
    try runtime.shutdown()
}

@Test func backlinksRebuildAfterReconcileAndDoNotRewriteObsidianFiles() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("Target.md", "# Existing\n")
    try f.write("Caller.md", "[[Target]]\n")
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    _ = try runtime.refreshLinkCache()
    let docs = try runtime.documents().documents
    let target = try #require(docs.first(where: { $0.path == "Target.md" }))
    let caller = try #require(docs.first(where: { $0.path == "Caller.md" }))
    #expect(try runtime.links(target.id, direction: .incoming).total == 1)

    try f.write("Caller.md", "# Rewritten\n[[Missing]]\n")
    // Until reconciliation, links still describe the immutable indexed head.
    #expect(try runtime.links(target.id, direction: .incoming).total == 1)
    #expect(try runtime.reconcile().revisionsCreated == 1)
    _ = try runtime.refreshLinkCache()
    #expect(try runtime.links(target.id, direction: .incoming).total == 0)
    #expect(try runtime.links(caller.id, direction: .outgoing).mentions.first?.status == "missing")

    try FileManager.default.moveItem(
        at: f.vault.appendingPathComponent("Target.md"),
        to: f.vault.appendingPathComponent("Renamed.md"))
    _ = try runtime.reconcile()
    _ = try runtime.refreshLinkCache()
    #expect(try runtime.inspectDocument(target.id).path == "Renamed.md")
    #expect(try runtime.links(target.id, direction: .incoming).total == 0)
    #expect(try runtime.status().revisions >= 3)
    #expect(try String(contentsOf: f.vault.appendingPathComponent("Caller.md"),
                       encoding: .utf8) == "# Rewritten\n[[Missing]]\n")
    try runtime.shutdown()
}

@Test func linkGraphRejectsOversizedNotesRatherThanLosingBacklinks() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("small.md", "# Small\n")
    let longNote = "# Large\n" + String(repeating: "a", count: 270_000) + "\n[[small]]"
    try f.write("large.md", longNote)
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    let target = try #require(try runtime.documents().documents.first {
        $0.path == "small.md"
    })
    #expect(throws: VaultLinkGraphError.graphTooLarge) {
        try runtime.refreshLinkCache()
    }
    #expect(throws: VaultLinkGraphError.graphTooLarge) {
        try runtime.links(target.id, direction: .incoming)
    }
    // The original note bytes and search index are not changed by refusal.
    #expect(try runtime.documentContents(target.id) == Data("# Small\n".utf8))
    try runtime.shutdown()
}

@Test func percentEncodedMarkdownAndRelativeTargetsAreBounded() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try FileManager.default.createDirectory(
        at: f.vault.appendingPathComponent("Parent"), withIntermediateDirectories: false)
    try f.write("a note.md", "# Heading\n")
    try f.write("Parent/Caller.md", """
    [Root](a%20note.md#Heading)
    [Relative](../a%20note.md)
    [No Escape](../../outside.md)
    [Local](./Sibling.md)
    """)
    try f.write("Parent/Sibling.md", "# Sibling\n")
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    _ = try runtime.refreshLinkCache()
    let id = try #require(try runtime.documents().documents.first {
        $0.path == "Parent/Caller.md"
    }).id
    let outgoing = try runtime.links(id, direction: .outgoing)
    #expect(outgoing.total == 4)
    #expect(outgoing.mentions.filter { $0.status == "resolved" }.count == 3)
    #expect(outgoing.mentions.contains(where: {
        $0.target == "a%20note.md" && $0.fragmentStatus == "resolved"
    }))
    #expect(outgoing.mentions.contains(where: {
        $0.target == "../../outside.md" && $0.status == "unsupported"
    }))
    try runtime.shutdown()
}

@Test func globalHeadingSearchIsUnsupportedAndEscapedMarkdownAnchorsResolve() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("One.md", "# Two Words\n")
    try f.write("Caller.md", """
    [Section](One.md#Two%20Words)
    [[##Words]]
    [[^^reference]]
    """)
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    _ = try runtime.refreshLinkCache()
    let caller = try #require(try runtime.documents().documents.first {
        $0.path == "Caller.md"
    }).id
    let mentions = try runtime.links(caller, direction: .outgoing).mentions
    #expect(mentions.count == 3)
    let escapedAnchor = mentions.first(where: { $0.syntax == "markdown" })
    #expect(escapedAnchor?.status == "resolved")
    #expect(escapedAnchor?.fragment == "Two Words")
    #expect(escapedAnchor?.fragmentStatus == "resolved")
    #expect(mentions.filter({ $0.status == "unsupported" }).count == 2)
    try runtime.shutdown()
}
