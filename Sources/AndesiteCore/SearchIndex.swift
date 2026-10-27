import Foundation

public enum SearchIndexError: Error, Equatable {
    case invalidIdentifier
    case invalidQuery
    case staleRevision
}

public struct SearchIndexHit: Equatable, Sendable {
    public let entryID: Data
    public let revisionID: Data
    public let title: String
}

/// A bounded, rebuildable FTS primitive, not the complete v1 search API.
/// All database access must be serialized with catalog writes. Callers must
/// parse immutable revision bytes off the network event loop.
public enum SearchIndex {
    public static func index(db: SQLiteConnection, vaultID: Data, entryID: Data, revisionID: Data, bytes: Data) throws {
        guard vaultID.count == 16, entryID.count == 16, revisionID.count == 16 else { throw SearchIndexError.invalidIdentifier }
        let facts = try MarkdownAnalyzer.analyze(bytes)
        guard let body = String(data: bytes, encoding: .utf8) else { throw MarkdownAnalysisError.invalidUTF8 }
        let title = facts.headings.first?.text ?? ""
        let vaultKey = vaultID.map { String(format: "%02x", $0) }.joined()
        let entryKey = entryID.map { String(format: "%02x", $0) }.joined()
        try db.transaction {
            let rows = try db.queryValues("SELECT head_revision FROM entries WHERE vault_id=? AND id=? AND state='live' AND kind='markdown'", bindings: [.blob(vaultID), .blob(entryID)])
            guard rows == [[.blob(revisionID)]] else { throw SearchIndexError.staleRevision }
            try db.executeValues("INSERT INTO document_metadata(vault_id,entry_id,indexed_revision,title) VALUES(?,?,?,?) ON CONFLICT(vault_id,entry_id) DO UPDATE SET indexed_revision=excluded.indexed_revision,title=excluded.title", bindings: [.blob(vaultID), .blob(entryID), .blob(revisionID), .text(title)])
            try db.executeValues("DELETE FROM document_fts WHERE vault_id=? AND entry_id=?", bindings: [.text(vaultKey), .text(entryKey)])
            try db.executeValues("INSERT INTO document_fts(vault_id,entry_id,title,body) VALUES(?,?,?,?)", bindings: [.text(vaultKey), .text(entryKey), .text(title), .text(body)])
        }
    }

    /// Interprets the query as a literal FTS phrase, not FTS operator syntax.
    public static func search(db: SQLiteConnection, vaultID: Data, phrase: String, limit: Int) throws -> [SearchIndexHit] {
        guard vaultID.count == 16 else { throw SearchIndexError.invalidIdentifier }
        guard !phrase.isEmpty, phrase.utf8.count <= 1024, !phrase.contains("\0"), (1...500).contains(limit) else { throw SearchIndexError.invalidQuery }
        let expression = "\"" + phrase.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let vaultKey = vaultID.map { String(format: "%02x", $0) }.joined()
        let rows = try db.queryValues("""
            SELECT m.entry_id,m.indexed_revision,m.title
            FROM document_fts f JOIN document_metadata m
              ON lower(hex(m.entry_id))=f.entry_id AND lower(hex(m.vault_id))=f.vault_id
            JOIN entries e ON e.vault_id=m.vault_id AND e.id=m.entry_id
            WHERE document_fts MATCH ? AND f.vault_id=? AND m.vault_id=?
              AND e.state='live' AND e.head_revision=m.indexed_revision
              AND NOT EXISTS (SELECT 1 FROM incidents i WHERE i.vault_id=e.vault_id AND i.path_key=e.path_key AND i.status='open')
            ORDER BY rank, m.entry_id LIMIT ?
            """, bindings: [.text(expression), .text(vaultKey), .blob(vaultID), .integer(Int64(limit))])
        return try rows.map { row in
            guard row.count == 3, case .blob(let entry) = row[0], case .blob(let revision) = row[1], case .text(let title) = row[2] else {
                throw SQLiteFailure(code: 20, message: "invalid search index row")
            }
            return SearchIndexHit(entryID: entry, revisionID: revision, title: title)
        }
    }
}
