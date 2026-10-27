import Foundation
import Testing
@testable import AndesiteCore

@Test func migrationsAreTransactionalAndRejectNewerCatalogs() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = try SQLiteConnection(path: dir.appendingPathComponent("catalog.sqlite").path)
    try CatalogSchema.migrate(db)
    try CatalogSchema.migrate(db)
    #expect(try db.scalarText("PRAGMA user_version") == "1")
    try db.execute("INSERT INTO vaults(id,root_config,epoch,created_at,state) VALUES(zeroblob(16),'root',zeroblob(16),'now','active')")
    #expect(throws: SQLiteFailure.self) {
        try db.execute("INSERT INTO vaults(id,root_config,epoch,created_at,state) VALUES(zeroblob(15),'root',zeroblob(16),'now','active')")
    }
    #expect(throws: SQLiteFailure.self) {
        try db.execute("INSERT INTO entries(vault_id,id,kind,state) VALUES(randomblob(16),randomblob(16),'markdown','reserved')")
    }
    try db.execute("PRAGMA user_version=99")
    #expect(throws: CatalogMigrationError.unsupportedVersion(99)) { try CatalogSchema.migrate(db) }
    #expect(try db.scalarText("PRAGMA user_version") == "99")

    let broken = try SQLiteConnection(path: dir.appendingPathComponent("broken.sqlite").path)
    try broken.execute("CREATE TABLE entries(x INTEGER)")
    #expect(throws: SQLiteFailure.self) { try CatalogSchema.migrate(broken) }
    #expect(try broken.scalarText("PRAGMA user_version") == "0")
    #expect(try broken.scalarText("SELECT name FROM sqlite_master WHERE name='vaults'") == nil)
}
