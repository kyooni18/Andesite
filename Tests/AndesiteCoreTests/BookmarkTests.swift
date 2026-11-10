import Foundation
import Testing
@testable import AndesiteCore

/// Obsidian's file round-trips, including fields Andesite doesn't model.
@Test func bookmarksReadAndWriteObsidiansFormat() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try FileManager.default.createDirectory(at: f.vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    let json = """
    {"items":[{"type":"file","ctime":1700000000000,"path":"Ideas.md","subpath":"#Plans"},
    {"type":"group","ctime":1700000000001,"title":"Reading","items":[{"type":"folder","ctime":1700000000002,"path":"Projects"}]},
    {"type":"graph","ctime":1700000000003,"title":"Graph","options":{"search":"tag:#a","showTags":true,"scale":1.5}}]}
    """
    try Data(json.utf8).write(to: f.vault.appendingPathComponent(".obsidian/bookmarks.json"))
    let store = BookmarkStore(vaultDirectory: f.vault.path)
    #expect(store.path.hasSuffix("/.obsidian/bookmarks.json"))

    let list = try store.load()
    #expect(list.all.map(\.type) == ["file", "group", "folder", "graph"])
    #expect(list.bookmark(forFile: "Ideas.md", subpath: "#Plans") != nil && list.bookmark(forFile: "Ideas.md") == nil)
    try store.update { try $0.move($0.items[0], into: $0.items[1], at: 0) }
    let reread = try store.load()
    #expect(reread.items.map(\.type) == ["group", "graph"])
    #expect(reread.items[0].items?.map(\.type) == ["file", "folder"])
    #expect(reread.items[1].extra["options"] == list.items[2].extra["options"])
    #expect(reread.items[1].ctime == 1700000000003)
}

/// Moves made through the API, and renames made outside it, carry
/// bookmarks along; deleting a file leaves its bookmark (as Obsidian).
@Test func bookmarksFollowMovedFilesAndFolders() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let vault = try VaultRuntime(configuration: f.configuration)
    _ = try vault.reconcile()
    let note = try vault.create("A/Note.md", Data("# Note\n".utf8))
    let other = try vault.create("Other.md", Data("x\n".utf8))
    try vault.bookmarkStore.update {
        $0.items = [.file("A/Note.md", subpath: "#Note"), .folder("A"), .file("Other.md"), .search("A/Note.md")]
    }
    #expect(vault.bookmarkStore.path.hasSuffix("/.andesite/bookmarks.json"))

    try vault.move("A/Note.md", to: "A/Renamed.md", revision: note.revisionID)
    try vault.moveDirectory("A", to: "B")
    var paths = try vault.bookmarkStore.load().items.map { $0.path ?? $0.query! }
    #expect(paths == ["B/Renamed.md", "B", "Other.md", "A/Note.md"])

    try FileManager.default.moveItem(at: f.vault.appendingPathComponent("Other.md"), to: f.vault.appendingPathComponent("Moved.md"))
    _ = try vault.reconcile()
    paths = try vault.bookmarkStore.load().items.map { $0.path ?? $0.query! }
    #expect(paths[2] == "Moved.md")

    try vault.delete("Moved.md", revision: try vault.document("Moved.md").revisionID)
    #expect(try vault.bookmarkStore.load().items.count == 4)
    _ = other
}
