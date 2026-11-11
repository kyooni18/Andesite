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

    /// Describes a file already captured into `objects`. Markdown must be
    /// UTF-8 (`maximumMarkdownBytes` bounds the validation read).
    static func prepare(_ file: ScannedFile, hash: String, size: Int64, objects: ObjectStore,
                        maximumMarkdownBytes: Int) throws -> Prepared {
        var valid = true
        if file.kind == "markdown" {
            valid = String(data: try objects.get(hash, maximumBytes: maximumMarkdownBytes), encoding: .utf8) != nil
        }
        return try Prepared(path: file.path, hash: hash, hashBytes: Data(hex: hash)!, length: Int(size),
                            hint: JSONEncoder().encode(file.fingerprint), valid: valid)
    }

    public static func capture(db: SQLiteConnection, reader: VaultReader, objects: ObjectStore,
                               vaultID: Data, path: VaultPath, maximumBytes: Int,
                               debounce: TimeInterval = 0.25) throws -> ExternalCaptureResult {
        guard vaultID.count == 16 else { throw ExternalCaptureError.unknownVault }
        let file = ScannedFile(path: path, fingerprint: try reader.fingerprint(path))
        Thread.sleep(forTimeInterval: debounce)
        let (hash, size) = try reader.capture(path, expected: file.fingerprint, into: objects, maximumBytes: maximumBytes)
        let prepared = try prepare(file, hash: hash, size: size, objects: objects, maximumMarkdownBytes: maximumBytes)
        let result = try db.transaction { try publish(db: db, vaultID: vaultID, prepared: prepared, at: Date()) }
        guard let result else { throw ExternalCaptureError.invalidMarkdown }
        return result
    }

    /// Caller owns the transaction. Explicit entryID is only supplied by the
    /// validated namespace planner, never inferred from a content hash.
    static func publish(db: SQLiteConnection, vaultID: Data, prepared p: Prepared,
                        entryID requestedID: Data? = nil, at date: Date) throws -> ExternalCaptureResult? {
        let current: CatalogEntry?
        if let requestedID {
            current = try Catalog.entry(db: db, vaultID: vaultID, id: requestedID)
            guard current != nil else { throw ExternalCaptureError.corruptCatalog }
        } else {
            current = try Catalog.live(db: db, vaultID: vaultID, path: p.name)
                ?? (p.name == SyncedVaultSettings.path
                    ? Catalog.entry(db: db, vaultID: vaultID, id: SyncedVaultSettings.entryID) : nil)
            if let path = current?.path, Array(path.utf8) != Array(p.name.utf8) { throw ExternalCaptureError.pathCollision }
        }
        if let current, current.kind != p.kind { throw ExternalCaptureError.corruptCatalog }
        try Catalog.registerObject(db: db, hash: p.hash, size: Int64(p.length))
        let live = current?.state == "live" ? current : nil
        if !p.valid {
            try incident(db: db, vaultID: vaultID, prepared: p, entryID: live?.id, at: date)
            return nil
        }
        let entryID = current?.id ?? (p.name == SyncedVaultSettings.path ? SyncedVaultSettings.entryID : identifier())
        if let live, let head = live.head, live.hash == p.hash, Array((live.path ?? "").utf8) == Array(p.name.utf8) {
            try db.executeValues("UPDATE entries SET fs_hint=? WHERE vault_id=? AND id=?", bindings: [.blob(p.hint), .blob(vaultID), .blob(entryID)])
            try resolveIncidents(db: db, vaultID: vaultID, key: p.path.portabilityKey, entryID: entryID)
            return ExternalCaptureResult(entryID: entryID, revisionID: head, contentHash: p.hash, sequence: nil)
        }
        let record = RevisionRecord(entry: entryID, revision: identifier(), parents: current?.head.map { [$0] } ?? [],
                                    path: p.name, deleted: false, hash: p.hash, size: Int64(p.length),
                                    kind: p.kind, origin: "external")
        try Catalog.setHead(db: db, vaultID: vaultID, record, hint: try JSONDecoder().decode(FileFingerprint.self, from: p.hint))
        try resolveIncidents(db: db, vaultID: vaultID, key: p.path.portabilityKey, entryID: entryID)
        let sequence = try db.queryValues("SELECT seq FROM changes WHERE vault_id=? AND revision_id=?",
                                          bindings: [.blob(vaultID), .blob(record.revision)])
        guard case .integer(let seq) = sequence.first?.first else { throw ExternalCaptureError.corruptCatalog }
        return ExternalCaptureResult(entryID: entryID, revisionID: record.revision, contentHash: p.hash, sequence: seq)
    }

    static func tombstone(db: SQLiteConnection, vaultID: Data, entryID: Data, at date: Date) throws {
        guard let current = try Catalog.entry(db: db, vaultID: vaultID, id: entryID), current.state == "live",
              let path = current.path, let head = current.head else { throw ExternalCaptureError.corruptCatalog }
        // Incident bytes remain retained. A disappearance is not a correction.
        try Catalog.setHead(db: db, vaultID: vaultID, RevisionRecord(
            entry: entryID, revision: identifier(), parents: [head], path: path, deleted: true,
            hash: nil, size: nil, kind: current.kind, origin: "external"), hint: nil)
    }

    static func incident(db: SQLiteConnection, vaultID: Data, prepared p: Prepared, entryID: Data?, at date: Date) throws {
        let timestamp = ISO8601DateFormatter().string(from: date)
        try Catalog.registerObject(db: db, hash: p.hash, size: Int64(p.length))
        let prior = try db.queryValues("SELECT id FROM incidents WHERE vault_id=? AND path_key=? AND content_hash=? AND status='open'", bindings: [.blob(vaultID), .text(p.path.portabilityKey), .blob(p.hashBytes)])
        if prior.isEmpty {
            try db.executeValues("INSERT INTO incidents(vault_id,id,path,path_key,entry_id,content_hash,fs_hint,status,observed_at) VALUES(?,?,?,?,?,?,?,'open',?)", bindings: [.blob(vaultID), .blob(identifier()), .text(p.name), .text(p.path.portabilityKey), entryID.map(SQLiteValue.blob) ?? .null, .blob(p.hashBytes), .blob(p.hint), .text(timestamp)])
        }
    }

    private static func resolveIncidents(db: SQLiteConnection, vaultID: Data, key: String, entryID: Data) throws {
        try db.executeValues("UPDATE incidents SET status='resolved' WHERE vault_id=? AND (entry_id=? OR (entry_id IS NULL AND path_key=?)) AND status='open'", bindings: [.blob(vaultID), .blob(entryID), .text(key)])
    }

    static func identifier() -> Data {
        var value = UUID().uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
