import Foundation
import Testing
@testable import AndesiteCore

@Test func searchIndexChecksRevisionAndVault() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = try SQLiteConnection(path: dir.appendingPathComponent("test.sqlite").path)
    try CatalogSchema.migrate(db)
    let vault = Data(repeating: 1, count: 16), otherVault = Data(repeating: 2, count: 16)
    let entry = Data(repeating: 3, count: 16), revision = Data(repeating: 4, count: 16)
    for id in [vault, otherVault] {
        try db.executeValues("INSERT INTO vaults(id,root_config,epoch,created_at,state) VALUES(?, 'root', ?, 'now', 'active')", bindings: [.blob(id), .blob(id)])
    }
    try db.executeValues("INSERT INTO entries(vault_id,id,kind,path,path_key,head_revision,state) VALUES(?,?,'markdown','a.md','a.md',?,'live')", bindings: [.blob(vault), .blob(entry), .blob(revision)])
    try SearchIndex.index(db: db, vaultID: vault, entryID: entry, revisionID: revision, bytes: Data("# Title\n\nA searchable phrase".utf8))
    #expect(try SearchIndex.search(db: db, vaultID: vault, phrase: "searchable phrase", limit: 10).map(\.title) == ["Title"])
    #expect(try SearchIndex.search(db: db, vaultID: otherVault, phrase: "searchable phrase", limit: 10).isEmpty)
    let next = Data(repeating: 5, count: 16)
    try db.executeValues("UPDATE entries SET head_revision=? WHERE vault_id=? AND id=?", bindings: [.blob(next), .blob(vault), .blob(entry)])
    #expect(try SearchIndex.search(db: db, vaultID: vault, phrase: "searchable", limit: 10).isEmpty)
    #expect(throws: SearchIndexError.staleRevision) { try SearchIndex.index(db: db, vaultID: vault, entryID: entry, revisionID: revision, bytes: Data("old".utf8)) }
    try SearchIndex.index(db: db, vaultID: vault, entryID: entry, revisionID: next, bytes: Data("# New\ncurrent text".utf8))
    #expect(try SearchIndex.search(db: db, vaultID: vault, phrase: "current", limit: 10).map(\.title) == ["New"])
    #expect(try SearchIndex.search(db: db, vaultID: vault, phrase: "searchable", limit: 10).isEmpty)
}
