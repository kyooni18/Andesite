import Foundation
import Testing
@testable import AndesiteCore

@Test func linkLexerFindsWikiAndMarkdownLinksWithPositionsOutsideCode() throws {
    let source = """
    ---
    related: "[[정리]]"
    ---
    # Chapter
    [[정리]] and [[Folder/Page#Details|이름]] and [text](../Other%20Note.md#Part "title")
    ![[image.png|200]] [[#Local Heading]] ![alt](<assets/a b.png>)
    `[[inside code]]` and `[x](y.md)`
    ```md
    [[in fence]]
    ```
        [[indented]]
    \\[[escaped]]
    """
    let links = ObsidianLinks.extract(source)
    #expect(links.map(\.target) == ["정리", "정리", "Folder/Page", "../Other%20Note.md", "image.png", "", "assets/a b.png"])
    #expect(links.map(\.syntax) == ["wikilink", "wikilink", "wikilink", "markdown", "wikilink", "wikilink", "markdown"])
    #expect(links[2].fragment == "Details" && links[2].display == "이름")
    #expect(links[3].fragment == "Part" && links[3].display == "text")
    #expect(links[4].embed && links[4].display == "200" && links[6].embed)
    #expect(links[5].fragment == "Local Heading")
    let bytes = Array(source.utf8)
    for link in links {
        #expect(String(decoding: bytes[link.targetRange], as: UTF8.self) == link.target)
    }
}

@Test func linksResolveBacklinksEmbedsFragmentsAndMentions() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let vault = try VaultRuntime(configuration: f.configuration)
    _ = try vault.reconcile()
    let target = try vault.create("Projects/Plan.md", Data("---\naliases: [Roadmap]\n---\n# Plan\n## Goals\nship it ^goal-1\n".utf8))
    try vault.create("assets/photo.png", Data([1, 2, 3]))
    try vault.create("Daily.md", Data("""
        [[Plan#Goals]] [[Plan#Missing]] [[plan#^goal-1|ref]] ![[photo.png]]
        [md](Projects/Plan.md) [[Nowhere]] [web](https://example.com)
        """.utf8))
    try vault.create("Other/Plan.md", Data("# Another plan\n".utf8))
    try vault.create("Projects/Near.md", Data("[[Plan]] is ambiguous by name, but this one is next to it.\n".utf8))
    try vault.create("Mentions.md", Data("The Roadmap and the Plan are discussed here.\n".utf8))

    let daily = try vault.document("Daily.md")
    let outgoing = try vault.links(daily.id, direction: .outgoing).mentions
    #expect(outgoing.map(\.status) == ["ambiguous", "ambiguous", "ambiguous", "resolved", "resolved", "missing", "external"])
    #expect(outgoing[3].documentPath == "assets/photo.png" && outgoing[3].embed)
    #expect(outgoing[4].documentID == target.id && outgoing[4].fragmentStatus == "none")

    // Unique once the second "Plan" is gone.
    try vault.delete("Other/Plan.md", revision: try vault.document("Other/Plan.md").revisionID)
    let resolved = try vault.links(daily.id, direction: .outgoing).mentions
    #expect(resolved.prefix(3).map(\.fragmentStatus) == ["resolved", "missing", "resolved"])
    let backlinks = try vault.links(target.id, direction: .incoming).mentions
    #expect(Set(backlinks.map(\.sourcePath)) == ["Daily.md", "Projects/Near.md"])
    #expect(try vault.unlinkedMentions(target.id).map(\.sourcePath) == ["Mentions.md"])
    try vault.shutdown()
}

@Test func renamingUpdatesUnambiguousLinksInEveryStyle() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let vault = try VaultRuntime(configuration: f.configuration)
    _ = try vault.reconcile()
    let note = try vault.create("Notes/Old Name.md", Data("# Old\nSee [sibling](Sibling.md)\n".utf8))
    try vault.create("Notes/Sibling.md", Data("# Sibling\n".utf8))
    try vault.create("Index.md", Data("""
        ---
        up: "[[Old Name]]"
        ---
        [[Old Name]], [[Notes/Old Name#Old|alias]], ![[Old Name]]
        [md](Notes/Old%20Name.md) and `[[Old Name]]` in code
        """.utf8))
    try vault.create("Notes/Deep/Child.md", Data("[up](../Old%20Name.md)\n".utf8))

    try vault.move("Notes/Old Name.md", to: "Archive/New Name.md", revision: note.revisionID)
    #expect(try String(decoding: vault.read("Index.md").content, as: UTF8.self) == """
        ---
        up: "[[New Name]]"
        ---
        [[New Name]], [[Archive/New Name#Old|alias]], ![[New Name]]
        [md](Archive/New%20Name.md) and `[[Old Name]]` in code
        """)
    #expect(try String(decoding: vault.read("Notes/Deep/Child.md").content, as: UTF8.self) == "[up](../../Archive/New%20Name.md)\n")
    // The moved note's own relative link still reaches its sibling.
    #expect(try String(decoding: vault.read("Archive/New Name.md").content, as: UTF8.self) == "# Old\nSee [sibling](../Notes/Sibling.md)\n")
    let moved = try vault.document("Archive/New Name.md")
    #expect(try vault.links(moved.id, direction: .incoming).total == 6)

    // Renamed to a name another note already has: links are written as paths.
    try vault.create("Elsewhere/Final.md", Data("other\n".utf8))
    try vault.move("Archive/New Name.md", to: "Archive/Final.md", revision: moved.revisionID)
    var index = try String(decoding: vault.read("Index.md").content, as: UTF8.self)
    #expect(index.contains("[[Archive/Final]], [[Archive/Final#Old|alias]], ![[Archive/Final]]"))
    #expect(index.contains("[md](Archive/Final.md)"))
    // Folder moves update path-style links to everything inside.
    try vault.moveDirectory("Archive", to: "Vault Archive")
    index = try String(decoding: vault.read("Index.md").content, as: UTF8.self)
    #expect(index.contains("up: \"[[Vault Archive/Final]]\""))
    #expect(index.contains("[md](Vault%20Archive/Final.md)"))
    #expect(try vault.links(vault.document("Vault Archive/Final.md").id, direction: .incoming).total == 6)
    try vault.shutdown()
}

@Test func propertyAndTagEditsChangeOnlyTheirOwnLines() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let vault = try VaultRuntime(configuration: f.configuration)
    _ = try vault.reconcile()
    let original = "---\r\ntitle:   Keep  # comment\r\ntags:\r\n  - one\r\nstatus: draft\r\n---\r\nBody #inline\r\n"
    var doc = try vault.create("note.md", Data(original.utf8))
    doc = try vault.setProperty("note.md", "status", to: .text("done: yes"), revision: doc.revisionID)
    doc = try vault.addTag("note.md", "#Project/Two", revision: doc.revisionID)
    doc = try vault.setProperty("note.md", "rating", to: .number(5), revision: doc.revisionID)
    #expect(try String(decoding: vault.read("note.md").content, as: UTF8.self) ==
            "---\r\ntitle:   Keep  # comment\r\ntags:\r\n- one\r\n- Project/Two\r\nstatus: 'done: yes'\r\nrating: 5\r\n---\r\nBody #inline\r\n")
    doc = try vault.removeTag("note.md", "one", revision: doc.revisionID)
    doc = try vault.removeTag("note.md", "project/two", revision: doc.revisionID)
    doc = try vault.setProperty("note.md", "rating", to: nil, revision: doc.revisionID)
    #expect(try String(decoding: vault.read("note.md").content, as: UTF8.self) ==
            "---\r\ntitle:   Keep  # comment\r\nstatus: 'done: yes'\r\n---\r\nBody #inline\r\n")
    #expect(try vault.documents(filter: ObsidianFilter(tag: nil, property: "status", value: "done: yes")).total == 1)

    let plain = try vault.create("plain.md", Data("Just text\n".utf8))
    try vault.addTag("plain.md", "new", revision: plain.revisionID)
    #expect(try String(decoding: vault.read("plain.md").content, as: UTF8.self) == "---\ntags:\n- new\n---\nJust text\n")
    let broken = try vault.create("broken.md", Data("---\nkey: [unclosed\n---\n".utf8))
    #expect(throws: VaultError.self) { try vault.addTag("broken.md", "x", revision: broken.revisionID) }
    try vault.shutdown()
}
