import Foundation
import Testing
@testable import AndesiteCore

@Test func indexedDocumentsPageAndImmutableHeadAreSafeToRead() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let first = "# A\nFirst exact content\n"
    let second = "# B\nAnother note\n"
    try f.write("a.md", first)
    try f.write("z.md", second)
    let runtime = try VaultRuntime(configuration: f.configuration)
    #expect(try runtime.reconcile().revisionsCreated == 2)

    let full = try runtime.documents(limit: 20, offset: 0)
    #expect(full.total == 2)
    #expect(full.documents.map(\.path) == ["a.md", "z.md"])
    #expect(full.documents.map(\.title) == ["A", "B"])
    let page = try runtime.documents(limit: 1, offset: 0)
    #expect(page.documents.count == 1 && page.nextOffset == 1)
    let next = try runtime.documents(limit: 1, offset: 1)
    #expect(next.documents.count == 1 && next.nextOffset == nil)
    #expect(next.documents[0].id == full.documents[1].id)
    #expect(try runtime.documents(limit: 1, offset: 5).documents.isEmpty)

    let document = full.documents[0]
    #expect(try runtime.inspectDocument(document.id) == document)
    #expect(try runtime.documentContents(document.id) == Data(first.utf8))
    #expect(throws: DocumentCatalogError.invalidIdentifier) {
        try runtime.inspectDocument(Data([0x01]))
    }
    #expect(throws: DocumentCatalogError.invalidPage) { try runtime.documents(limit: 0) }
    #expect(throws: DocumentCatalogError.invalidPage) { try runtime.documents(limit: 101) }
    #expect(throws: DocumentCatalogError.invalidPage) { try runtime.documents(offset: -1) }
    #expect(throws: DocumentCatalogError.contentTooLarge) {
        try runtime.documentContents(document.id, maximumBytes: 2)
    }

    // A change not observed by the scanner must not silently be passed
    // through the catalog API as an indexed head revision.
    try f.write("a.md", "# Changed\nDifferent bytes\n")
    #expect(try runtime.documentContents(document.id) == Data(first.utf8))
    #expect(try runtime.reconcile().revisionsCreated == 1)
    #expect(try runtime.inspectDocument(document.id).revisionID != document.revisionID)
    #expect(try runtime.documentContents(document.id) == Data("# Changed\nDifferent bytes\n".utf8))
    try runtime.shutdown()
}

@Test func removedAndRenamedDocumentsPreserveStableIdentities() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("keep.md", "# Keep\nunchanged")
    try f.write("gone.md", "# Gone\nhistory")
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    let original = try runtime.documents(limit: 10).documents
    let kept = try #require(original.first(where: { $0.path == "keep.md" }))
    let gone = try #require(original.first(where: { $0.path == "gone.md" }))
    let snapshots = try runtime.snapshots(entryID: gone.id)
    #expect(!snapshots.isEmpty)
    try FileManager.default.moveItem(at: f.vault.appendingPathComponent("keep.md"),
                                     to: f.vault.appendingPathComponent("renamed.md"))
    try FileManager.default.removeItem(at: f.vault.appendingPathComponent("gone.md"))
    _ = try runtime.reconcile()
    let next = try runtime.documents()
    #expect(next.total == 1)
    #expect(next.documents[0].id == kept.id)
    #expect(next.documents[0].path == "renamed.md")
    #expect(throws: DocumentCatalogError.notFound) { try runtime.inspectDocument(gone.id) }
    #expect(try runtime.snapshots(entryID: gone.id).count == snapshots.count)
    try runtime.shutdown()
}

@Test func simpleWikilinkLexerHandlesObsidianSyntaxWithoutInventingResolution() throws {
    let source = """
    # Chapter
    [[정리]] and [[Folder/Page#Details|이름]]
    ![[image.png|200]] [[#Local Heading]]
    `[[inside code]]`
    ```md
    [[in fence]]
    ```
    ~~~
    [[in tilde fence]]
    ~~~
    Four spaces code:
        [[indented]]
    \\[[escaped]]
    """
    let results = ObsidianLinks.extract(source)
    #expect(results == [
        .init(target: "정리", fragment: nil, alias: nil, embed: false),
        .init(target: "Folder/Page", fragment: "Details", alias: "이름", embed: false),
        .init(target: "image.png", fragment: nil, alias: "200", embed: true),
        .init(target: "", fragment: "Local Heading", alias: nil, embed: false)
    ])
}

@Test func defaultObsidianConfigurationIsExcludedWithoutDeletingSettings() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "# Visible\n")
    let config = f.vault.appendingPathComponent(".obsidian")
    try FileManager.default.createDirectory(
        at: config, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o755])
    let settings = config.appendingPathComponent("app.json")
    let plugin = config.appendingPathComponent("plugins")
    try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: false)
    let privateNote = plugin.appendingPathComponent("README.md")
    try Data("{\"vimMode\":true}".utf8).write(to: settings)
    try Data("# Plugin README\nnot a user note".utf8).write(to: privateNote)

    let runtime = try VaultRuntime(configuration: f.configuration)
    #expect(try runtime.reconcile().discovered == 1)
    #expect(try runtime.documents().documents.map(\.path) == ["note.md"])
    #expect(try Data(contentsOf: settings) == Data("{\"vimMode\":true}".utf8))
    #expect(try Data(contentsOf: privateNote) == Data("# Plugin README\nnot a user note".utf8))
    try runtime.shutdown()
}

@Test func trashedNotesAndGitMetadataAreNotLiveObsidianDocuments() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("active.md", "# Active\n")
    let trash = f.vault.appendingPathComponent(".trash")
    let git = f.vault.appendingPathComponent(".git")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: false)
    try Data("# Trashed\n".utf8).write(to: trash.appendingPathComponent("discard.md"))
    try Data("# Git internal\n".utf8).write(to: git.appendingPathComponent("README.md"))
    let runtime = try VaultRuntime(configuration: f.configuration)
    #expect(try runtime.reconcile().discovered == 1)
    #expect(try runtime.documents().documents.map(\.path) == ["active.md"])
    #expect(try Data(contentsOf: trash.appendingPathComponent("discard.md")) ==
            Data("# Trashed\n".utf8))
    try runtime.shutdown()
}
