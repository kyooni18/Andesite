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
}

public struct VaultConfiguration: Sendable {
    public let vaultDirectory: String
    public let stateDirectory: String
    public let maximumBytes: Int
    public let debounce: TimeInterval
    public init(vaultDirectory: String, stateDirectory: String, maximumBytes: Int = 16 * 1024 * 1024, debounce: TimeInterval = 0.25) {
        self.vaultDirectory = vaultDirectory; self.stateDirectory = stateDirectory
        self.maximumBytes = maximumBytes; self.debounce = debounce
    }
}

public struct ReconciliationReport: Sendable {
    public var discovered = 0
    public var revisionsCreated = 0
    public var unchanged = 0
    public var invalidMarkdown = 0
    public var deleted = 0
    public var renamed = 0
    public var snapshotsCreated = 0
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
    private var processLock: ProcessLock?
    let configuration: VaultConfiguration
    public let vaultID: Data

    /// Derived, disposable in-memory data. Only the VaultRuntime owner
    /// touches it, never an FSEvents callback, NIO task or separate SQLite
    /// connection. Reconciliation invalidates the published generation.
    private var linkSnapshot: VaultLinkGraph.Snapshot?
    private var linkBuilder: VaultLinkGraph.Builder?
    private var linkCacheReady = false
    private var linkCacheError: VaultLinkGraphError?
    private var linkCacheBuildCount = 0

    public struct LinkCacheReport: Sendable {
        public let parsedDocuments: Int
        public let reusedDocuments: Int
        public let graphChanged: Bool
        public let generation: Int
    }

    public var linksIndexed: Bool { linkCacheReady }
    public var linkCacheGeneration: Int { linkCacheBuildCount }
    /// Progress applies only to a pending low-priority generation.
    public var linkCacheProgress: (processedHeads: Int, totalHeads: Int, resolvedHeads: Int)? {
        guard let builder = linkBuilder else { return nil }
        return (builder.processedDocuments, builder.totalDocuments,
                builder.resolvedDocuments)
    }
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
        guard c.maximumBytes > 0, c.debounce.isFinite, c.debounce >= 0 else { throw VaultRuntimeError.invalidConfiguration }
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
                let pieces = recorded.split(separator: "\n", omittingEmptySubsequences: false)
                let priorIdentity = "\(rootInfo.st_dev):\(rootInfo.st_ino)"
                guard pieces.count == 2, String(pieces[1]) == priorIdentity,
                      let oldPath = pieces.first.map(String.init), oldPath != vault,
                      let selected = try VaultPathRegistry(vaultDirectory: vault).storedPath(),
                      selected == oldPath || selected == vault else {
                    throw VaultRuntimeError.identityMismatch
                }
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
            linkSnapshot = nil
            linkBuilder = nil
            linkCacheReady = false
            linkCacheError = nil
            resources = nil
            processLock = nil
        }
        _ = try flushSnapshots(at: date)
    }

    deinit { linkBuilder = nil; linkSnapshot = nil; resources = nil; processLock = nil }

    public func status() throws -> VaultStatus {
        guard let r = resources else { throw VaultRuntimeError.closed }
        func count(_ table: String, _ suffix: String = "") throws -> Int {
            Int(try r.db.scalarText("SELECT count(*) FROM \(table) \(suffix)") ?? "") ?? 0
        }
        return try VaultStatus(vaultID: vaultID, state: r.db.scalarText("SELECT state FROM vaults") ?? "unknown", entries: count("entries"), revisions: count("revisions"), openIncidents: count("incidents", "WHERE status='open'"), unfinishedMutations: count("mutations"))
    }

    /// Search refreshes canonical files first; failed/partial scans never expose
    /// the previous index as current. A result is an observation, not a live FS snapshot.
    public func search(_ phrase: String, limit: Int = 50) throws -> [SearchIndexHit] {
        _ = try reconcile()
        guard let r = resources else { throw VaultRuntimeError.closed }
        return try SearchIndex.search(db: r.db, vaultID: vaultID, phrase: phrase, limit: limit)
    }

    /// Catalog-only query for the in-process read-only local API. Unlike the
    /// interactive CLI search, never starts a nested scan or opens another
    /// SQLite owner while the watcher holds its exclusive state lock.
    public func searchIndexed(_ phrase: String, limit: Int = 50,
                              filter: ObsidianFilter? = nil) throws -> [SearchIndexHit] {
        guard let r = resources else { throw VaultRuntimeError.closed }
        guard try status().state == "ready" else { throw VaultRuntimeError.inconsistentCatalog }
                return try SearchIndex.search(db: r.db, vaultID: vaultID,
                                      phrase: phrase, limit: limit, filter: filter)
    }

    /// Current live Markdown heads, read from the same owner SQLite connection
    /// and never from source notes. No nested reconciliation takes place.
    public func documents(limit: Int = 50, offset: Int = 0,
                          filter: ObsidianFilter? = nil) throws -> DocumentPage {
        guard let r = resources else { throw VaultRuntimeError.closed }
        guard try status().state == "ready" else { throw VaultRuntimeError.inconsistentCatalog }
                return try DocumentCatalog.list(db: r.db, vaultID: vaultID,
                                        limit: limit, offset: offset, filter: filter)
    }

    public func inspectDocument(_ id: Data) throws -> IndexedDocument {
        guard let r = resources else { throw VaultRuntimeError.closed }
        guard try status().state == "ready" else { throw VaultRuntimeError.inconsistentCatalog }
                return try DocumentCatalog.inspect(db: r.db, vaultID: vaultID, documentID: id)
    }

    public func documentContents(_ id: Data, maximumBytes: Int = 1024 * 1024) throws -> Data {
        guard let r = resources else { throw VaultRuntimeError.closed }
        let document = try inspectDocument(id)
        return try DocumentCatalog.content(objects: r.objects, document: document, maximumBytes: maximumBytes)
    }

    /// The immutable, revision-aligned YAML/tags projection. No source reads,
    /// parser invocation or reconciliation happens on the HTTP request path.
    public func documentMetadata(_ id: Data) throws -> [String: Any] {
        guard let r = resources else { throw VaultRuntimeError.closed }
        let note = try inspectDocument(id)
        return try ObsidianMetadataIndex.document(db: r.db, vaultID: vaultID,
                                                   id: id, revision: note.revisionID)
    }

    public func tags(limit: Int = 50, offset: Int = 0) throws -> [String: Any] {
        guard let r = resources else { throw VaultRuntimeError.closed }
        guard try status().state == "ready" else { throw VaultRuntimeError.inconsistentCatalog }
                return try ObsidianMetadataIndex.tags(db: r.db, vaultID: vaultID,
                                               limit: limit, offset: offset)
    }

    public func properties(limit: Int = 50, offset: Int = 0) throws -> [String: Any] {
        guard let r = resources else { throw VaultRuntimeError.closed }
        guard try status().state == "ready" else { throw VaultRuntimeError.inconsistentCatalog }
                return try ObsidianMetadataIndex.properties(db: r.db, vaultID: vaultID,
                                                     limit: limit, offset: offset)
    }

    /// Cooperative background maintenance: advance one bounded parse/resolve
    /// slice, then yield to FSEvents and private HTTP before the next slice.
    /// The result is nil until the graph is fully rebuilt and atomically
    /// published. Only call on the existing synchronous VaultRuntime owner.
    @discardableResult
    public func advanceLinkCache(maxDocuments: Int = 8,
                                 maxBytes: Int = 256 * 1024) throws -> LinkCacheReport? {
        guard let r = resources else { throw VaultRuntimeError.closed }
        guard try status().state == "ready" else { throw VaultRuntimeError.inconsistentCatalog }
                do {
            if linkBuilder == nil {
                linkBuilder = try VaultLinkGraph.begin(
                    db: r.db, vaultID: vaultID, previous: linkSnapshot)
            }
            guard let builder = linkBuilder else { throw VaultLinkGraphError.inconsistentCatalog }
            guard let result = try builder.step(objects: r.objects,
                                                maxDocuments: maxDocuments,
                                                maxBytes: maxBytes) else {
                return nil
            }
            // Never publish partial generations; the old snapshot is reused
            // only internally until a complete fresh graph is available.
            linkSnapshot = result.snapshot
            linkBuilder = nil
            linkCacheError = nil
            linkCacheReady = true
            if result.changed { linkCacheBuildCount += 1 }
            return LinkCacheReport(parsedDocuments: result.parsed,
                                   reusedDocuments: result.reused,
                                   graphChanged: result.changed,
                                   generation: linkCacheBuildCount)
        } catch let graphError as VaultLinkGraphError {
            linkBuilder = nil
            linkCacheReady = false
            linkCacheError = graphError
            throw graphError
        } catch {
            linkBuilder = nil
            linkCacheReady = false
            linkCacheError = .inconsistentCatalog
            throw error
        }
    }

    /// Synchronous maintenance for explicit calls and legacy tests. The
    /// always-on watcher uses advanceLinkCache, not this blocking wrapper.
    @discardableResult
    public func refreshLinkCache() throws -> LinkCacheReport {
        while true {
            if let report = try advanceLinkCache() { return report }
        }
    }

    /// Cheap, page-only lookup of an already-published in-memory graph.
    /// Never scans, parses or reads the object store on the request path.
    public func links(_ documentID: Data, direction: VaultLinkDirection,
                      limit: Int = 50, offset: Int = 0) throws -> VaultLinkPage {
        guard resources != nil else { throw VaultRuntimeError.closed }
        guard try status().state == "ready" else { throw VaultRuntimeError.inconsistentCatalog }
                guard linkCacheReady, let snapshot = linkSnapshot else {
            throw linkCacheError ?? .cacheNotReady
        }
        return try snapshot.query(documentID: documentID, direction: direction,
                                  limit: limit, offset: offset)
    }

    public func reconcile(at date: Date = Date()) throws -> ReconciliationReport {
        guard let r = resources else { throw VaultRuntimeError.closed }
        // The prior snapshot can be reused incrementally after this scan,
        // but must not be served until its namespace has been reconciled.
        linkCacheReady = false
        linkBuilder = nil
        linkCacheError = nil
        try journal().recover()
        try RecoverySnapshots.validateTime(date)
        try setState("scanning")
        do {
            try verifyObjects()
            let scan = try r.reader.markdownFiles()
            let plan = try NamespacePlan(db: r.db, vaultID: vaultID, scan: scan)
            var report = ReconciliationReport()
            report.discovered = scan.count
            var deferred: [(Int, ExternalCapture.Prepared)] = []
            var quarantinedMove = false
            func index(_ captured: ExternalCaptureResult) throws {
                let bytes = try r.objects.get(captured.contentHash, maximumBytes: configuration.maximumBytes)
                try SearchIndex.index(db: r.db, vaultID: vaultID, entryID: captured.entryID, revisionID: captured.revisionID, bytes: bytes)
                if captured.sequence == nil { report.unchanged += 1 } else { report.revisionsCreated += 1 }
            }
            for (indexInScan, file) in scan.enumerated() {
                let observation = try r.reader.observeStable(file.path, maximumBytes: configuration.maximumBytes, debounce: configuration.debounce)
                guard observation.fingerprint == file.fingerprint else { throw VaultReadError.unstable }
                let prepared = try ExternalCapture.prepare(path: file.path, observation: observation, objects: r.objects)
                if plan.needsNamespaceCommit(index: indexInScan, file: file) {
                    if !prepared.valid {
                        let id = plan.assignment[indexInScan].map { plan.old[$0].id }
                        try r.db.transaction { try ExternalCapture.incident(db: r.db, vaultID: vaultID, prepared: prepared, entryID: id, at: date) }
                        report.invalidMarkdown += 1
                        quarantinedMove = true
                    } else { deferred.append((indexInScan, prepared)) }
                    continue
                }
                let captured = try r.db.transaction { try ExternalCapture.publish(db: r.db, vaultID: vaultID, prepared: prepared, at: date) }
                if let captured {
                    if try r.db.transaction({ try RecoverySnapshots.schedule(db: r.db, vaultID: vaultID, entryID: captured.entryID, at: date) }) { report.snapshotsCreated += 1 }
                    try index(captured)
                } else { report.invalidMarkdown += 1 }
            }
            // Only a fully enumerated, unchanged namespace and a later secure
            // absence check may authorize tombstones. A failure above or here
            // leaves earlier captures intact but publishes no disappearances.
            try NamespacePlan.validateUnchanged(scan, r.reader.markdownFiles())
            if quarantinedMove {
                try setState("quarantined")
                return report
            }
            let results: [ExternalCaptureResult] = try r.db.transaction {
                // Recheck after acquiring SQLite's writer lock, not before a
                // potentially long lock wait. No metadata has changed yet.
                for prior in plan.deleted {
                    guard try r.reader.confirmAbsent(plan.old[prior].path) else { throw VaultReadError.unstable }
                }
                for prior in plan.moved.union(plan.deleted).sorted() {
                    let reason = plan.deleted.contains(prior) ? "deletion" : "rename"
                    if try RecoverySnapshots.schedule(db: r.db, vaultID: vaultID, entryID: plan.old[prior].id, at: date, reason: reason, force: true) { report.snapshotsCreated += 1 }
                }
                for prior in plan.deleted.sorted() {
                    try ExternalCapture.tombstone(db: r.db, vaultID: vaultID, entryID: plan.old[prior].id, at: date)
                    report.deleted += 1; report.revisionsCreated += 1
                }
                // Release all old names together so swaps and reuse cannot violate
                // uniqueness or expose partially moved catalog identities.
                for prior in plan.moved.sorted() {
                    try r.db.executeValues("UPDATE entries SET state='reserved',path=NULL,path_key=NULL WHERE vault_id=? AND id=?", bindings: [.blob(vaultID), .blob(plan.old[prior].id)])
                }
                var results: [ExternalCaptureResult] = []
                for (indexInScan, prepared) in deferred {
                    let id = plan.assignment[indexInScan].map { plan.old[$0].id }
                    guard let captured = try ExternalCapture.publish(db: r.db, vaultID: vaultID, prepared: prepared, entryID: id, at: date) else { throw VaultRuntimeError.inconsistentCatalog }
                    let moved = id != nil
                    if moved { report.renamed += 1 }
                    if try RecoverySnapshots.schedule(db: r.db, vaultID: vaultID, entryID: captured.entryID, at: date, reason: moved ? "rename" : "interval", force: moved) { report.snapshotsCreated += 1 }
                    results.append(captured)
                }
                return results
            }
            for captured in results { try index(captured) }
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
            return report
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
        for row in try r.db.queryValues("SELECT lower(hex(hash)),length,durable_location FROM objects") {
            guard case .text(let hash) = row[0], case .integer(let length) = row[1], row[2] == .text(hash), length >= 0, length <= Int.max else { throw VaultRuntimeError.inconsistentCatalog }
            let bytes = try r.objects.get(hash, maximumBytes: Int(length))
            guard bytes.count == Int(length) else { throw VaultRuntimeError.inconsistentCatalog }
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
        let oldLines = old.components(separatedBy: "\n"), newLines = new.components(separatedBy: "\n")
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
            for row in try r.db.queryValues("SELECT id FROM entries WHERE vault_id=? AND state='live' AND kind='markdown' ORDER BY id", bindings: [.blob(vaultID)]) {
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
            for row in try r.db.queryValues("SELECT id FROM entries WHERE vault_id=? AND state='live' AND kind='markdown' ORDER BY id", bindings: [.blob(vaultID)]) {
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
            guard s.st_mode & 0o022 == 0 || s.st_mode & mode_t(S_ISVTX) != 0 else { throw VaultRuntimeError.invalidConfiguration }
            if prefix == path {
                guard s.st_uid == geteuid(), !privateDirectory || s.st_mode & 0o077 == 0 else { throw VaultRuntimeError.unsafeState }
            }
        }
    }
}
