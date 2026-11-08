import Foundation

public enum DocumentCatalogError: Error, Equatable {
    case invalidIdentifier
    case invalidPage
    case notFound
    case inconsistentMetadata
    case contentTooLarge
}

public struct IndexedDocument: Equatable, Sendable {
    public let id: Data
    public let revisionID: Data
    public let path: String
    public let title: String
    public let hash: String
    public let byteLength: Int
}

public struct DocumentPage: Sendable {
    public let documents: [IndexedDocument]
    public let total: Int
    public let offset: Int
    public var nextOffset: Int? {
        offset + documents.count < total ? offset + documents.count : nil
    }
}

/// Read-only queries against the index head. Never reads mutable source
/// files; content comes only from verified SHA-256 immutable objects.
/// All calls must execute on the existing synchronous VaultRuntime owner.
public enum DocumentCatalog {
    private static let liveJoin = """
        FROM entries e
        JOIN document_metadata m ON m.vault_id=e.vault_id AND m.entry_id=e.id
          AND m.indexed_revision=e.head_revision
        JOIN revisions r ON r.vault_id=e.vault_id AND r.entry_id=e.id
          AND r.revision_id=e.head_revision AND r.deleted=0
        JOIN objects o ON o.hash=r.content_hash AND o.length=r.byte_length
        WHERE e.vault_id=? AND e.state='live' AND e.kind='markdown'
          AND NOT EXISTS (
            SELECT 1 FROM incidents i
            WHERE i.vault_id=e.vault_id AND i.status='open'
              AND (i.entry_id=e.id OR (i.entry_id IS NULL AND i.path_key=e.path_key))
          )
        """

    private static let fields = """
        SELECT e.id,e.head_revision,e.path,m.title,r.content_hash,r.byte_length
        """

    private static func availableCount(db: SQLiteConnection, vaultID: Data) throws -> Int {
        let expected = try db.queryValues(
            "SELECT count(*) FROM entries WHERE vault_id=? AND state='live' AND kind='markdown'",
            bindings: [.blob(vaultID)])
        let indexed = try db.queryValues(
            "SELECT count(*) " + liveJoin,
            bindings: [.blob(vaultID)])
        guard expected.count == 1, indexed.count == 1,
              case .integer(let a) = expected[0][0],
              case .integer(let b) = indexed[0][0],
              a >= 0, a == b, a <= Int64(Int.max) else {
            throw DocumentCatalogError.inconsistentMetadata
        }
        return Int(a)
    }

    private static func decode(_ row: [SQLiteValue]) throws -> IndexedDocument {
        guard row.count == 6,
              case .blob(let id) = row[0], id.count == 16,
              case .blob(let revision) = row[1], revision.count == 16,
              case .text(let path) = row[2],
              case .text(let title) = row[3],
              case .blob(let digest) = row[4], digest.count == 32,
              case .integer(let bytes) = row[5], bytes >= 0, bytes <= Int64(Int.max) else {
            throw DocumentCatalogError.inconsistentMetadata
        }
        return IndexedDocument(
            id: id, revisionID: revision, path: path, title: title,
            hash: digest.map { String(format: "%02x", $0) }.joined(),
            byteLength: Int(bytes))
    }

    public static func list(db: SQLiteConnection, vaultID: Data,
                            limit: Int = 50, offset: Int = 0) throws -> DocumentPage {
        guard (1...100).contains(limit), (0...100_000).contains(offset),
              vaultID.count == 16 else { throw DocumentCatalogError.invalidPage }
        let total = try availableCount(db: db, vaultID: vaultID)
        let rows = try db.queryValues(
            fields + " " + liveJoin + " ORDER BY e.path COLLATE BINARY, e.id LIMIT ? OFFSET ?",
            bindings: [.blob(vaultID), .integer(Int64(limit)), .integer(Int64(offset))])
        return DocumentPage(documents: try rows.map(decode), total: total, offset: offset)
    }

    public static func inspect(db: SQLiteConnection, vaultID: Data, documentID: Data) throws -> IndexedDocument {
        guard vaultID.count == 16, documentID.count == 16 else {
            throw DocumentCatalogError.invalidIdentifier
        }
        let rows = try db.queryValues(
            fields + " " + liveJoin + " AND e.id=? LIMIT 2",
            bindings: [.blob(vaultID), .blob(documentID)])
        if rows.isEmpty {
            // A live indexed head missing its metadata is corruption, not a
            // deleted/missing document. Never disguise that as HTTP 404.
            let live = try db.queryValues(
                "SELECT 1 FROM entries WHERE vault_id=? AND id=? AND state='live' AND kind='markdown'",
                bindings: [.blob(vaultID), .blob(documentID)])
            if !live.isEmpty { throw DocumentCatalogError.inconsistentMetadata }
            throw DocumentCatalogError.notFound
        }
        guard rows.count == 1 else { throw DocumentCatalogError.inconsistentMetadata }
        return try decode(rows[0])
    }

    public static func content(objects: ObjectStore, document: IndexedDocument,
                               maximumBytes: Int = 1024 * 1024) throws -> Data {
        guard maximumBytes > 0 else { throw DocumentCatalogError.invalidPage }
        guard document.byteLength <= maximumBytes else { throw DocumentCatalogError.contentTooLarge }
        let bytes = try objects.get(document.hash, maximumBytes: document.byteLength)
        guard bytes.count == document.byteLength else { throw DocumentCatalogError.inconsistentMetadata }
        return bytes
    }
}
