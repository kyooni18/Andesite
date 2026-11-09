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
    public let path: String
}

/// A bounded, rebuildable FTS primitive, not the complete v1 search API.
/// All database access must be serialized with catalog writes. Callers must
/// parse immutable revision bytes off the network event loop.
public enum SearchIndex {
    public static func index(db: SQLiteConnection, vaultID: Data, entryID: Data, revisionID: Data, bytes: Data, withinTransaction: Bool = false) throws {
        guard vaultID.count == 16, entryID.count == 16, revisionID.count == 16 else { throw SearchIndexError.invalidIdentifier }
        let parsed = try ObsidianMetadataParser.parse(bytes)
        let facts = try MarkdownAnalyzer.analyze(Data(parsed.body.utf8))
        let body = parsed.state == "invalid" ?
            (String(data: bytes, encoding: .utf8) ?? "") : parsed.body
        let title = facts.headings.first?.text ?? ""
        let vaultKey = vaultID.map { String(format: "%02x", $0) }.joined()
        let entryKey = entryID.map { String(format: "%02x", $0) }.joined()
        let publish = {
            let rows = try db.queryValues("SELECT head_revision FROM entries WHERE vault_id=? AND id=? AND state='live' AND kind='markdown'", bindings: [.blob(vaultID), .blob(entryID)])
            guard rows == [[.blob(revisionID)]] else { throw SearchIndexError.staleRevision }
            try db.executeValues("INSERT INTO document_metadata(vault_id,entry_id,indexed_revision,title) VALUES(?,?,?,?) ON CONFLICT(vault_id,entry_id) DO UPDATE SET indexed_revision=excluded.indexed_revision,title=excluded.title", bindings: [.blob(vaultID), .blob(entryID), .blob(revisionID), .text(title)])
            try db.executeValues("DELETE FROM document_fts WHERE vault_id=? AND entry_id=?", bindings: [.text(vaultKey), .text(entryKey)])
            try db.executeValues("INSERT INTO document_fts(vault_id,entry_id,title,body) VALUES(?,?,?,?)", bindings: [.text(vaultKey), .text(entryKey), .text(title), .text(body)])
            try db.executeValues("""
                INSERT INTO document_properties(vault_id,entry_id,indexed_revision,state,properties_json,diagnostic)
                VALUES(?,?,?,?,?,?)
                ON CONFLICT(vault_id,entry_id) DO UPDATE SET
                indexed_revision=excluded.indexed_revision,
                state=excluded.state,
                properties_json=excluded.properties_json,
                diagnostic=excluded.diagnostic
                """, bindings: [.blob(vaultID), .blob(entryID), .blob(revisionID),
                                 .text(parsed.state), .text(parsed.propertiesJSON),
                                 parsed.diagnostic.map(SQLiteValue.text) ?? .null])
            try db.executeValues("DELETE FROM document_tags WHERE vault_id=? AND entry_id=?",
                                 bindings: [.blob(vaultID), .blob(entryID)])
            for tag in parsed.tags {
                try db.executeValues("""
                    INSERT INTO document_tags(vault_id,entry_id,indexed_revision,canonical,display,origin)
                    VALUES(?,?,?,?,?,?)
                    """, bindings: [.blob(vaultID), .blob(entryID), .blob(revisionID),
                                     .text(tag.canonical), .text(tag.name), .text(tag.origin)])
            }
            try db.executeValues("DELETE FROM document_property_values WHERE vault_id=? AND entry_id=?",
                                 bindings: [.blob(vaultID), .blob(entryID)])
            try db.executeValues("DELETE FROM document_property_keys WHERE vault_id=? AND entry_id=?",
                                 bindings: [.blob(vaultID), .blob(entryID)])
            for field in parsed.properties {
                guard let name = field["name"] as? String,
                      let kind = field["type"] as? String else {
                    throw SearchIndexError.staleRevision
                }
                try db.executeValues("""
                    INSERT INTO document_property_keys(
                        vault_id,entry_id,indexed_revision,name_key,display,kind
                    ) VALUES(?,?,?,?,?,?)
                    """, bindings: [.blob(vaultID), .blob(entryID), .blob(revisionID),
                                     .text(ObsidianMetadataParser.canonicalProperty(name)),
                                     .text(name), .text(kind)])
            }
            for scalar in parsed.scalars {
                try db.executeValues("""
                    INSERT INTO document_property_values(
                        vault_id,entry_id,indexed_revision,name_key,ordinal,value_type,value_text
                    ) VALUES(?,?,?,?,?,?,?)
                    """, bindings: [.blob(vaultID), .blob(entryID), .blob(revisionID),
                                     .text(scalar.property), .integer(Int64(scalar.ordinal)),
                                      .text(scalar.type),
                                     .text(ObsidianMetadataParser.canonicalProperty(scalar.text))])
            }
        }
        if withinTransaction { try publish() } else { try db.transaction(publish) }
    }

    /// Indexes every live Markdown head whose index is missing or stale (an
    /// interrupted index transaction, an upgraded catalog), from immutable
    /// stored content, never the mutable source file.
    /// A successful scan calls this before reporting indexed readiness.
    @discardableResult
    public static func backfillMetadata(db: SQLiteConnection, objects: ObjectStore,
                                        vaultID: Data, maximumBytes: Int) throws -> Int {
        let rows = try db.queryValues("""
            SELECT e.id,e.head_revision,lower(hex(r.content_hash)),r.byte_length
            FROM entries e JOIN revisions r
              ON r.vault_id=e.vault_id AND r.entry_id=e.id
              AND r.revision_id=e.head_revision AND r.deleted=0
            LEFT JOIN document_properties p
              ON p.vault_id=e.vault_id AND p.entry_id=e.id
              AND p.indexed_revision=e.head_revision
            LEFT JOIN document_metadata m
              ON m.vault_id=e.vault_id AND m.entry_id=e.id
              AND m.indexed_revision=e.head_revision
            WHERE e.vault_id=? AND e.state='live' AND e.kind='markdown'
              AND (p.entry_id IS NULL OR m.entry_id IS NULL)
            ORDER BY e.path
            """, bindings: [.blob(vaultID)])
        for row in rows {
            guard row.count == 4, case .blob(let entry) = row[0],
                  case .blob(let revision) = row[1],
                  case .text(let hash) = row[2],
                  case .integer(let length) = row[3],
                  length >= 0, length <= maximumBytes else {
                throw SearchIndexError.staleRevision
            }
            let bytes = try objects.get(hash, maximumBytes: Int(length))
            guard bytes.count == Int(length) else { throw SearchIndexError.staleRevision }
            try index(db: db, vaultID: vaultID, entryID: entry,
                      revisionID: revision, bytes: bytes)
        }
        return rows.count
    }

    /// Interprets the query as a literal FTS phrase, not FTS operator syntax.
    public static func search(db: SQLiteConnection, vaultID: Data, phrase: String, limit: Int,
                              filter: ObsidianFilter? = nil) throws -> [SearchIndexHit] {
        guard vaultID.count == 16 else { throw SearchIndexError.invalidIdentifier }
        guard !phrase.isEmpty, phrase.utf8.count <= 1024, !phrase.contains("\0"), (1...500).contains(limit) else { throw SearchIndexError.invalidQuery }
        let expression = "\"" + phrase.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let vaultKey = vaultID.map { String(format: "%02x", $0) }.joined()
        let statement = """
            SELECT m.entry_id,m.indexed_revision,m.title,e.path
            FROM document_fts f JOIN document_metadata m
              ON lower(hex(m.entry_id))=f.entry_id AND lower(hex(m.vault_id))=f.vault_id
            JOIN entries e ON e.vault_id=m.vault_id AND e.id=m.entry_id
            WHERE document_fts MATCH ? AND f.vault_id=? AND m.vault_id=?
              AND e.state='live' AND e.head_revision=m.indexed_revision
              AND NOT EXISTS (SELECT 1 FROM incidents i WHERE i.vault_id=e.vault_id AND (i.entry_id=e.id OR (i.entry_id IS NULL AND i.path_key=e.path_key)) AND i.status='open')
            """ + (filter?.sql ?? "") + " ORDER BY rank, m.entry_id LIMIT ?"
        let rows = try db.queryValues(statement, bindings: [
            .text(expression), .text(vaultKey), .blob(vaultID)
        ] + (filter?.bindings ?? []) + [.integer(Int64(limit))])
        return try rows.map { row in
            guard row.count == 4, case .blob(let entry) = row[0], case .blob(let revision) = row[1],
                  case .text(let title) = row[2], case .text(let path) = row[3] else {
                throw SQLiteFailure(code: 20, message: "invalid search index row")
            }
            return SearchIndexHit(entryID: entry, revisionID: revision, title: title, path: path)
        }
    }
}
