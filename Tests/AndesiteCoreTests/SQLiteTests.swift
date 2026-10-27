import Foundation
import Testing
@testable import AndesiteCore

@Test func databaseTransactionsAndFTS() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = try SQLiteConnection(path: directory.appendingPathComponent("test.sqlite").path)
    try db.execute("CREATE TABLE items (id TEXT PRIMARY KEY, value TEXT NOT NULL)")
    try db.execute("CREATE VIRTUAL TABLE search USING fts5(content)")
    try db.transaction {
        try db.execute("INSERT INTO items VALUES (?, ?)", bindings: ["1", "original"])
        try db.execute("INSERT INTO search VALUES (?)", bindings: ["searchable text"])
    }
    #expect(try db.scalarText("SELECT content FROM search WHERE search MATCH ?", bindings: ["searchable"]) == "searchable text")
    #expect(throws: SQLiteFailure.self) {
        try db.transaction {
            try db.execute("UPDATE items SET value = ? WHERE id = ?", bindings: ["changed", "1"])
            try db.execute("INSERT INTO items VALUES (?, ?)", bindings: ["1", "duplicate"])
        }
    }
    #expect(try db.scalarText("SELECT value FROM items WHERE id = ?", bindings: ["1"]) == "original")
    #expect(try db.scalarText("PRAGMA foreign_keys") == "1")
    try db.execute("INSERT INTO items VALUES (?, ?)", bindings: ["nul", "a\0b"])
    #expect(try db.scalarText("SELECT value FROM items WHERE id = ?", bindings: ["nul"]) == "a\0b")
}

@Test func typedSQLiteBindingsRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = try SQLiteConnection(path: directory.appendingPathComponent("test.sqlite").path)
    try db.execute("CREATE TABLE values_test (a BLOB, b BLOB, c INTEGER, d TEXT, e REAL, f TEXT)")
    let values: [SQLiteValue] = [.blob(Data([0, 255, 1])), .blob(Data()), .integer(Int64.max), .text("x\0y"), .real(1.5), .null]
    try db.executeValues("INSERT INTO values_test VALUES (?, ?, ?, ?, ?, ?)", bindings: values)
    #expect(try db.queryValues("SELECT * FROM values_test") == [values])
    #expect(throws: SQLiteFailure.self) { try db.executeValues("INSERT INTO values_test VALUES (?, ?, ?, ?, ?, ?)", bindings: []) }
}
