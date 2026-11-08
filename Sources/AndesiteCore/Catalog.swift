import Foundation

/// One revision in a document's history. Revision and document IDs are
/// globally unique, so the same record describes the revision on every peer.
public struct RevisionRecord: Codable, Equatable, Sendable {
    public var entry: Data
    public var revision: Data
    public var parents: [Data]
    public var path: String
    public var deleted: Bool
    public var hash: String?
    public var size: Int64?
    public var kind: String
    public var origin: String
}

/// The catalog state of one entry (document or attachment).
struct CatalogEntry {
    let id: Data
    let kind: String
    let state: String
    let path: String?
    let head: Data?
    let hash: String?
    let size: Int64?
    let hint: FileFingerprint?
}

/// Row-level catalog writes shared by external capture, local mutations
/// and remote revisions. Callers own the surrounding transaction.
enum Catalog {
    private static let entryColumns = """
        SELECT e.id,e.kind,e.state,e.path,e.head_revision,
               CASE WHEN r.deleted=0 THEN lower(hex(r.content_hash)) END,r.byte_length,e.fs_hint
        FROM entries e LEFT JOIN revisions r ON r.vault_id=e.vault_id AND r.revision_id=e.head_revision
        """

    static func entry(db: SQLiteConnection, vaultID: Data, id: Data) throws -> CatalogEntry? {
        try db.queryValues(entryColumns + " WHERE e.vault_id=? AND e.id=?",
                           bindings: [.blob(vaultID), .blob(id)]).first.map(decode)
    }

    static func live(db: SQLiteConnection, vaultID: Data, path: String) throws -> CatalogEntry? {
        try db.queryValues(entryColumns + " WHERE e.vault_id=? AND e.state='live' AND e.path_key=?",
                           bindings: [.blob(vaultID), .text(VaultPath(path).portabilityKey)]).first.map(decode)
    }

    static func liveEntries(db: SQLiteConnection, vaultID: Data, under prefix: String) throws -> [CatalogEntry] {
        let key = try VaultPath(String(prefix.dropLast())).portabilityKey + "/"
        return try db.queryValues(entryColumns + " WHERE e.vault_id=? AND e.state='live' AND substr(e.path_key,1,?)=? ORDER BY e.path",
                                  bindings: [.blob(vaultID), .integer(Int64(key.count)), .text(key)]).map(decode)
    }

    private static func decode(_ row: [SQLiteValue]) throws -> CatalogEntry {
        guard case .blob(let id) = row[0], case .text(let kind) = row[1], case .text(let state) = row[2] else {
            throw VaultRuntimeError.inconsistentCatalog
        }
        var path: String?, head: Data?, hash: String?, size: Int64?, hint: FileFingerprint?
        if case .text(let value) = row[3] { path = value }
        if case .blob(let value) = row[4] { head = value }
        if case .text(let value) = row[5] { hash = value }
        if case .integer(let value) = row[6] { size = value }
        if case .blob(let value) = row[7] { hint = try? JSONDecoder().decode(FileFingerprint.self, from: value) }
        return CatalogEntry(id: id, kind: kind, state: state, path: path, head: head, hash: hash, size: size, hint: hint)
    }

    static func knows(db: SQLiteConnection, vaultID: Data, revision: Data) throws -> Bool {
        try !db.queryValues("SELECT 1 FROM revisions WHERE vault_id=? AND revision_id=?",
                            bindings: [.blob(vaultID), .blob(revision)]).isEmpty
    }

    /// Inserts a revision (and its change event) without moving the head.
    /// Idempotent for an already known revision.
    static func record(db: SQLiteConnection, vaultID: Data, _ r: RevisionRecord) throws {
        if try knows(db: db, vaultID: vaultID, revision: r.revision) { return }
        if try entry(db: db, vaultID: vaultID, id: r.entry) == nil {
            try db.executeValues("INSERT INTO entries(vault_id,id,kind,state) VALUES(?,?,?,'reserved')",
                                 bindings: [.blob(vaultID), .blob(r.entry), .text(r.kind)])
        }
        if let hash = r.hash, let size = r.size { try registerObject(db: db, hash: hash, size: size) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try db.executeValues("""
            INSERT INTO revisions(vault_id,entry_id,revision_id,parent1,parent2,content_hash,byte_length,path,deleted,origin,created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, bindings: [.blob(vaultID), .blob(r.entry), .blob(r.revision),
                            r.parents.first.map(SQLiteValue.blob) ?? .null,
                            r.parents.count > 1 ? .blob(r.parents[1]) : .null,
                            r.hash.flatMap { Data(hex: $0) }.map(SQLiteValue.blob) ?? .null,
                            r.size.map(SQLiteValue.integer) ?? .null,
                            .text(r.path), .integer(r.deleted ? 1 : 0), .text(r.origin), .text(timestamp)])
        try appendChange(db: db, vaultID: vaultID, r, type: try changeType(db: db, vaultID: vaultID, r))
    }

    /// Describes a revision relative to its first parent.
    private static func changeType(db: SQLiteConnection, vaultID: Data, _ r: RevisionRecord) throws -> String {
        if r.deleted { return "deleted" }
        guard let parent = r.parents.first, let row = try db.queryValues(
            "SELECT path,deleted FROM revisions WHERE vault_id=? AND revision_id=?",
            bindings: [.blob(vaultID), .blob(parent)]).first,
              case .text(let path) = row[0], row[1] == .integer(0) else { return "created" }
        return Array(path.utf8) == Array(r.path.utf8) ? "updated" : "moved"
    }

    /// Records a revision and makes it the entry's head.
    static func setHead(db: SQLiteConnection, vaultID: Data, _ r: RevisionRecord, hint: FileFingerprint?) throws {
        if try !knows(db: db, vaultID: vaultID, revision: r.revision) {
            try record(db: db, vaultID: vaultID, r)
        }
        if r.deleted {
            try db.executeValues("UPDATE entries SET state='deleted',path=NULL,path_key=NULL,head_revision=?,fs_hint=NULL WHERE vault_id=? AND id=?",
                                 bindings: [.blob(r.revision), .blob(vaultID), .blob(r.entry)])
        } else {
            try db.executeValues("UPDATE entries SET state='live',path=?,path_key=?,head_revision=?,fs_hint=? WHERE vault_id=? AND id=?",
                                 bindings: [.text(r.path), .text(VaultPath(r.path).portabilityKey), .blob(r.revision),
                                            try hint.map { .blob(try JSONEncoder().encode($0)) } ?? .null,
                                            .blob(vaultID), .blob(r.entry)])
        }
    }

    static func registerObject(db: SQLiteConnection, hash: String, size: Int64) throws {
        guard let digest = Data(hex: hash), digest.count == 32 else { throw ObjectStoreError.invalidHash }
        try db.executeValues("INSERT INTO objects(hash,length,durable_location,created_at) VALUES(?,?,?,?) ON CONFLICT(hash) DO NOTHING",
                             bindings: [.blob(digest), .integer(size), .text(hash), .text(ISO8601DateFormatter().string(from: Date()))])
        guard try db.queryValues("SELECT length FROM objects WHERE hash=?", bindings: [.blob(digest)]) == [[.integer(size)]] else {
            throw VaultRuntimeError.inconsistentCatalog
        }
    }

    /// Appends to the monotonic change feed consumed by peers.
    @discardableResult
    static func appendChange(db: SQLiteConnection, vaultID: Data, _ r: RevisionRecord, type: String) throws -> Int64 {
        let rows = try db.queryValues("UPDATE vaults SET next_seq=next_seq+1 WHERE id=? AND next_seq<9223372036854775807 RETURNING next_seq-1",
                                      bindings: [.blob(vaultID)])
        guard rows.count == 1, case .integer(let sequence) = rows[0][0] else { throw ExternalCaptureError.sequenceExhausted }
        let payload: [String: Any] = [
            "sequence": String(sequence), "entryId": uuid(r.entry), "revision": uuid(r.revision),
            "parents": r.parents.map(uuid), "type": type, "path": r.path, "kind": r.kind,
            "deleted": r.deleted, "contentHash": r.hash as Any? ?? NSNull(),
            "size": r.size.map { String($0) } as Any? ?? NSNull(), "operationId": NSNull()
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
        try db.executeValues("INSERT INTO changes(vault_id,seq,entry_id,revision_id,type,payload_json) VALUES(?,?,?,?,?,?)",
                             bindings: [.blob(vaultID), .integer(sequence), .blob(r.entry), .blob(r.revision), .text(type), .text(json)])
        return sequence
    }

    static func uuid(_ bytes: Data) -> String {
        UUID(uuid: bytes.withUnsafeBytes { $0.load(as: uuid_t.self) }).uuidString.lowercased()
    }

    static func revisions(db: SQLiteConnection, vaultID: Data, entry: Data) throws -> [Revision] {
        try db.queryValues("""
            SELECT r.revision_id,r.entry_id,r.parent1,r.parent2,r.path,r.deleted,lower(hex(r.content_hash)),r.byte_length,r.origin,r.created_at
            FROM revisions r LEFT JOIN changes c ON c.vault_id=r.vault_id AND c.revision_id=r.revision_id
            WHERE r.vault_id=? AND r.entry_id=? ORDER BY c.seq
            """, bindings: [.blob(vaultID), .blob(entry)]).map(Revision.init)
    }
}

/// A historical revision as returned by `history`.
public struct Revision: Sendable, Equatable {
    public let id: Data
    public let document: Data
    public let parents: [Data]
    public let path: String
    public let deleted: Bool
    public let hash: String?
    public let size: Int64?
    public let origin: String
    public let created: String

    init(_ row: [SQLiteValue]) throws {
        guard case .blob(let id) = row[0], case .blob(let document) = row[1], case .text(let path) = row[4],
              case .integer(let deleted) = row[5], case .text(let origin) = row[8], case .text(let created) = row[9] else {
            throw VaultRuntimeError.inconsistentCatalog
        }
        var parents: [Data] = []
        if case .blob(let p) = row[2] { parents.append(p) }
        if case .blob(let p) = row[3] { parents.append(p) }
        var hash: String?, size: Int64?
        if case .text(let h) = row[6] { hash = h }
        if case .integer(let s) = row[7] { size = s }
        self.id = id; self.document = document; self.parents = parents; self.path = path
        self.deleted = deleted != 0; self.hash = hash; self.size = size; self.origin = origin; self.created = created
    }
}

extension Data {
    public init?(hex: String) {
        guard hex.utf8.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.utf8.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}
