import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum VaultRuntimeError: Error, Equatable {
    case invalidConfiguration
    case unsafeState
    case identityMismatch
    case inconsistentCatalog
    case portabilityCollision(String)
    case closed
    /// The first scan has not finished (or the last one failed), so the
    /// index does not yet reflect the vault.
    case indexNotReady
}

public struct VaultConfiguration: Sendable {
    public let vaultDirectory: String
    public let stateDirectory: String
    /// Largest Markdown note (notes are parsed in memory).
    public let maximumBytes: Int
    /// Largest attachment (attachments are only ever streamed).
    public let maximumFileBytes: Int
    public let debounce: TimeInterval
    public init(vaultDirectory: String, stateDirectory: String, maximumBytes: Int = 16 * 1024 * 1024,
                maximumFileBytes: Int = 4 * 1024 * 1024 * 1024, debounce: TimeInterval = 0.25) {
        self.vaultDirectory = vaultDirectory; self.stateDirectory = stateDirectory
        self.maximumBytes = maximumBytes; self.maximumFileBytes = maximumFileBytes; self.debounce = debounce
    }

    func limit(for kind: String) -> Int { kind == "markdown" ? maximumBytes : maximumFileBytes }
}

public struct ReconciliationReport: Sendable {
    public var discovered = 0
    public var revisionsCreated = 0
    public var unchanged = 0
    public var invalidMarkdown = 0
    public var deleted = 0
    public var renamed = 0
    public var snapshotsCreated = 0
    /// Files over the size limit, left untracked.
    public var oversize = 0
}

public struct VaultStatus: Sendable {
    public let vaultID: Data
    public let state: String
    public let entries: Int
    public let revisions: Int
    public let openIncidents: Int
    public let unfinishedMutations: Int
}

/// Synchronous, deliberately non-Sendable owner. Use on one blocking executor;
/// no database/reader/store escapes. shutdown closes the connection before lock release.
public final class VaultRuntime {
    struct Resources {
        let db: SQLiteConnection
        let reader: VaultReader
        let objects: ObjectStore
    }
    private(set) var resources: Resources?
    private var objectsVerifiedAt: Date?
    /// Set by `Vault` while background work runs; see `VaultExecutor`.
    var cooperation = Cooperation()
    private var processLock: ProcessLock?
    let configuration: VaultConfiguration
    public let vaultID: Data

    // Internal deterministic hook for tests; never supplied by vault contents.
    var mutationFault: ((String) throws -> Void)?
    func journal() throws -> Journal {
        guard let r = resources else { throw VaultRuntimeError.closed }
        let journal = Journal(db: r.db, objects: r.objects, root: r.reader.root, vaultID: vaultID,
                              maximumBytes: configuration.maximumBytes)
        if let mutationFault { journal.fault = mutationFault }
        return journal
    }

    func requireOpen() throws -> Resources {
        guard let r = resources else { throw VaultRuntimeError.closed }
        return r
    }

    public init(configuration: VaultConfiguration) throws {
        let c = configuration
        guard c.maximumBytes > 0, c.maximumFileBytes >= c.maximumBytes, c.debounce.isFinite, c.debounce >= 0 else { throw VaultRuntimeError.invalidConfiguration }
        try Self.validateDirectory(c.vaultDirectory, privateDirectory: false)
        try Self.validateDirectory(c.stateDirectory, privateDirectory: true)
        let vault = c.vaultDirectory
        let state = c.stateDirectory
        guard vault != state, !vault.hasPrefix(state + "/"), !state.hasPrefix(vault + "/") else { throw VaultRuntimeError.invalidConfiguration }
        let lock = try ProcessLock(stateDirectory: state)
        defer { withExtendedLifetime(lock) {} }
        // State is operator-owned and must not be modified by other processes.
        // Reject symlink/special SQLite files before SQLite can follow them.
        for name in ["catalog.sqlite", "catalog.sqlite-wal", "catalog.sqlite-shm"] {
            var s = stat()
            let path = state + "/" + name
            if lstat(path, &s) == 0 {
                guard s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), s.st_nlink == 1, s.st_uid == geteuid(), s.st_mode & 0o077 == 0 else { throw VaultRuntimeError.unsafeState }
            } else if errno != ENOENT { throw VaultRuntimeError.unsafeState }
        }
        let objectPath = state + "/objects"
        if mkdir(objectPath, 0o700) != 0 && errno != EEXIST { throw VaultRuntimeError.unsafeState }
        try Self.validateDirectory(objectPath, privateDirectory: true)
        // SQLite creates files according to umask; precreate the main file privately.
        let fd = open(state + "/catalog.sqlite", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd >= 0 { close(fd) } else if errno != EEXIST { throw VaultRuntimeError.unsafeState }
        let db = try SQLiteConnection(path: state + "/catalog.sqlite")
        try CatalogSchema.migrate(db)
        guard try db.scalarText("PRAGMA quick_check") == "ok", try db.queryValues("PRAGMA foreign_key_check").isEmpty else { throw VaultRuntimeError.inconsistentCatalog }
        let reader = try VaultReader(rootPath: vault)
        let objects = try ObjectStore(directory: objectPath)
        var rootInfo = stat()
        guard lstat(vault, &rootInfo) == 0 else { throw VaultRuntimeError.identityMismatch }
        let rootIdentity = "\(vault)\n\(rootInfo.st_dev):\(rootInfo.st_ino)"
        let rows = try db.queryValues("SELECT id,root_config FROM vaults")
        let id: Data
        if rows.isEmpty {
            id = Self.identifier()
            try db.executeValues("INSERT INTO vaults(id,root_config,epoch,created_at,state) VALUES(?,?,?,?, 'scanRequired')", bindings: [.blob(id), .text(rootIdentity), .blob(Self.identifier()), .text(ISO8601DateFormatter().string(from: Date()))])
        } else {
            guard rows.count == 1, rows[0].count == 2,
                  case .blob(let existing) = rows[0][0],
                  case .text(let recorded) = rows[0][1] else {
                throw VaultRuntimeError.identityMismatch
            }
            if recorded != rootIdentity {
                // Same-filesystem renames preserve the directory's inode.
                // Require that identity AND the path-only marker that moved
                // with the Vault. Existing revisions and IDs are preserved.
                // At the same path, the marker alone is enough: some file
                // systems (a folder shared into a VM) renumber inodes on
                // every mount, while the marker lives inside the folder.
                let pieces = recorded.split(separator: "\n", omittingEmptySubsequences: false)
                let priorIdentity = "\(rootInfo.st_dev):\(rootInfo.st_ino)"
                guard pieces.count == 2, let oldPath = pieces.first.map(String.init),
                      let selected = try VaultPathRegistry(vaultDirectory: vault).storedPath() else {
                    throw VaultRuntimeError.identityMismatch
                }
                let moved = String(pieces[1]) == priorIdentity && oldPath != vault && (selected == oldPath || selected == vault)
                let renumbered = oldPath == vault && selected == vault
                guard moved || renumbered else { throw VaultRuntimeError.identityMismatch }
                try db.transaction {
                    try db.executeValues(
                        "UPDATE vaults SET root_config=? WHERE id=? AND root_config=?",
                        bindings: [.text(rootIdentity), .blob(existing), .text(recorded)])
                }
            }
            id = existing
        }
        self.configuration = c
        self.vaultID = id
        self.processLock = lock
        self.resources = Resources(db: db, reader: reader, objects: objects)
        try setState("scanRequired")
        try verifyObjects()
        if try db.queryValues("SELECT 1 FROM snapshot_policy WHERE vault_id=?", bindings: [.blob(id)]).isEmpty {
            try RecoverySnapshots.configure(db: db, vaultID: id, policy: SnapshotPolicy())
        }
        _ = try RecoverySnapshots.policy(db: db, vaultID: id)
        // Settle interrupted mutations before anything observes the files.
        try journal().recover()
        _ = try flushSnapshotHeads(at: Date(), reason: "recovery")
        let directory = open(state, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw VaultRuntimeError.unsafeState }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw VaultRuntimeError.unsafeState }
    }

    /// Flush observed pending heads, not a last-second filesystem scan. Failures
    /// are reported, but resources/ownership are always released. Abrupt exits
    /// leave durable revisions from which scheduling resumes on reconciliation.
    public func shutdown(at date: Date = Date()) throws {
        guard resources != nil else { return }
        defer {
            resources = nil
            processLock = nil
        }
        _ = try flushSnapshots(at: date)
    }

    deinit { resources = nil; processLock = nil }

    public func status() throws -> VaultStatus {
        guard let r = resources else { throw VaultRuntimeError.closed }
        func count(_ table: String, _ suffix: String = "") throws -> Int {
            Int(try r.db.scalarText("SELECT count(*) FROM \(table) \(suffix)") ?? "") ?? 0
        }
        return try VaultStatus(vaultID: vaultID, state: r.db.scalarText("SELECT state FROM vaults") ?? "unknown", entries: count("entries"), revisions: count("revisions"), openIncidents: count("incidents", "WHERE status='open'"), unfinishedMutations: count("mutations"))
    }

    /// Runs `body` with catalog writes rejected (SQLite `query_only`).
    func readingOnly<T>(_ body: () throws -> T) rethrows -> T {
        guard let r = resources else { return try body() }
        try? r.db.execute("PRAGMA query_only=1")
        defer { try? r.db.execute("PRAGMA query_only=0") }
        return try body()
    }

    func requireReady() throws -> Resources {
        let r = try requireOpen()
        guard try status().state == "ready" else { throw VaultRuntimeError.indexNotReady }
        return r
    }

    /// Full-text search of the index as of the last scan.
    public func search(_ phrase: String, limit: Int = 50,
                       filter: ObsidianFilter? = nil) throws -> [SearchIndexHit] {
        let r = try requireReady()
        return try SearchIndex.search(db: r.db, vaultID: vaultID, phrase: phrase, limit: limit, filter: filter)
    }

    /// Current live Markdown heads, read from the same owner SQLite connection
    /// and never from source notes. No nested reconciliation takes place.
    public func documents(limit: Int = 50, offset: Int = 0,
                          filter: ObsidianFilter? = nil) throws -> DocumentPage {
        let r = try requireReady()
        return try DocumentCatalog.list(db: r.db, vaultID: vaultID,
                                        limit: limit, offset: offset, filter: filter)
    }

    public func inspectDocument(_ id: Data) throws -> IndexedDocument {
        let r = try requireReady()
        return try DocumentCatalog.inspect(db: r.db, vaultID: vaultID, documentID: id)
    }

    public func documentContents(_ id: Data, maximumBytes: Int = 1024 * 1024) throws -> Data {
        guard let r = resources else { throw VaultRuntimeError.closed }
        let document = try inspectDocument(id)
        return try DocumentCatalog.content(objects: r.objects, document: document, maximumBytes: maximumBytes)
    }

    /// The immutable, revision-aligned YAML/tags projection. No source reads,
    /// parser invocation or reconciliation happens on the HTTP request path.
    public func documentMetadata(_ id: Data) throws -> NoteMetadata {
        guard let r = resources else { throw VaultRuntimeError.closed }
        let note = try inspectDocument(id)
        return try ObsidianMetadataIndex.document(db: r.db, vaultID: vaultID,
                                                   id: id, revision: note.revisionID)
    }

    public func tags(limit: Int = 50, offset: Int = 0) throws -> TagPage {
        let r = try requireReady()
        return try ObsidianMetadataIndex.tags(db: r.db, vaultID: vaultID,
                                               limit: limit, offset: offset)
    }

    public func properties(limit: Int = 50, offset: Int = 0) throws -> PropertyPage {
        let r = try requireReady()
        return try ObsidianMetadataIndex.properties(db: r.db, vaultID: vaultID,
                                                     limit: limit, offset: offset)
    }

    /// Captures outside changes: new, edited, moved and deleted files.
    /// Repeats `scan` until a pass completes. After three incomplete
    /// passes, writes wait; if that pass is incomplete too, files kept
    /// changing during it and `VaultReadError.unstable` is thrown.
    public func reconcile(at date: Date = Date()) throws -> ReconciliationReport {
        var earlier = ReconciliationReport()
        for attempt in 0... {
            let (report, complete) = try scan(at: date, writesMayEnter: attempt < 3)
            if !complete && attempt >= 3 { throw VaultReadError.unstable }
            guard complete else {
                earlier.revisionsCreated += report.revisionsCreated
                earlier.snapshotsCreated += report.snapshotsCreated
                earlier.invalidMarkdown += report.invalidMarkdown
                continue
            }
            var total = report
            total.revisionsCreated += earlier.revisionsCreated
            total.snapshotsCreated += earlier.snapshotsCreated
            total.invalidMarkdown += earlier.invalidMarkdown
            return total
        }
        fatalError("unreachable")
    }

    /// One scan pass. Run by `Vault` as background work, it lets waiting
    /// user requests in: reads at any safe point, and, if `writesMayEnter`,
    /// writes between its batches.
    ///
    /// When a write entered, or a file changed while the pass ran, what the
    /// pass saw may be out of date: it commits the captures it could make,
    /// leaves moves and deletions to the next pass, and returns
    /// `complete: false`. The index stays usable meanwhile.
    func scan(at date: Date = Date(), writesMayEnter: Bool) throws -> (report: ReconciliationReport, complete: Bool) {
        guard let r = resources else { throw VaultRuntimeError.closed }
        try journal().recover()
        try RecoverySnapshots.validateTime(date)
        do {
            // The full catalog/object cross-check is O(vault): on the first
            // scan, then at most every five minutes. Content is verified by
            // hash whenever it is read.
            if objectsVerifiedAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true {
                try verifyObjects()
                objectsVerifiedAt = Date()
            }
            // Only reads may enter while the folder is enumerated: a write
            // could make the listing inconsistent.
            let all = try r.reader.files(visiting: { _ = cooperation.yield(false) })
            var interrupted = false // a user write ran, or a file changed
            func letUsersIn() { if cooperation.yield(writesMayEnter) { interrupted = true } }
            // Files over their size limit are left alone: untracked, and not
            // mistaken for the deletion of what was tracked at that path.
            let oversize = Set(all.filter { $0.fingerprint.size > Int64(configuration.limit(for: $0.kind)) }.map(\.path.portabilityKey))
            let scan = all.filter { !oversize.contains($0.path.portabilityKey) }
            let plan = try NamespacePlan(db: r.db, vaultID: vaultID, scan: scan)
            let deleted = plan.deleted.filter { !oversize.contains(plan.old[$0].path.portabilityKey) }
            var report = ReconciliationReport()
            report.discovered = scan.count
            report.oversize = all.count - scan.count
            var deferred: [(Int, ExternalCapture.Prepared)] = []
            var quarantinedMove = false
            /// Indexes captured notes in one transaction. Their revisions are
            /// already committed; a failed index is repaired by a later scan.
            typealias Captured = (result: ExternalCaptureResult, kind: String, analysis: SearchIndex.Analysis?)
            func index(_ captured: [Captured]) throws {
                try r.db.transaction {
                    for (result, kind, analysis) in captured where kind == "markdown" {
                        let analysis = try analysis ?? SearchIndex.analyze(
                            r.objects.get(result.contentHash, maximumBytes: configuration.maximumBytes))
                        try SearchIndex.index(db: r.db, vaultID: vaultID, entryID: result.entryID, revisionID: result.revisionID,
                                              analysis: analysis, withinTransaction: true)
                    }
                }
                for (result, _, _) in captured {
                    if result.sequence == nil { report.unchanged += 1 } else { report.revisionsCreated += 1 }
                }
            }
            // Only files whose metadata differs from the catalog are read.
            let changed = scan.indices.filter { index in
                guard let prior = plan.assignment[index], !plan.moved.contains(prior) else { return true }
                return plan.old[prior].fingerprint != scan[index].fingerprint
            }
            report.unchanged = scan.count - changed.count
            // One quiet period for the whole batch, counted from the latest
            // change (watcher scans start after one, so they rarely wait). A
            // file still being written changes its fingerprint; it is left
            // to the next pass.
            let latest = changed.map { scan[$0].fingerprint.changedAt }.max() ?? 0
            let wait = min(configuration.debounce, latest + configuration.debounce - Date().timeIntervalSince1970)
            if wait > 0, cooperation.pause(wait, writesMayEnter) { interrupted = true }
            // Captures are committed in batches: one transaction (and one
            // device flush) for many files instead of several per file. A
            // batch ends early when a user write is waiting, which then runs
            // between batches.
            var position = 0
            while position < changed.count {
                // Notes are parsed here, before the commit, so a write that
                // waits for the batch waits only for its SQL.
                var ready: [(ExternalCapture.Prepared, SearchIndex.Analysis?)] = []
                let start = position
                while position < changed.count, position - start < 256,
                      position == start || !(writesMayEnter && cooperation.writeWaiting()) {
                    // Reads may enter mid-batch: nothing is published yet.
                    _ = cooperation.yield(false)
                    let indexInScan = changed[position]
                    position += 1
                    let file = scan[indexInScan]
                    let prepared: ExternalCapture.Prepared, analysis: SearchIndex.Analysis?
                    do {
                        let (hash, size) = try r.reader.capture(file.path, expected: file.fingerprint, into: r.objects,
                                                                maximumBytes: configuration.limit(for: file.kind))
                        prepared = try ExternalCapture.prepare(file, hash: hash, size: size, objects: r.objects,
                                                               maximumMarkdownBytes: configuration.maximumBytes)
                        analysis = prepared.kind == "markdown" && prepared.valid
                            ? try SearchIndex.analyze(r.objects.get(hash, maximumBytes: configuration.maximumBytes)) : nil
                    } catch let error where interrupted || error as? VaultReadError == .unstable {
                        // Being written, or changed by a user write: the next pass looks again.
                        interrupted = true
                        continue
                    }
                    if plan.needsNamespaceCommit(index: indexInScan, file: file) {
                        if !prepared.valid {
                            let id = plan.assignment[indexInScan].map { plan.old[$0].id }
                            try r.db.transaction { try ExternalCapture.incident(db: r.db, vaultID: vaultID, prepared: prepared, entryID: id, at: date) }
                            report.invalidMarkdown += 1
                            quarantinedMove = true
                        } else { deferred.append((indexInScan, prepared)) }
                    } else {
                        ready.append((prepared, analysis))
                    }
                }
                let captured: [Captured]
                do { captured = try r.db.transaction {
                    var captured: [Captured] = []
                    for (prepared, analysis) in ready {
                        guard let result = try ExternalCapture.publish(db: r.db, vaultID: vaultID, prepared: prepared, at: date) else {
                            report.invalidMarkdown += 1
                            continue
                        }
                        if try RecoverySnapshots.schedule(db: r.db, vaultID: vaultID, entryID: result.entryID, at: date) { report.snapshotsCreated += 1 }
                        captured.append((result, prepared.kind, analysis))
                    }
                    return captured
                } } catch where interrupted {
                    return (report, false)
                }
                try index(captured)
                letUsersIn()
            }
            if interrupted { return (report, false) }
            // Only a fully enumerated, unchanged namespace and a later secure
            // absence check may authorize tombstones. A failure above or here
            // leaves earlier captures intact but publishes no disappearances.
            let after = try r.reader.files(visiting: { _ = cooperation.yield(false) })
            guard (try? NamespacePlan.validateUnchanged(all, after)) != nil else { return (report, false) }
            if quarantinedMove {
                try setState("quarantined")
                return (report, true)
            }
            let results: [Captured] = try r.db.transaction {
                // Recheck after acquiring SQLite's writer lock, not before a
                // potentially long lock wait. No metadata has changed yet.
                for prior in deleted {
                    guard try r.reader.confirmAbsent(plan.old[prior].path) else { throw VaultReadError.unstable }
                }
                for prior in plan.moved.union(deleted).sorted() {
                    let reason = deleted.contains(prior) ? "deletion" : "rename"
                    if try RecoverySnapshots.schedule(db: r.db, vaultID: vaultID, entryID: plan.old[prior].id, at: date, reason: reason, force: true) { report.snapshotsCreated += 1 }
                }
                for prior in deleted.sorted() {
                    try ExternalCapture.tombstone(db: r.db, vaultID: vaultID, entryID: plan.old[prior].id, at: date)
                    report.deleted += 1; report.revisionsCreated += 1
                }
                // Release all old names together so swaps and reuse cannot violate
                // uniqueness or expose partially moved catalog identities.
                for prior in plan.moved.sorted() {
                    try r.db.executeValues("UPDATE entries SET state='reserved',path=NULL,path_key=NULL,name_key=NULL WHERE vault_id=? AND id=?", bindings: [.blob(vaultID), .blob(plan.old[prior].id)])
                }
                var results: [Captured] = []
                for (indexInScan, prepared) in deferred {
                    let id = plan.assignment[indexInScan].map { plan.old[$0].id }
                    guard let captured = try ExternalCapture.publish(db: r.db, vaultID: vaultID, prepared: prepared, entryID: id, at: date) else { throw VaultRuntimeError.inconsistentCatalog }
                    let moved = id != nil
                    if moved { report.renamed += 1 }
                    if try RecoverySnapshots.schedule(db: r.db, vaultID: vaultID, entryID: captured.entryID, at: date, reason: moved ? "rename" : "interval", force: moved) { report.snapshotsCreated += 1 }
                    results.append((captured, prepared.kind, nil))
                }
                return results
            }
            try index(results)
            // v9 metadata migration: populate missing properties/tag rows
            // from already verified immutable revisions, never source files.
            // Do not declare the index ready with a partial backfill.
            _ = try SearchIndex.backfillMetadata(
                db: r.db, objects: r.objects, vaultID: vaultID,
                maximumBytes: configuration.maximumBytes)
            // Deleted/quarantined incident bytes are retained; an unresolved
            // incident remains visible even when its original path disappears.
            let incidents = try status().openIncidents
            try setState(incidents == 0 ? "ready" : "quarantined")
            // Unchanged files are not revisited, so promote snapshots that
            // became due since their revision was captured.
            report.snapshotsCreated += try scheduleDueSnapshots(at: date)
            return (report, true)
        } catch {
            try? setState("scanFailed")
            throw error
        }
    }

    private func setState(_ state: String) throws {
        guard let r = resources else { throw VaultRuntimeError.closed }
        try r.db.executeValues("UPDATE vaults SET state=? WHERE id=?", bindings: [.text(state), .blob(vaultID)])
    }

    private func verifyObjects() throws {
        guard let r = resources else { throw VaultRuntimeError.closed }
        guard try r.db.queryValues("SELECT 1 FROM revisions r LEFT JOIN objects o ON o.hash=r.content_hash WHERE r.deleted=0 AND (o.hash IS NULL OR o.length!=r.byte_length) LIMIT 1").isEmpty,
              try r.db.queryValues("SELECT 1 FROM entries e LEFT JOIN revisions r ON r.vault_id=e.vault_id AND r.entry_id=e.id AND r.revision_id=e.head_revision WHERE e.state IN ('live','deleted') AND (r.revision_id IS NULL OR r.deleted!=(e.state='deleted')) LIMIT 1").isEmpty,
              try r.db.queryValues("""
                SELECT 1 FROM recovery_snapshots s
                LEFT JOIN revisions r ON r.vault_id=s.vault_id AND r.revision_id=s.revision_id
                LEFT JOIN objects o ON o.hash=s.content_hash
                WHERE r.revision_id IS NULL OR r.entry_id!=s.entry_id OR r.deleted!=0
                  OR r.content_hash!=s.content_hash OR r.byte_length!=s.byte_length OR r.path!=s.path
                  OR o.hash IS NULL OR o.length!=s.byte_length LIMIT 1
                """).isEmpty else { throw VaultRuntimeError.inconsistentCatalog }
        // Every registered object must exist with its recorded size. Content
        // is verified by hash whenever it is read (exports, sync, restores).
        for (index, row) in try r.db.queryValues("SELECT lower(hex(hash)),length,durable_location FROM objects").enumerated() {
            if index % 1024 == 1023 { _ = cooperation.yield(false) }
            guard case .text(let hash) = row[0], case .integer(let length) = row[1], row[2] == .text(hash),
                  r.objects.size(hash) == length else { throw VaultRuntimeError.inconsistentCatalog }
        }
    }

    public func snapshotPolicy() throws -> SnapshotPolicy {
        guard let r = resources else { throw VaultRuntimeError.closed }
        return try RecoverySnapshots.policy(db: r.db, vaultID: vaultID)
    }

    /// Persists across restarts. Existing expiration deadlines are deliberately
    /// unchanged; configuration changes affect newly created snapshots only.
    public func configureSnapshots(_ policy: SnapshotPolicy) throws {
        guard let r = resources else { throw VaultRuntimeError.closed }
        try r.db.transaction { try RecoverySnapshots.configure(db: r.db, vaultID: vaultID, policy: policy) }
    }

    public func snapshots(entryID: Data? = nil, path: String? = nil) throws -> [RecoverySnapshot] {
        guard let r = resources else { throw VaultRuntimeError.closed }
        try verifyObjects()
        return try RecoverySnapshots.list(db: r.db, vaultID: vaultID, entryID: entryID, path: path)
    }

    public func inspectSnapshot(_ id: Data) throws -> RecoverySnapshot {
        guard let r = resources else { throw VaultRuntimeError.closed }
        try verifyObjects()
        guard let snapshot = try RecoverySnapshots.list(db: r.db, vaultID: vaultID, snapshotID: id).first else { throw SnapshotError.notFound }
        let bytes = try r.objects.get(snapshot.contentHash, maximumBytes: snapshot.byteLength)
        guard bytes.count == snapshot.byteLength else { throw SnapshotError.inconsistentMetadata }
        return snapshot
    }

    public func snapshotContents(_ id: Data) throws -> Data {
        let snapshot = try inspectSnapshot(id)
        guard let r = resources else { throw VaultRuntimeError.closed }
        return try r.objects.get(snapshot.contentHash, maximumBytes: snapshot.byteLength)
    }

    public func compareSnapshots(_ beforeID: Data, _ afterID: Data) throws -> SnapshotComparison {
        let before = try inspectSnapshot(beforeID), after = try inspectSnapshot(afterID)
        // Bound CollectionDifference's work for adversarial input. Export larger
        // snapshots for comparison using the user's preferred diff tool.
        guard before.byteLength <= 256 * 1024, after.byteLength <= 256 * 1024 else { throw SnapshotError.comparisonTooLarge }
        let a = try snapshotContents(beforeID), b = try snapshotContents(afterID)
        guard let old = String(data: a, encoding: .utf8), let new = String(data: b, encoding: .utf8) else { throw SnapshotError.inconsistentMetadata }
        let oldLines = old.lines(), newLines = new.lines()
        guard oldLines.count <= 2000, newLines.count <= 2000 else { throw SnapshotError.comparisonTooLarge }
        let changes = newLines.difference(from: oldLines, by: { $0.utf8.elementsEqual($1.utf8) }).map { change -> String in
            switch change {
            case .remove(let offset, let line, _): return "-\(offset):\(line)"
            case .insert(let offset, let line, _): return "+\(offset):\(line)"
            }
        }
        return SnapshotComparison(before: before, after: after, changes: changes)
    }

    public func exportSnapshot(_ id: Data, to destination: String) throws {
        let bytes = try snapshotContents(id)
        try SnapshotExport.publish(bytes, to: destination, excluding: [configuration.vaultDirectory, configuration.stateDirectory])
    }

    public func snapshotStorage(at date: Date = Date()) throws -> SnapshotStorageUsage {
        guard let r = resources else { throw VaultRuntimeError.closed }
        try verifyObjects()
        var usage = try RecoverySnapshots.usage(db: r.db, vaultID: vaultID, at: date)
        let physical = try r.objects.storageUsage()
        usage.immutableObjectLogicalBytes = physical.logical
        usage.physicalObjectAllocatedBytes = physical.allocated
        usage.temporaryObjectAllocatedBytes = physical.temporary
        return usage
    }

    /// Promote already durably captured heads when their per-document minimum
    /// snapshot interval expires. This never reads or writes vault source files.
    /// The continuous monitor calls it on a timer; editor events are only hints
    /// that drive full reconciliation through the existing scanner.
    @discardableResult
    public func scheduleDueSnapshots(at date: Date = Date()) throws -> Int {
        guard let r = resources else { throw VaultRuntimeError.closed }
        try RecoverySnapshots.validateTime(date)
        // Neither a failed scan nor a conflicting restore can silently publish
        // snapshots as though the currently observed filesystem were verified.
        guard try status().state == "ready" else { return 0 }
                return try r.db.transaction {
            var created = 0
            // Only notes whose current version has no snapshot yet can be due.
            for row in try r.db.queryValues("""
                SELECT e.id FROM entries e WHERE e.vault_id=? AND e.state='live' AND e.kind='markdown'
                  AND NOT EXISTS (SELECT 1 FROM recovery_snapshots s
                                  WHERE s.vault_id=e.vault_id AND s.entry_id=e.id AND s.revision_id=e.head_revision)
                ORDER BY e.id
                """, bindings: [.blob(vaultID)]) {
                guard case .blob(let id) = row[0] else { throw VaultRuntimeError.inconsistentCatalog }
                if try RecoverySnapshots.schedule(db: r.db, vaultID: vaultID, entryID: id, at: date) { created += 1 }
            }
            return created
        }
    }

    @discardableResult
    public func flushSnapshots(at date: Date = Date()) throws -> Int {
        try flushSnapshotHeads(at: date, reason: "shutdown")
    }

    private func flushSnapshotHeads(at date: Date, reason: String) throws -> Int {
        guard let r = resources else { throw VaultRuntimeError.closed }
        try verifyObjects()
        try RecoverySnapshots.validateTime(date)
        return try r.db.transaction {
            var created = 0
            // Only notes whose current version has no snapshot yet can be due.
            for row in try r.db.queryValues("""
                SELECT e.id FROM entries e WHERE e.vault_id=? AND e.state='live' AND e.kind='markdown'
                  AND NOT EXISTS (SELECT 1 FROM recovery_snapshots s
                                  WHERE s.vault_id=e.vault_id AND s.entry_id=e.id AND s.revision_id=e.head_revision)
                ORDER BY e.id
                """, bindings: [.blob(vaultID)]) {
                guard case .blob(let id) = row[0] else { throw VaultRuntimeError.inconsistentCatalog }
                if try RecoverySnapshots.schedule(db: r.db, vaultID: vaultID, entryID: id, at: date, reason: reason, force: true) { created += 1 }
            }
            return created
        }
    }

    private static func identifier() -> Data {
        var value = UUID().uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func validateDirectory(_ path: String, privateDirectory: Bool) throws {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }), path != "/" else { throw VaultRuntimeError.invalidConfiguration }
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            var s = stat()
            guard lstat(prefix, &s) == 0, s.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw VaultRuntimeError.invalidConfiguration }
            // Ancestors may be shared sticky temp directories, not arbitrary writable directories.
            guard s.st_mode & 0o022 == 0 || s.st_mode & mode_t(S_ISVTX) != 0 || isAboveAppContainer(prefix) else { throw VaultRuntimeError.invalidConfiguration }
            if prefix == path {
                guard s.st_uid == geteuid(), !privateDirectory || s.st_mode & 0o077 == 0 else { throw VaultRuntimeError.unsafeState }
            }
        }
    }
}
