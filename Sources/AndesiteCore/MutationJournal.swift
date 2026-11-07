import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct MutationOperation: Sendable {
    public let id: Data
    public let entryID: Data
    public let snapshotID: Data
    public let preimageID: Data
    public let revisionID: Data
    public let path: String
    public let artifact: String
    public let state: String
    public let diagnostic: String
}

/// A small redo/observe journal, not a filesystem/SQLite distributed transaction.
/// Durable preimage -> prepared -> staged -> published -> catalogued -> completed.
/// Never-published work is cancelled on restart; ambiguity is quarantined, never
/// rolled back over a possibly newer edit. Atomic exchange retains the displaced
/// inode indefinitely; no recovery path unlinks or rewrites that evidence.
final class MutationJournal {
    struct Record {
        let operation: MutationOperation
        let parent: Data
        let original: FileFingerprint
        let stage: FileFingerprint?
        let directories: [DirectoryIdentity]
        let created: Date
    }
    let db: SQLiteConnection
    let objects: ObjectStore
    let vaultID: Data
    let root: String
    let maximumBytes: Int
    var fault: (String) throws -> Void = { point in
        // Deliberately opt-in, deterministic process-death harness. Never reads
        // fault controls from vault files. Production has neither variable set.
        if ProcessInfo.processInfo.environment["ANDESITE_TEST_FAULTS"] == "1",
           ProcessInfo.processInfo.environment["ANDESITE_TEST_KILL_POINT"] == point {
            kill(getpid(), SIGKILL)
        }
    }
    init(db: SQLiteConnection, objects: ObjectStore, vaultID: Data, root: String, maximumBytes: Int) {
        self.db = db; self.objects = objects; self.vaultID = vaultID; self.root = root; self.maximumBytes = maximumBytes
    }
    func records() throws -> [Record] {
        try db.queryValues("""
            SELECT id,entry_id,snapshot_id,preimage_id,revision_id,path,artifact,state,diagnostic,
                   parent_revision,original_hint,stage_hint,directories,created_at
            FROM mutation_journal WHERE vault_id=? ORDER BY created_at,id
            """, bindings: [.blob(vaultID)]).map { row in
            guard case .blob(let id) = row[0], case .blob(let entry) = row[1], case .blob(let snapshot) = row[2],
                  case .blob(let preimage) = row[3], case .blob(let revision) = row[4], case .text(let path) = row[5],
                  case .text(let artifact) = row[6], case .text(let state) = row[7], case .text(let diagnostic) = row[8],
                  case .blob(let parent) = row[9], case .blob(let original) = row[10], case .blob(let dirs) = row[12],
                  let time = RecoverySnapshots.number(row[13]) else { throw VaultRuntimeError.inconsistentCatalog }
            let stage: FileFingerprint?
            if case .blob(let bytes) = row[11] { stage = try JSONDecoder().decode(FileFingerprint.self, from: bytes) }
            else { guard row[11] == .null else { throw VaultRuntimeError.inconsistentCatalog }; stage = nil }
            _ = try VaultPath(path)
            guard artifact == ".andesite-mutation-" + Self.hex(id), id.count == 16 else { throw VaultRuntimeError.inconsistentCatalog }
            return try Record(operation: MutationOperation(id: id, entryID: entry, snapshotID: snapshot, preimageID: preimage,
                revisionID: revision, path: path, artifact: artifact, state: state, diagnostic: diagnostic), parent: parent,
                original: JSONDecoder().decode(FileFingerprint.self, from: original), stage: stage,
                directories: JSONDecoder().decode([DirectoryIdentity].self, from: dirs), created: Date(timeIntervalSince1970: time))
        }
    }
    static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    func assertResolved() throws {
        guard try records().allSatisfy({ ["completed", "cancelled"].contains($0.operation.state) }) else { throw MutationError.unfinished }
    }
    func snapshot(_ id: Data) throws -> (RecoverySnapshot, Data) {
        guard let s = try RecoverySnapshots.list(db: db, vaultID: vaultID, snapshotID: id).first else { throw SnapshotError.notFound }
        let bytes = try objects.get(s.contentHash, maximumBytes: maximumBytes)
        guard bytes.count == s.byteLength else { throw SnapshotError.inconsistentMetadata }
        return (s, bytes)
    }
    /// Always registers this exact revision even if spacing/hash coalescing would
    /// suppress an ordinary scheduled snapshot. A retry reuses its existing ID.
    func preserveHead(entryID: Data, at date: Date) throws -> Data {
        let bindings: [SQLiteValue] = [.blob(vaultID), .blob(entryID)]
        guard let row = try db.queryValues("""
            SELECT r.revision_id,r.content_hash,r.byte_length,r.path FROM entries e JOIN revisions r
            ON r.vault_id=e.vault_id AND r.revision_id=e.head_revision
            WHERE e.vault_id=? AND e.id=? AND e.state='live' AND r.deleted=0
            """, bindings: bindings).first,
              case .blob(let revision) = row[0], case .blob(let hash) = row[1], case .integer(let length) = row[2], case .text(let path) = row[3] else { throw VaultRuntimeError.inconsistentCatalog }
        if let existing = try db.queryValues("SELECT id FROM recovery_snapshots WHERE vault_id=? AND entry_id=? AND revision_id=?", bindings: bindings + [.blob(revision)]).first,
           case .blob(let id) = existing[0] { return id }
        let rows = try db.queryValues("SELECT coalesce(max(ordinal),0) FROM recovery_snapshots WHERE vault_id=? AND entry_id=?", bindings: bindings)
        guard case .integer(let last) = rows[0][0], last < Int64.max else { throw SnapshotError.inconsistentMetadata }
        let id = ExternalCapture.identifier()
        let policy = try RecoverySnapshots.policy(db: db, vaultID: vaultID)
        try db.executeValues("""
            INSERT INTO recovery_snapshots(vault_id,id,entry_id,revision_id,content_hash,byte_length,path,ordinal,created_at,expires_at,reason)
            VALUES(?,?,?,?,?,?,?,?,?,?,'recovery')
            """, bindings: [.blob(vaultID), .blob(id), .blob(entryID), .blob(revision), .blob(hash), .integer(length), .text(path), .integer(last + 1), .real(date.timeIntervalSince1970), .real(date.timeIntervalSince1970 + policy.retentionSeconds)])
        return id
    }
    func setState(_ record: Record, _ state: String, _ diagnostic: String = "") throws {
        try db.executeValues("UPDATE mutation_journal SET state=?,diagnostic=? WHERE vault_id=? AND id=?", bindings: [.text(state), .text(diagnostic), .blob(vaultID), .blob(record.operation.id)])
    }
    func reload(_ id: Data) throws -> Record {
        guard let r = try records().first(where: { $0.operation.id == id }) else { throw VaultRuntimeError.inconsistentCatalog }
        return r
    }
    func filesystem(path: String, expected: [DirectoryIdentity]? = nil) throws -> MutationFilesystem {
        let fs = try MutationFilesystem(root: root, path: VaultPath(path), expected: expected)
        let rootIndex = root.split(separator: "/").count - 1
        let identity = fs.identities[rootIndex]
        guard try db.queryValues("SELECT root_config FROM vaults WHERE id=?", bindings: [.blob(vaultID)]) == [[.text("\(root)\n\(identity.device):\(identity.inode)")]] else { throw MutationError.conflict("vault root no longer matches the catalog") }
        return fs
    }
    func restore(_ id: Data) throws -> MutationOperation {
        #if !canImport(Darwin)
        throw MutationError.unsupportedPlatform
        #else
        try assertResolved()
        let (snapshot, replacement) = try snapshot(id)
        let rows = try db.queryValues("""
            SELECT e.path,e.head_revision,e.fs_hint,r.content_hash FROM entries e JOIN revisions r
            ON r.vault_id=e.vault_id AND r.revision_id=e.head_revision
            WHERE e.vault_id=? AND e.id=? AND e.state='live' AND e.kind='markdown'
            """, bindings: [.blob(vaultID), .blob(snapshot.entryID)])
        guard let row = rows.first, case .text(let path) = row[0], case .blob(let parent) = row[1],
              case .blob(let hint) = row[2], case .blob(let hash) = row[3] else { throw MutationError.conflict("snapshot document is not a live Markdown file; export instead") }
        let fs = try filesystem(path: path)
        let observation = try fs.observe(fs.name, maximumBytes: maximumBytes)
        let original = try JSONDecoder().decode(FileFingerprint.self, from: hint)
        guard observation.fingerprint == original, ObjectStore.hash(observation.bytes) == Self.hex(hash) else { throw MutationError.conflict("target changed since its last captured revision; reconcile and review before retrying") }
        // Ensure both sides are durably immutable before registering any intent.
        _ = try objects.put(observation.bytes)
        let now = Date()
        try fault("before-preimage")
        let preimage = try db.transaction {
            let id = try preserveHead(entryID: snapshot.entryID, at: now)
            try fault("preimage-written")
            return id
        }
        try fault("preimage-preserved")
        let operationID = ExternalCapture.identifier(), revision = ExternalCapture.identifier()
        let artifact = ".andesite-mutation-" + Self.hex(operationID)
        try db.transaction {
            try db.executeValues("""
                INSERT INTO mutation_journal(vault_id,id,entry_id,snapshot_id,preimage_id,parent_revision,revision_id,path,artifact,original_hint,directories,state,created_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,'prepared',?)
                """, bindings: [.blob(vaultID), .blob(operationID), .blob(snapshot.entryID), .blob(id), .blob(preimage), .blob(parent), .blob(revision), .text(path), .text(artifact), .blob(hint), .blob(try JSONEncoder().encode(fs.identities)), .real(now.timeIntervalSince1970)])
            try fault("intent-written")
        }
        try fault("intent-committed")
        let staged = try fs.stage(replacement, artifact: artifact, original: original, fault: fault)
        try db.transaction {
            try db.executeValues("UPDATE mutation_journal SET stage_hint=?,state='staged' WHERE vault_id=? AND id=?", bindings: [.blob(try JSONEncoder().encode(staged)), .blob(vaultID), .blob(operationID)])
        }
        try fault("staged")
        let record = try reload(operationID)
        // Obtain the SQLite writer reservation BEFORE touching the target. It
        // does not make the exchange atomic with COMMIT; recovery observes both.
        try db.transaction {
            try fs.verifyChain()
            let current = try fs.observe(fs.name, maximumBytes: maximumBytes)
            guard current.fingerprint == original, current.bytes == observation.bytes,
                  try fs.observe(artifact, maximumBytes: maximumBytes).fingerprint == staged else { throw MutationError.conflict("external edit before publication") }
            try fault("before-exchange")
            // Revalidate after a deterministic test hook as well.
            guard try fs.observe(fs.name, maximumBytes: maximumBytes).fingerprint == original else { throw MutationError.conflict("external edit at publication boundary") }
            try fs.exchange(artifact: artifact)
            try fault("exchanged")
            try fs.syncPublished()
            try fs.verifyChain()
            try verifyPublished(record, fs: fs)
            try setState(record, "published")
        }
        try fault("published")
        try publishCatalog(try reload(operationID), fs: fs)
        try fault("catalogued")
        try complete(try reload(operationID), fs: fs)
        return try reload(operationID).operation
        #endif
    }
    func verifyPublished(_ record: Record, fs: MutationFilesystem) throws {
        let (source, wanted) = try snapshot(record.operation.snapshotID)
        let (before, preimage) = try snapshot(record.operation.preimageID)
        guard source.entryID == record.operation.entryID, before.entryID == record.operation.entryID,
              before.revisionID == record.parent else { throw MutationError.conflict("journal snapshot identity or preimage lineage mismatch") }
        guard let stage = record.stage else { throw MutationError.conflict("missing durable stage identity") }
        let target = try fs.observe(fs.name, maximumBytes: maximumBytes)
        let displaced = try fs.observe(record.operation.artifact, maximumBytes: maximumBytes)
        guard target.fingerprint.sameInode(as: stage), target.bytes == wanted,
              displaced.fingerprint.sameInode(as: record.original), displaced.bytes == preimage else { throw MutationError.conflict("published target or retained preimage changed; evidence retained without rollback") }
        try fs.verifyChain()
    }
    func publishCatalog(_ record: Record, fs: MutationFilesystem) throws {
        try verifyPublished(record, fs: fs)
        let observed = try fs.observe(fs.name, maximumBytes: maximumBytes)
        guard observed.fingerprint.sameInode(as: record.stage!), observed.bytes == (try snapshot(record.operation.snapshotID).1) else { throw MutationError.conflict("target changed before catalog publication") }
        let p = try ExternalCapture.prepare(path: VaultPath(record.operation.path), observation: observed, objects: objects)
        try fault("before-catalog")
        try db.transaction {
            guard try db.queryValues("SELECT head_revision FROM entries WHERE vault_id=? AND id=? AND state='live'", bindings: [.blob(vaultID), .blob(record.operation.entryID)]) == [[.blob(record.parent)]] else { throw MutationError.conflict("catalog head no longer matches the journal parent") }
            guard let captured = try ExternalCapture.publish(db: db, vaultID: vaultID, prepared: p, entryID: record.operation.entryID, at: record.created, restoringRevision: record.operation.revisionID) else { throw SnapshotError.inconsistentMetadata }
            try SearchIndex.index(db: db, vaultID: vaultID, entryID: captured.entryID, revisionID: captured.revisionID, bytes: snapshot(record.operation.snapshotID).1, withinTransaction: true)
            _ = try preserveHead(entryID: captured.entryID, at: record.created)
            try fault("catalog-written")
            try setState(record, "catalogued")
        }
    }
    func complete(_ record: Record, fs: MutationFilesystem) throws {
        try verifyPublished(record, fs: fs)
        try fs.syncPublished()
        try fault("before-completion")
        try db.transaction { try setState(record, "completed") }
        try fault("completed")
    }
    /// Runs before reconciliation and on subsequent attempts after a local error.
    /// No restart ever retries an unpublished exchange. Already-visible exchange
    /// is redone only in the catalog with its preallocated revision ID.
    func recover() throws {
        for record in try records() {
            if record.operation.state == "quarantined" { continue }
            do {
                let fs = try filesystem(path: record.operation.path, expected: record.directories)
                switch record.operation.state {
                case "completed":
                    // Keep watching displaced inodes: an editor with an open FD
                    // can write there even after an otherwise successful restore.
                    let (_, bytes) = try snapshot(record.operation.preimageID)
                    let displaced = try fs.observe(record.operation.artifact, maximumBytes: maximumBytes)
                    guard displaced.fingerprint.sameInode(as: record.original), displaced.bytes == bytes else { throw MutationError.conflict("retained displaced inode changed after completion") }
                case "cancelled": break
                case "prepared":
                    if try fs.info(record.operation.artifact) != nil { throw MutationError.conflict("interrupted staging; unverified artifact retained") }
                    try db.transaction { try setState(record, "cancelled", "Intent was never staged; source not modified by recovery") }
                case "staged", "published":
                    guard let stage = record.stage else { throw MutationError.conflict("missing staged identity") }
                    let target = try fs.observe(fs.name, maximumBytes: maximumBytes)
                    let artifact = try fs.observe(record.operation.artifact, maximumBytes: maximumBytes)
                    if record.operation.state == "staged", target.fingerprint == record.original,
                       artifact.fingerprint == stage, artifact.bytes == (try snapshot(record.operation.snapshotID).1) {
                        try db.transaction { try setState(record, "cancelled", "Staged but not published; source not modified by recovery") }
                    } else {
                        try verifyPublished(record, fs: fs)
                        try fs.syncPublished()
                        try db.transaction { try setState(record, "published") }
                        try publishCatalog(record, fs: fs)
                        try complete(try reload(record.operation.id), fs: fs)
                    }
                case "catalogued": try complete(record, fs: fs)
                default: throw VaultRuntimeError.inconsistentCatalog
                }
            } catch let error as SQLiteFailure { throw error } // A busy/failed DB is not an FS conflict.
            catch {
                // Diagnostics are fixed descriptions, never file contents.
                try db.transaction { try setState(record, "quarantined", "Filesystem/object/identity verification failed; retained artifact and immutable preimage require manual review") }
            }
        }
    }
    /// Exclusions are exact paths plus inode identity, not a blanket hidden-file
    /// filter. Unknown .andesite names still abort ordinary read-only scans.
    func scanArtifacts() throws -> [String: FileFingerprint] {
        try assertResolved()
        var result: [String: FileFingerprint] = [:]
        for r in try records() {
            let expected: FileFingerprint?
            if r.operation.state == "completed" { expected = r.original }
            else { expected = r.stage }
            if let expected {
                let components = try VaultPath(r.operation.path).components.dropLast()
                let prefix = components.isEmpty ? "" : components.joined(separator: "/") + "/"
                result[prefix + r.operation.artifact] = expected
            }
        }
        return result
    }
}
