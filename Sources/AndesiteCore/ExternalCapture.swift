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

/// A limited, explicit single-file capture, not a directory scanner or watcher.
/// The caller must hold the state-directory process lock, serialize all catalog
/// work for the vault, and call this on a bounded blocking executor. No vault
/// writes are performed. Unicode paths use NFC plus case folding for comparison.
public enum ExternalCapture {
    public static func capture(db: SQLiteConnection, reader: VaultReader, objects: ObjectStore,
                               vaultID: Data, path: VaultPath, maximumBytes: Int,
                               debounce: TimeInterval = 0.25) throws -> ExternalCaptureResult {
        guard vaultID.count == 16 else { throw ExternalCaptureError.unknownVault }
        let name = path.components.joined(separator: "/")
        let key = path.portabilityKey
        let kind = name.lowercased().hasSuffix(".md") ? "markdown" : "attachment"
        let observation = try reader.observeStable(path, maximumBytes: maximumBytes, debounce: debounce)
        let hash = try objects.put(observation.bytes)
        let hashBytes = Data(stride(from: 0, to: hash.count, by: 2).map { offset in
            let start = hash.index(hash.startIndex, offsetBy: offset)
            return UInt8(hash[start..<hash.index(start, offsetBy: 2)], radix: 16)!
        })
        let hint = try JSONEncoder().encode(observation.fingerprint)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        if kind == "markdown", String(data: observation.bytes, encoding: .utf8) == nil {
            try db.transaction {
                guard try db.queryValues("SELECT id FROM vaults WHERE id=?", bindings: [.blob(vaultID)]).count == 1 else { throw ExternalCaptureError.unknownVault }
                let rows = try db.queryValues("SELECT id,path FROM entries WHERE vault_id=? AND path_key=? AND state='live'", bindings: [.blob(vaultID), .text(key)])
                let entry: SQLiteValue
                if let row = rows.first {
                    guard row.count == 2, case .blob = row[0], case .text(let existingPath) = row[1] else { throw ExternalCaptureError.corruptCatalog }
                    guard existingPath == name else { throw ExternalCaptureError.pathCollision }
                    entry = row[0]
                } else { entry = .null }
                try registerObject(db: db, hash: hash, hashBytes: hashBytes, length: observation.bytes.count, timestamp: timestamp)
                let prior = try db.queryValues("SELECT id FROM incidents WHERE vault_id=? AND path_key=? AND content_hash=? AND status='open'", bindings: [.blob(vaultID), .text(key), .blob(hashBytes)])
                if prior.isEmpty {
                    try db.executeValues("INSERT INTO incidents(vault_id,id,path,path_key,entry_id,content_hash,fs_hint,status,observed_at) VALUES(?,?,?,?,?,?,?,'open',?)", bindings: [.blob(vaultID), .blob(identifier()), .text(name), .text(key), entry, .blob(hashBytes), .blob(hint), .text(timestamp)])
                }
            }
            throw ExternalCaptureError.invalidMarkdown
        }
        return try db.transaction {
            guard try db.queryValues("SELECT id FROM vaults WHERE id=?", bindings: [.blob(vaultID)]).count == 1 else {
                throw ExternalCaptureError.unknownVault
            }
            let existing = try db.queryValues("""
                SELECT e.id,e.path,e.kind,e.head_revision,r.content_hash
                FROM entries e LEFT JOIN revisions r ON r.vault_id=e.vault_id AND r.revision_id=e.head_revision
                WHERE e.vault_id=? AND e.path_key=? AND e.state='live'
                """, bindings: [.blob(vaultID), .text(key)])
            let entryID: Data, oldRevision: Data?
            if let row = existing.first {
                guard row.count == 5, case .blob(let id) = row[0], case .text(let existingPath) = row[1],
                      case .text(let existingKind) = row[2], case .blob(let head) = row[3], case .blob(let oldHash) = row[4] else {
                    throw ExternalCaptureError.corruptCatalog
                }
                guard existingPath == name, existingKind == kind else { throw ExternalCaptureError.pathCollision }
                entryID = id; oldRevision = head
                if oldHash == hashBytes {
                    try db.executeValues("UPDATE entries SET fs_hint=? WHERE vault_id=? AND id=?", bindings: [.blob(hint), .blob(vaultID), .blob(id)])
                    try db.executeValues("UPDATE incidents SET status='resolved' WHERE vault_id=? AND path_key=? AND status='open'", bindings: [.blob(vaultID), .text(key)])
                    return ExternalCaptureResult(entryID: id, revisionID: head, contentHash: hash, sequence: nil)
                }
            } else {
                entryID = identifier(); oldRevision = nil
                try db.executeValues("INSERT INTO entries(vault_id,id,kind,state) VALUES(?,?,?,'reserved')", bindings: [.blob(vaultID), .blob(entryID), .text(kind)])
            }
            let sequenceRows = try db.queryValues("UPDATE vaults SET next_seq=next_seq+1 WHERE id=? AND next_seq<9223372036854775807 RETURNING next_seq-1", bindings: [.blob(vaultID)])
            guard sequenceRows.count == 1, case .integer(let sequence) = sequenceRows[0][0] else { throw ExternalCaptureError.sequenceExhausted }
            try registerObject(db: db, hash: hash, hashBytes: hashBytes, length: observation.bytes.count, timestamp: timestamp)
            let revision = identifier()
            try db.executeValues("""
                INSERT INTO revisions(vault_id,entry_id,revision_id,parent1,content_hash,byte_length,path,deleted,origin,created_at,fs_hint)
                VALUES(?,?,?,?,?,?,?,0,'external',?,?)
                """, bindings: [.blob(vaultID), .blob(entryID), .blob(revision), oldRevision.map(SQLiteValue.blob) ?? .null,
                                .blob(hashBytes), .integer(Int64(observation.bytes.count)), .text(name), .text(timestamp), .blob(hint)])
            try db.executeValues("UPDATE entries SET path=?,path_key=?,head_revision=?,state='live',fs_hint=? WHERE vault_id=? AND id=?", bindings: [.text(name), .text(key), .blob(revision), .blob(hint), .blob(vaultID), .blob(entryID)])
            try db.executeValues("UPDATE incidents SET status='resolved' WHERE vault_id=? AND path_key=? AND status='open'", bindings: [.blob(vaultID), .text(key)])
            let type = oldRevision == nil ? "created" : "updated"
            let payload = try JSONSerialization.data(withJSONObject: ["sequence": String(sequence), "entryId": uuidString(entryID), "operationId": NSNull(), "type": type, "revision": uuidString(revision), "path": name, "kind": kind, "contentHash": hash, "size": String(observation.bytes.count)], options: [.sortedKeys])
            guard let json = String(data: payload, encoding: .utf8) else { throw ExternalCaptureError.corruptCatalog }
            try db.executeValues("INSERT INTO changes(vault_id,seq,entry_id,revision_id,type,payload_json) VALUES(?,?,?,?,?,?)", bindings: [.blob(vaultID), .integer(sequence), .blob(entryID), .blob(revision), .text(type), .text(json)])
            return ExternalCaptureResult(entryID: entryID, revisionID: revision, contentHash: hash, sequence: sequence)
        }
    }

    private static func registerObject(db: SQLiteConnection, hash: String, hashBytes: Data, length: Int, timestamp: String) throws {
        try db.executeValues("INSERT INTO objects(hash,length,durable_location,created_at) VALUES(?,?,?,?) ON CONFLICT(hash) DO NOTHING", bindings: [.blob(hashBytes), .integer(Int64(length)), .text(hash), .text(timestamp)])
        let rows = try db.queryValues("SELECT length,durable_location FROM objects WHERE hash=?", bindings: [.blob(hashBytes)])
        guard rows == [[.integer(Int64(length)), .text(hash)]] else { throw ExternalCaptureError.corruptCatalog }
    }

    private static func identifier() -> Data {
        var uuid = UUID().uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }
    private static func uuidString(_ bytes: Data) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [8, 4, 4, 4, 12]
        var index = hex.startIndex
        return parts.map { length in
            let end = hex.index(index, offsetBy: length)
            defer { index = end }
            return String(hex[index..<end])
        }.joined(separator: "-")
    }
}
