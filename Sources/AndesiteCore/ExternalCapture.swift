import Foundation

public enum ExternalCaptureError: Error, Equatable {
    case unsupportedPath
    case pathCollision
    case invalidMarkdown
    case unknownVault
    case corruptCatalog
    case sequenceExhausted
}

public struct ExternalCaptureResult: Sendable, Equatable {
    public let entryID: Data
    public let revisionID: Data
    public let contentHash: String
    public let sequence: Int64?
}

/// Durable immutable capture and catalog publication are intentionally separate
/// from snapshot scheduling. All calls require exclusive ownership/serialization.
public enum ExternalCapture {
    struct Prepared {
        let path: VaultPath
        let hash: String
        let hashBytes: Data
        let length: Int
        let hint: Data
        let valid: Bool
        var name: String { path.components.joined(separator: "/") }
        var kind: String { name.lowercased().hasSuffix(".md") ? "markdown" : "attachment" }
    }

    static func prepare(path: VaultPath, observation: ObservedFile, objects: ObjectStore) throws -> Prepared {
        let hash = try objects.put(observation.bytes)
        let hashBytes = Data(stride(from: 0, to: 64, by: 2).map { offset in
            let start = hash.index(hash.startIndex, offsetBy: offset)
            return UInt8(hash[start..<hash.index(start, offsetBy: 2)], radix: 16)!
        })
        return try Prepared(path: path, hash: hash, hashBytes: hashBytes, length: observation.bytes.count,
                            hint: JSONEncoder().encode(observation.fingerprint),
                            valid: !path.components.last!.lowercased().hasSuffix(".md") || String(data: observation.bytes, encoding: .utf8) != nil)
    }

    public static func capture(db: SQLiteConnection, reader: VaultReader, objects: ObjectStore,
                               vaultID: Data, path: VaultPath, maximumBytes: Int,
                               debounce: TimeInterval = 0.25) throws -> ExternalCaptureResult {
        let observation = try reader.observeStable(path, maximumBytes: maximumBytes, debounce: debounce)
        let prepared = try prepare(path: path, observation: observation, objects: objects)
        let result = try db.transaction { try publish(db: db, vaultID: vaultID, prepared: prepared, at: Date()) }
        guard let result else { throw ExternalCaptureError.invalidMarkdown }
        return result
    }

    /// Caller owns the transaction. Explicit entryID is only supplied by the
    /// validated namespace planner, never inferred from a content hash.
    static func publish(db: SQLiteConnection, vaultID: Data, prepared p: Prepared,
                        entryID requestedID: Data? = nil, at date: Date) throws -> ExternalCaptureResult? {
        guard vaultID.count == 16, try db.queryValues("SELECT id FROM vaults WHERE id=?", bindings: [.blob(vaultID)]).count == 1 else { throw ExternalCaptureError.unknownVault }
        let timestamp = ISO8601DateFormatter().string(from: date)
        let predicate = requestedID == nil ? "e.path_key=? AND e.state='live'" : "e.id=? AND e.state IN ('live','reserved')"
        let rows = try db.queryValues("""
            SELECT e.id,r.path,e.kind,e.head_revision,r.content_hash
            FROM entries e LEFT JOIN revisions r ON r.vault_id=e.vault_id AND r.revision_id=e.head_revision
            WHERE e.vault_id=? AND \(predicate)
            """, bindings: [.blob(vaultID), requestedID.map(SQLiteValue.blob) ?? .text(p.path.portabilityKey)])
        let entryID: Data, oldRevision: Data?, oldPath: String?, oldHash: Data?
        if let row = rows.first {
            guard case .blob(let id) = row[0], case .text(let path) = row[1], row[2] == .text(p.kind),
                  case .blob(let head) = row[3], case .blob(let hash) = row[4] else { throw ExternalCaptureError.corruptCatalog }
            if requestedID == nil && Array(path.utf8) != Array(p.name.utf8) { throw ExternalCaptureError.pathCollision }
            entryID = id; oldRevision = head; oldPath = path; oldHash = hash
        } else {
            guard requestedID == nil else { throw ExternalCaptureError.corruptCatalog }
            entryID = identifier(); oldRevision = nil; oldPath = nil; oldHash = nil
        }
        try registerObject(db: db, prepared: p, timestamp: timestamp)
        if !p.valid {
            try incident(db: db, vaultID: vaultID, prepared: p, entryID: oldRevision == nil ? nil : entryID, at: date)
            return nil
        }
        let moved = oldPath.map { Array($0.utf8) != Array(p.name.utf8) } ?? false
        if oldHash == p.hashBytes && !moved, let head = oldRevision {
            try db.executeValues("UPDATE entries SET fs_hint=? WHERE vault_id=? AND id=?", bindings: [.blob(p.hint), .blob(vaultID), .blob(entryID)])
            try resolveIncidents(db: db, vaultID: vaultID, key: p.path.portabilityKey)
            return ExternalCaptureResult(entryID: entryID, revisionID: head, contentHash: p.hash, sequence: nil)
        }
        if oldRevision == nil {
            try db.executeValues("INSERT INTO entries(vault_id,id,kind,state) VALUES(?,?,?,'reserved')", bindings: [.blob(vaultID), .blob(entryID), .text(p.kind)])
        }
        let revision = identifier()
        try db.executeValues("""
            INSERT INTO revisions(vault_id,entry_id,revision_id,parent1,content_hash,byte_length,path,deleted,origin,created_at,fs_hint)
            VALUES(?,?,?,?,?,?,?,0,'external',?,?)
            """, bindings: [.blob(vaultID), .blob(entryID), .blob(revision), oldRevision.map(SQLiteValue.blob) ?? .null,
                            .blob(p.hashBytes), .integer(Int64(p.length)), .text(p.name), .text(timestamp), .blob(p.hint)])
        try db.executeValues("UPDATE entries SET path=?,path_key=?,head_revision=?,state='live',fs_hint=? WHERE vault_id=? AND id=?", bindings: [.text(p.name), .text(p.path.portabilityKey), .blob(revision), .blob(p.hint), .blob(vaultID), .blob(entryID)])
        try resolveIncidents(db: db, vaultID: vaultID, key: p.path.portabilityKey)
        let type = moved ? "moved" : (oldRevision == nil ? "created" : "updated")
        let sequence = try event(db: db, vaultID: vaultID, entryID: entryID, revision: revision, type: type,
                                 path: p.name, kind: p.kind, hash: p.hash, length: p.length, fromPath: moved ? oldPath : nil)
        return ExternalCaptureResult(entryID: entryID, revisionID: revision, contentHash: p.hash, sequence: sequence)
    }

    static func tombstone(db: SQLiteConnection, vaultID: Data, entryID: Data, at date: Date) throws {
        let rows = try db.queryValues("SELECT path,kind,head_revision FROM entries WHERE vault_id=? AND id=? AND state='live'", bindings: [.blob(vaultID), .blob(entryID)])
        guard let row = rows.first, case .text(let path) = row[0], case .text(let kind) = row[1], case .blob(let parent) = row[2] else { throw ExternalCaptureError.corruptCatalog }
        let revision = identifier()
        try db.executeValues("INSERT INTO revisions(vault_id,entry_id,revision_id,parent1,path,deleted,origin,created_at) VALUES(?,?,?,?,?,1,'external',?)", bindings: [.blob(vaultID), .blob(entryID), .blob(revision), .blob(parent), .text(path), .text(ISO8601DateFormatter().string(from: date))])
        try db.executeValues("UPDATE entries SET path=NULL,path_key=NULL,head_revision=?,state='deleted',fs_hint=NULL WHERE vault_id=? AND id=?", bindings: [.blob(revision), .blob(vaultID), .blob(entryID)])
        _ = try event(db: db, vaultID: vaultID, entryID: entryID, revision: revision, type: "deleted", path: path, kind: kind, hash: nil, length: nil)
        // Incident bytes remain retained. A disappearance is not a correction.
    }

    static func incident(db: SQLiteConnection, vaultID: Data, prepared p: Prepared, entryID: Data?, at date: Date) throws {
        let timestamp = ISO8601DateFormatter().string(from: date)
        try registerObject(db: db, prepared: p, timestamp: timestamp)
        let prior = try db.queryValues("SELECT id FROM incidents WHERE vault_id=? AND path_key=? AND content_hash=? AND status='open'", bindings: [.blob(vaultID), .text(p.path.portabilityKey), .blob(p.hashBytes)])
        if prior.isEmpty {
            try db.executeValues("INSERT INTO incidents(vault_id,id,path,path_key,entry_id,content_hash,fs_hint,status,observed_at) VALUES(?,?,?,?,?,?,?,'open',?)", bindings: [.blob(vaultID), .blob(identifier()), .text(p.name), .text(p.path.portabilityKey), entryID.map(SQLiteValue.blob) ?? .null, .blob(p.hashBytes), .blob(p.hint), .text(timestamp)])
        }
    }

    private static func registerObject(db: SQLiteConnection, prepared p: Prepared, timestamp: String) throws {
        try db.executeValues("INSERT INTO objects(hash,length,durable_location,created_at) VALUES(?,?,?,?) ON CONFLICT(hash) DO NOTHING", bindings: [.blob(p.hashBytes), .integer(Int64(p.length)), .text(p.hash), .text(timestamp)])
        guard try db.queryValues("SELECT length,durable_location FROM objects WHERE hash=?", bindings: [.blob(p.hashBytes)]) == [[.integer(Int64(p.length)), .text(p.hash)]] else { throw ExternalCaptureError.corruptCatalog }
    }

    private static func resolveIncidents(db: SQLiteConnection, vaultID: Data, key: String) throws {
        try db.executeValues("UPDATE incidents SET status='resolved' WHERE vault_id=? AND path_key=? AND status='open'", bindings: [.blob(vaultID), .text(key)])
    }

    private static func event(db: SQLiteConnection, vaultID: Data, entryID: Data, revision: Data, type: String,
                              path: String, kind: String, hash: String?, length: Int?, fromPath: String? = nil) throws -> Int64 {
        let rows = try db.queryValues("UPDATE vaults SET next_seq=next_seq+1 WHERE id=? AND next_seq<9223372036854775807 RETURNING next_seq-1", bindings: [.blob(vaultID)])
        guard rows.count == 1, case .integer(let sequence) = rows[0][0] else { throw ExternalCaptureError.sequenceExhausted }
        var fields: [String: Any] = ["sequence": String(sequence), "entryId": uuidString(entryID), "operationId": NSNull(), "type": type, "revision": uuidString(revision), "path": path, "kind": kind, "contentHash": hash as Any? ?? NSNull(), "size": length.map(String.init) as Any? ?? NSNull()]
        if let fromPath { fields["fromPath"] = fromPath }
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else { throw ExternalCaptureError.corruptCatalog }
        try db.executeValues("INSERT INTO changes(vault_id,seq,entry_id,revision_id,type,payload_json) VALUES(?,?,?,?,?,?)", bindings: [.blob(vaultID), .integer(sequence), .blob(entryID), .blob(revision), .text(type), .text(json)])
        return sequence
    }

    static func identifier() -> Data {
        var value = UUID().uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    private static func uuidString(_ bytes: Data) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        var index = hex.startIndex
        return [8, 4, 4, 4, 12].map { length in
            let end = hex.index(index, offsetBy: length)
            defer { index = end }
            return String(hex[index..<end])
        }.joined(separator: "-")
    }
}
