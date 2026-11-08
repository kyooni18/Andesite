import Foundation

public enum SnapshotError: Error, Equatable {
    case invalidPolicy
    case invalidTime
    case notFound
    case inconsistentMetadata
    case comparisonTooLarge
    case unsafeExport
    case restorationRequiresMutationJournal
}

public struct SnapshotPolicy: Sendable, Equatable {
    public let minimumInterval: TimeInterval
    public let retentionSeconds: TimeInterval
    public init(minimumInterval: TimeInterval = 300, retentionSeconds: TimeInterval = 7 * 86400) {
        self.minimumInterval = minimumInterval; self.retentionSeconds = retentionSeconds
    }
    func validate() throws {
        guard minimumInterval.isFinite, minimumInterval >= 0, minimumInterval <= 100 * 366 * 86400,
              retentionSeconds.isFinite, retentionSeconds >= 1, retentionSeconds <= 100 * 366 * 86400 else { throw SnapshotError.invalidPolicy }
    }
}

/// A complete immutable file, not a diff or a full-vault synchronization manifest.
/// Expiration is eligibility metadata only: this milestone never deletes snapshots.
public struct RecoverySnapshot: Sendable, Equatable {
    public let id: Data
    public let entryID: Data
    public let revisionID: Data
    public let contentHash: String
    public let byteLength: Int
    public let originalPath: String
    public let createdAt: Date
    public let expiresAt: Date
    public let reason: String
    public let documentState: String
    public let observedAt: String
    public func isExpired(at date: Date = Date()) -> Bool { date >= expiresAt }
}

public struct SnapshotObjectReferences: Sendable, Equatable {
    public let contentHash: String
    public let byteLength: Int64
    public let snapshots: Int64
    public let revisions: Int64
    public let incidents: Int64
}

public struct SnapshotStorageUsage: Sendable {
    public let policy: SnapshotPolicy
    public let snapshots: Int
    public let expirationEligible: Int
    public let pendingDocuments: Int
    public let logicalBytes: Int64
    public let uniqueSnapshotBytes: Int64
    public let registeredObjectBytes: Int64
    public internal(set) var immutableObjectLogicalBytes: Int64 = 0
    public internal(set) var physicalObjectAllocatedBytes: Int64 = 0
    public internal(set) var temporaryObjectAllocatedBytes: Int64 = 0
    public internal(set) var artifactAllocatedBytes: Int64 = 0
    public internal(set) var retirementEligibleAllocatedBytes: Int64 = 0
    public internal(set) var unresolvedArtifactAllocatedBytes: Int64 = 0
    public internal(set) var uncertainArtifacts: Int = 0
    public let objects: [SnapshotObjectReferences]
}

public struct SnapshotComparison: Sendable {
    public let before: RecoverySnapshot
    public let after: RecoverySnapshot
    /// Exact line insertions/removals with zero-based offsets, not a patch to apply.
    public let changes: [String]
}

/// Internal, synchronous scheduler/catalog adapter. The coordinator owns all
/// transactions. Pending work is derived from durable revision heads versus the
/// last snapshot, so capture -> scheduling interruptions need no volatile queue.
enum RecoverySnapshots {
    static func policy(db: SQLiteConnection, vaultID: Data) throws -> SnapshotPolicy {
        let rows = try db.queryValues("SELECT minimum_interval,retention_seconds FROM snapshot_policy WHERE vault_id=?", bindings: [.blob(vaultID)])
        guard let row = rows.first, row.count == 2, let interval = number(row[0]), let retention = number(row[1]) else { throw SnapshotError.inconsistentMetadata }
        let policy = SnapshotPolicy(minimumInterval: interval, retentionSeconds: retention)
        try policy.validate()
        return policy
    }

    static func configure(db: SQLiteConnection, vaultID: Data, policy: SnapshotPolicy) throws {
        try policy.validate()
        try db.executeValues("INSERT INTO snapshot_policy(vault_id,minimum_interval,retention_seconds) VALUES(?,?,?) ON CONFLICT(vault_id) DO UPDATE SET minimum_interval=excluded.minimum_interval,retention_seconds=excluded.retention_seconds", bindings: [.blob(vaultID), .real(policy.minimumInterval), .real(policy.retentionSeconds)])
    }

    static func validateTime(_ date: Date) throws {
        guard date.timeIntervalSince1970.isFinite, abs(date.timeIntervalSince1970) < 1e12 else { throw SnapshotError.invalidTime }
    }

    /// Objects must already be committed/durable and verified. No source reads or
    /// filesystem writes occur here. Force bypasses spacing, never content dedup.
    @discardableResult
    static func schedule(db: SQLiteConnection, vaultID: Data, entryID: Data, at date: Date,
                         reason: String = "interval", force: Bool = false) throws -> Bool {
        try validateTime(date)
        let heads = try db.queryValues("""
            SELECT r.revision_id,r.content_hash,r.byte_length,r.path,o.length
            FROM entries e JOIN revisions r ON r.vault_id=e.vault_id AND r.entry_id=e.id AND r.revision_id=e.head_revision
            LEFT JOIN objects o ON o.hash=r.content_hash
            WHERE e.vault_id=? AND e.id=? AND r.deleted=0 AND e.kind='markdown'
            """, bindings: [.blob(vaultID), .blob(entryID)])
        guard let head = heads.first else { return false }
        guard case .blob(let revision) = head[0], case .blob(let hash) = head[1],
              case .integer(let length) = head[2], case .text(let path) = head[3], head[4] == .integer(length) else { throw SnapshotError.inconsistentMetadata }
        let policy = try policy(db: db, vaultID: vaultID)
        let last = try db.queryValues("SELECT content_hash,created_at,ordinal FROM recovery_snapshots WHERE vault_id=? AND entry_id=? ORDER BY ordinal DESC LIMIT 1", bindings: [.blob(vaultID), .blob(entryID)]).first
        var ordinal: Int64 = 1
        if let last {
            guard let time = number(last[1]), case .integer(let previous) = last[2], previous < Int64.max else { throw SnapshotError.inconsistentMetadata }
            if last[0] == .blob(hash) { return false }
            if !force && date.timeIntervalSince1970 - time < policy.minimumInterval { return false }
            ordinal = previous + 1
        }
        // Retry must not allocate a second identity for an already registered revision.
        if !(try db.queryValues("SELECT 1 FROM recovery_snapshots WHERE vault_id=? AND entry_id=? AND revision_id=?", bindings: [.blob(vaultID), .blob(entryID), .blob(revision)])).isEmpty { return false }
        try db.executeValues("""
            INSERT INTO recovery_snapshots(vault_id,id,entry_id,revision_id,content_hash,byte_length,path,ordinal,created_at,expires_at,reason)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, bindings: [.blob(vaultID), .blob(ExternalCapture.identifier()), .blob(entryID), .blob(revision), .blob(hash), .integer(length), .text(path), .integer(ordinal), .real(date.timeIntervalSince1970), .real(date.timeIntervalSince1970 + policy.retentionSeconds), .text(reason)])
        return true
    }

    static func list(db: SQLiteConnection, vaultID: Data, entryID: Data? = nil, path: String? = nil,
                     snapshotID: Data? = nil) throws -> [RecoverySnapshot] {
        var predicates = ["s.vault_id=?"]
        var bindings: [SQLiteValue] = [.blob(vaultID)]
        if let entryID { predicates.append("s.entry_id=?"); bindings.append(.blob(entryID)) }
        if let snapshotID { predicates.append("s.id=?"); bindings.append(.blob(snapshotID)) }
        // Use the same portable key as observation, not SQLite's ASCII NOCASE
        // or byte equality (filesystems may enumerate decomposed Unicode). A
        // historical path can select several IDs; it never relinks their history.
        var historicalEntries: Set<Data>?
        if let path {
            let key = try VaultPath(path).portabilityKey
            var ids = Set<Data>()
            for row in try db.queryValues("SELECT DISTINCT entry_id,path FROM revisions WHERE vault_id=?", bindings: [.blob(vaultID)]) {
                guard case .blob(let id) = row[0], case .text(let name) = row[1] else { throw SnapshotError.inconsistentMetadata }
                if try VaultPath(name).portabilityKey == key { ids.insert(id) }
            }
            historicalEntries = ids
        }
        let rows = try db.queryValues("""
            SELECT s.id,s.entry_id,s.revision_id,lower(hex(s.content_hash)),s.byte_length,s.path,s.created_at,s.expires_at,s.reason,e.state,r.created_at
            FROM recovery_snapshots s JOIN entries e ON e.vault_id=s.vault_id AND e.id=s.entry_id
            JOIN revisions r ON r.vault_id=s.vault_id AND r.revision_id=s.revision_id
            WHERE \(predicates.joined(separator: " AND ")) ORDER BY s.entry_id,s.ordinal
            """, bindings: bindings)
        return try rows.compactMap { row in
            guard case .blob(let id) = row[0], case .blob(let entry) = row[1], case .blob(let revision) = row[2],
                  case .text(let hash) = row[3], case .integer(let length) = row[4], length >= 0, length <= Int.max,
                  case .text(let path) = row[5], let created = number(row[6]), let expires = number(row[7]),
                  case .text(let reason) = row[8], case .text(let state) = row[9], case .text(let observed) = row[10] else { throw SnapshotError.inconsistentMetadata }
            if let historicalEntries, !historicalEntries.contains(entry) { return nil }
            return RecoverySnapshot(id: id, entryID: entry, revisionID: revision, contentHash: hash, byteLength: Int(length), originalPath: path, createdAt: Date(timeIntervalSince1970: created), expiresAt: Date(timeIntervalSince1970: expires), reason: reason, documentState: state, observedAt: observed)
        }
    }

    static func pendingCount(db: SQLiteConnection, vaultID: Data) throws -> Int {
        let rows = try db.queryValues("""
            SELECT count(*) FROM entries e JOIN revisions r ON r.vault_id=e.vault_id AND r.revision_id=e.head_revision
            WHERE e.vault_id=? AND e.state='live' AND e.kind='markdown' AND NOT EXISTS (
              SELECT 1 FROM recovery_snapshots s WHERE s.vault_id=e.vault_id AND s.entry_id=e.id AND s.content_hash=r.content_hash
              AND s.ordinal=(SELECT max(t.ordinal) FROM recovery_snapshots t WHERE t.vault_id=e.vault_id AND t.entry_id=e.id))
            """, bindings: [.blob(vaultID)])
        guard case .integer(let count) = rows.first?.first else { throw SnapshotError.inconsistentMetadata }
        return Int(count)
    }

    static func usage(db: SQLiteConnection, vaultID: Data, at date: Date) throws -> SnapshotStorageUsage {
        try validateTime(date)
        let snapshots = try list(db: db, vaultID: vaultID)
        let rows = try db.queryValues("""
            SELECT lower(hex(o.hash)),o.length,
              (SELECT count(*) FROM recovery_snapshots s WHERE s.content_hash=o.hash),
              (SELECT count(*) FROM revisions r WHERE r.content_hash=o.hash),
              (SELECT count(*) FROM incidents i WHERE i.content_hash=o.hash)
            FROM objects o ORDER BY o.hash
            """)
        let objects: [SnapshotObjectReferences] = try rows.map { row in
            guard case .text(let hash) = row[0], case .integer(let length) = row[1], case .integer(let s) = row[2],
                  case .integer(let r) = row[3], case .integer(let i) = row[4] else { throw SnapshotError.inconsistentMetadata }
            return SnapshotObjectReferences(contentHash: hash, byteLength: length, snapshots: s, revisions: r, incidents: i)
        }
        return try SnapshotStorageUsage(policy: policy(db: db, vaultID: vaultID), snapshots: snapshots.count,
            expirationEligible: snapshots.filter { $0.isExpired(at: date) }.count,
            pendingDocuments: pendingCount(db: db, vaultID: vaultID), logicalBytes: snapshots.reduce(0) { $0 + Int64($1.byteLength) },
            uniqueSnapshotBytes: objects.filter { $0.snapshots > 0 }.reduce(0) { $0 + $1.byteLength },
            registeredObjectBytes: objects.reduce(0) { $0 + $1.byteLength }, objects: objects)
    }

    static func number(_ value: SQLiteValue) -> Double? {
        switch value { case .real(let number): return number.isFinite ? number : nil
        case .integer(let number): return Double(number)
        default: return nil }
    }
}
