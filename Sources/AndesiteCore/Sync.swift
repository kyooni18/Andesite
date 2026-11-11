import Foundation
import Crypto

/// One revision as exchanged between peers. IDs are lowercase hex.
public struct SyncRecord: Codable, Sendable, Equatable {
    public var sequence: Int64
    public var document: String
    public var revision: String
    public var parents: [String]
    public var path: String
    public var deleted: Bool
    public var hash: String?
    public var size: Int64?
    public var kind: String
    public var origin: String
}

/// A page of a Vault's change feed, in the order the revisions were recorded
/// (so parents always precede children).
public struct SyncBatch: Codable, Sendable {
    public var vault: String
    public var epoch: String
    public var records: [SyncRecord]
    /// Every feed position up to here is covered by this page.
    public var through: Int64
    /// The sender's newest feed position.
    public var head: Int64
}

public struct ObjectProgress: Codable, Sendable, Equatable {
    public var hash: String
    public var received: Int64
    public init(hash: String, received: Int64) { self.hash = hash; self.received = received }
}

public struct SyncIdentity: Codable, Sendable, Equatable {
    public var vault: String
    public var epoch: String
}

public struct SyncReport: Codable, Sendable, Equatable {
    /// New revisions recorded from the peer.
    public var received = 0
    /// Revisions sent to the peer.
    public var sent = 0
    /// Documents whose current version changed.
    public var applied = 0
    /// Merge revisions created.
    public var merged = 0
    /// Conflicting versions preserved as separate documents or paths.
    public var conflicts = 0
    /// Documents still waiting (see `failures`); retried on the next sync.
    public var pending = 0
    public var failures: [String] = []

    public init() {}

    mutating func add(_ other: SyncReport) {
        received += other.received; applied += other.applied; merged += other.merged
        conflicts += other.conflicts; pending = other.pending; failures = other.failures
    }
}

public enum SyncError: Error, Equatable {
    case invalidBatch(String)
    case historyGap(String)
    case missingObject(String)
}

/// Bidirectional sync over the revision graph.
///
/// Receiving only records revisions (and marks their documents pending);
/// it never touches files. `resolvePending` then brings each pending
/// document to the single head implied by its graph, through the same
/// mutation journal as local edits. Several heads are merged: a clean
/// three-way merge when possible, otherwise the greater revision wins and
/// the other version is kept as a separate conflict copy. Merge, conflict
/// and rename-aside revisions have IDs derived from their inputs, so two
/// peers that resolve the same graph create the same revisions and converge.
extension VaultRuntime {
    public static let syncPageLimit = 500

    public func syncIdentity() throws -> SyncIdentity {
        let rows = try requireOpen().db.queryValues("SELECT epoch FROM vaults WHERE id=?", bindings: [.blob(vaultID)])
        guard case .blob(let epoch) = rows.first?.first else { throw VaultRuntimeError.inconsistentCatalog }
        return SyncIdentity(vault: vaultID.hex, epoch: epoch.hex)
    }

    /// Feed positions after `after`, at most `limit` revisions.
    public func syncFeed(after: Int64, limit: Int = syncPageLimit) throws -> SyncBatch {
        guard after >= 0, (1...1000).contains(limit) else { throw SyncError.invalidBatch("range") }
        let r = try requireOpen()
        let rows = try r.db.queryValues("""
            SELECT c.seq,r.entry_id,r.revision_id,r.parent1,r.parent2,r.path,r.deleted,CASE WHEN r.content_hash IS NOT NULL THEN lower(hex(r.content_hash)) END,r.byte_length,e.kind,r.origin
            FROM changes c JOIN revisions r ON r.vault_id=c.vault_id AND r.revision_id=c.revision_id
            JOIN entries e ON e.vault_id=r.vault_id AND e.id=r.entry_id
            WHERE c.vault_id=? AND c.seq>? ORDER BY c.seq LIMIT ?
            """, bindings: [.blob(vaultID), .integer(after), .integer(Int64(limit))])
        let records = try rows.map { row -> SyncRecord in
            guard case .integer(let seq) = row[0], case .blob(let entry) = row[1], case .blob(let revision) = row[2],
                  case .text(let path) = row[5], case .integer(let deleted) = row[6], case .text(let kind) = row[9],
                  case .text(let origin) = row[10] else { throw VaultRuntimeError.inconsistentCatalog }
            var parents: [String] = []
            if case .blob(let p) = row[3] { parents.append(p.hex) }
            if case .blob(let p) = row[4] { parents.append(p.hex) }
            var hash: String?, size: Int64?
            if case .text(let h) = row[7] { hash = h }
            if case .integer(let s) = row[8] { size = s }
            return SyncRecord(sequence: seq, document: entry.hex, revision: revision.hex, parents: parents, path: path,
                              deleted: deleted != 0, hash: hash, size: size, kind: kind, origin: origin)
        }
        guard case .integer(let next) = try r.db.queryValues("SELECT next_seq FROM vaults WHERE id=?",
                                                             bindings: [.blob(vaultID)]).first?.first else {
            throw VaultRuntimeError.inconsistentCatalog
        }
        let head = next - 1
        let identity = try syncIdentity()
        return SyncBatch(vault: identity.vault, epoch: identity.epoch, records: records,
                         through: records.count == limit ? records.last!.sequence : max(head, after), head: head)
    }

    // MARK: Objects

    /// Largest chunk of an object sent in one request.
    public static let chunkLimit = 4 * 1024 * 1024

    /// Of `hashes`, the objects this Vault lacks, with how much of each an
    /// interrupted transfer already delivered.
    public func missingObjects(_ hashes: [String]) throws -> [ObjectProgress] {
        guard hashes.count <= 5000, hashes.allSatisfy(ObjectStore.validHash) else { throw SyncError.invalidBatch("hashes") }
        let objects = try requireOpen().objects
        return Set(hashes).filter { !objects.contains($0) }.sorted()
            .map { ObjectProgress(hash: $0, received: objects.received($0)) }
    }

    /// Stores one chunk of a peer's object; see `ObjectStore.receive`.
    public func receiveChunk(_ hash: String, size: Int64, offset: Int64, _ data: Data) throws -> Int64 {
        guard ObjectStore.validHash(hash), size >= 0, size <= Int64(configuration.maximumFileBytes), offset >= 0,
              data.count <= Self.chunkLimit else { throw SyncError.invalidBatch("chunk") }
        do {
            return try requireOpen().objects.receive(hash, size: size, offset: offset, data)
        } catch ObjectStoreError.corruptObject {
            throw SyncError.invalidBatch("object \(hash) does not match its hash")
        }
    }

    public func objectChunk(_ hash: String, offset: Int64, length: Int) throws -> Data {
        guard ObjectStore.validHash(hash), try requireOpen().objects.contains(hash) else { throw VaultError.notFound(hash) }
        guard offset >= 0, (0...Self.chunkLimit).contains(length) else { throw SyncError.invalidBatch("range") }
        return try requireOpen().objects.chunk(hash, offset: offset, length: length)
    }

    // MARK: Bundles

    /// Objects up to this size travel whole, many to a request, in bundles
    /// of at most `chunkLimit` bytes. Larger ones use resumable chunks.
    public static let bundledObjectLimit: Int64 = 1024 * 1024

    /// The whole objects `hashes`, framed as `ObjectBundle`. Absent ones
    /// are skipped; the bundle stops before it would exceed `chunkLimit`.
    public func objectBundle(_ hashes: [String]) throws -> Data {
        guard hashes.count <= 5000, hashes.allSatisfy(ObjectStore.validHash) else { throw SyncError.invalidBatch("hashes") }
        let objects = try requireOpen().objects
        var bundle = Data()
        for hash in hashes where objects.contains(hash) {
            guard let size = objects.size(hash), size <= Self.bundledObjectLimit,
                  bundle.count + ObjectBundle.frameOverhead + Int(size) <= Self.chunkLimit else { continue }
            ObjectBundle.append(hash, try objects.chunk(hash, offset: 0, length: Int(size)), to: &bundle)
        }
        return bundle
    }

    /// Stores every object of a bundle, checking each against its hash.
    /// Returns how many were stored.
    @discardableResult
    public func receiveBundle(_ bundle: Data) throws -> Int {
        guard bundle.count <= Self.chunkLimit + 1024 * 1024 else { throw SyncError.invalidBatch("bundle") }
        let objects = try requireOpen().objects
        let frames = try ObjectBundle.frames(bundle)
        for (hash, bytes) in frames {
            guard Int64(bytes.count) <= min(Self.bundledObjectLimit, Int64(configuration.maximumFileBytes)),
                  ObjectStore.hash(bytes) == hash else { throw SyncError.invalidBatch("object \(hash) does not match its hash") }
            if !objects.contains(hash) { try objects.put(bytes) }
        }
        return frames.count
    }

    /// The newest feed position, for waiting on changes.
    public func syncHead() throws -> Int64 {
        guard case .integer(let next) = try requireOpen().db.queryValues("SELECT next_seq FROM vaults WHERE id=?",
                                                                         bindings: [.blob(vaultID)]).first?.first else {
            throw VaultRuntimeError.inconsistentCatalog
        }
        return next - 1
    }

    // MARK: Progress

    /// How far this Vault has received the feed of `peer`.
    public func syncCursor(_ peer: SyncIdentity) throws -> Int64 {
        guard let vault = Data(hex: peer.vault), let epoch = Data(hex: peer.epoch) else { throw SyncError.invalidBatch("peer") }
        let rows = try requireOpen().db.queryValues("SELECT last_seq FROM sync_inbox_cursors WHERE origin_vault=? AND origin_epoch=?",
                                                    bindings: [.blob(vault), .blob(epoch)])
        if case .integer(let value) = rows.first?.first { return value }
        return 0
    }

    /// How far `peer` has confirmed receiving this Vault's feed.
    public func acknowledgedSequence(_ peer: SyncIdentity) throws -> Int64 {
        let rows = try requireOpen().db.queryValues("SELECT acknowledged_seq FROM sync_outgoing_peers WHERE peer_key=?",
                                                    bindings: [.text(peer.vault + ":" + peer.epoch)])
        if case .integer(let value) = rows.first?.first { return value }
        return 0
    }

    public func acknowledge(_ peer: SyncIdentity, through: Int64) throws {
        try requireOpen().db.executeValues("""
            INSERT INTO sync_outgoing_peers(peer_key,acknowledged_seq,updated_at) VALUES(?,?,?)
            ON CONFLICT(peer_key) DO UPDATE SET acknowledged_seq=max(acknowledged_seq,excluded.acknowledged_seq),updated_at=excluded.updated_at
            """, bindings: [.text(peer.vault + ":" + peer.epoch), .integer(through), .text(ISO8601DateFormatter().string(from: Date()))])
    }

    // MARK: Receiving

    /// Records a page of a peer's feed in one transaction and advances the
    /// cursor for that peer. Known revisions are skipped, so duplicate or
    /// repeated delivery is harmless. Returns the number of new revisions.
    @discardableResult
    public func receive(_ batch: SyncBatch) throws -> Int {
        let r = try requireOpen()
        guard let source = Data(hex: batch.vault), source.count == 16, let epoch = Data(hex: batch.epoch), epoch.count == 16,
              source != vaultID, batch.records.count <= 1000, batch.through >= 0 else { throw SyncError.invalidBatch("header") }
        var received = 0
        try r.db.transaction {
            for item in batch.records {
                let record = try validated(item)
                if let known = try Catalog.revision(db: r.db, vaultID: vaultID, id: record.revision) {
                    guard known.entry == record.entry, known.parents == record.parents, known.deleted == record.deleted,
                          known.hash == record.hash else { throw SyncError.invalidBatch("revision \(item.revision) differs") }
                    continue
                }
                for parent in record.parents {
                    guard let known = try Catalog.revision(db: r.db, vaultID: vaultID, id: parent) else {
                        throw SyncError.historyGap(item.revision)
                    }
                    guard known.entry == record.entry else { throw SyncError.invalidBatch("parent of \(item.revision)") }
                }
                if let entry = try Catalog.entry(db: r.db, vaultID: vaultID, id: record.entry), entry.kind != record.kind {
                    throw SyncError.invalidBatch("kind of \(item.document)")
                }
                if let hash = record.hash, r.objects.size(hash) != record.size {
                    throw SyncError.missingObject(hash)
                }
                try Catalog.record(db: r.db, vaultID: vaultID, record)
                try markPending(record.entry)
                received += 1
            }
            try r.db.executeValues("""
                INSERT INTO sync_inbox_cursors(origin_vault,origin_epoch,last_seq) VALUES(?,?,?)
                ON CONFLICT(origin_vault,origin_epoch) DO UPDATE SET last_seq=max(last_seq,excluded.last_seq)
                """, bindings: [.blob(source), .blob(epoch), .integer(batch.through)])
        }
        return received
    }

    private func validated(_ s: SyncRecord) throws -> RevisionRecord {
        func id(_ text: String) throws -> Data {
            guard text.utf8.count == 32, text == text.lowercased(), let value = Data(hex: text) else {
                throw SyncError.invalidBatch("identifier \(text.prefix(40))")
            }
            return value
        }
        let parents = try s.parents.map(id)
        guard parents.count <= 2, Set(parents).count == parents.count,
              ["markdown", "attachment"].contains(s.kind), kind(of: s.path) == s.kind,
              s.path.utf8.count <= 1024, let path = try? VaultPath(s.path),
              SyncedVaultSettings.permits(path, document: s.document),
              s.deleted == (s.hash == nil), s.deleted == (s.size == nil),
              s.hash.map(ObjectStore.validHash) ?? true, (s.size ?? 0) >= 0, (s.size ?? 0) <= Int64(configuration.limit(for: s.kind)),
              !s.origin.isEmpty, s.origin.utf8.count <= 32 else { throw SyncError.invalidBatch("record \(s.revision.prefix(40))") }
        return RevisionRecord(entry: try id(s.document), revision: try id(s.revision), parents: parents, path: s.path,
                              deleted: s.deleted, hash: s.hash, size: s.size, kind: s.kind, origin: s.origin)
    }

    private func markPending(_ entry: Data) throws {
        try requireOpen().db.executeValues("INSERT INTO sync_pending(vault_id,entry_id) VALUES(?,?) ON CONFLICT DO NOTHING",
                                           bindings: [.blob(vaultID), .blob(entry)])
    }

    // MARK: Resolving

    /// Brings every pending document to its converged head. Documents that
    /// cannot be resolved stay pending and are reported.
    @discardableResult
    public func resolvePending() throws -> SyncReport {
        var report = SyncReport()
        try journal().recover()
        var failed: [Data: String] = [:], forced = false
        // Works through the pending documents in passes over one ordered
        // list, instead of querying for the next one after every document.
        while true {
            let ordered = try pendingEntries().filter { failed[$0] == nil }
            guard !ordered.isEmpty else { break }
            var pending = Set(ordered), progressed = false
            for entry in ordered where pending.contains(entry) {
                _ = cooperation.yield(false)
                do {
                    if try resolve(entry, forced: forced, pending: pending, &report) {
                        try requireOpen().db.executeValues("DELETE FROM sync_pending WHERE vault_id=? AND entry_id=?",
                                                           bindings: [.blob(vaultID), .blob(entry)])
                        pending.remove(entry)
                        progressed = true
                        forced = false
                    }
                } catch VaultRuntimeError.closed {
                    throw VaultRuntimeError.closed
                } catch {
                    failed[entry] = "\(error)"
                    pending.remove(entry)
                    progressed = true
                }
            }
            // Only documents waiting on each other remain (for example two
            // that swapped names): resolve them without waiting.
            if !progressed {
                if forced { break }
                forced = true
            }
        }
        report.pending = try pendingEntries().count
        report.failures = failed.map { "\($0.key.hex): \($0.value)" }.sorted()
        return report
    }

    /// Pending documents in the order their newest revisions arrived, so a
    /// move away from a path is applied before a create at that path.
    private func pendingEntries() throws -> [Data] {
        try requireOpen().db.queryValues("""
            SELECT p.entry_id FROM sync_pending p LEFT JOIN changes c ON c.vault_id=p.vault_id AND c.entry_id=p.entry_id
            WHERE p.vault_id=? GROUP BY p.entry_id ORDER BY max(c.seq),p.entry_id
            """, bindings: [.blob(vaultID)]).compactMap { if case .blob(let id) = $0[0] { return id }; return nil }
    }

    /// Returns false when the document must wait for another pending
    /// document to leave its path first.
    private func resolve(_ id: Data, forced: Bool, pending: Set<Data>, _ report: inout SyncReport) throws -> Bool {
        let db = try requireOpen().db
        for _ in 0..<4 {
            var graph = try RevisionGraph(db: db, vaultID: vaultID, entry: id)
            let tips = graph.tips
            guard var target = tips.first else { throw VaultRuntimeError.inconsistentCatalog }
            for tip in tips.dropFirst() { target = try merge(target, tip, &graph, &report) }
            guard let entry = try Catalog.entry(db: db, vaultID: vaultID, id: id),
                  var revision = try Catalog.revision(db: db, vaultID: vaultID, id: target) else {
                throw VaultRuntimeError.inconsistentCatalog
            }
            if entry.head == target { return true }
            let live = entry.state == "live"
            var destination: String?
            if !revision.deleted {
                let path = try vaultPath(revision.path, allowsSettings: true)
                if let occupant = try Catalog.live(db: db, vaultID: vaultID, path: path), occupant.id != id {
                    if !forced, pending.contains(occupant.id) { return false }
                    if !live, occupant.hash == revision.hash {
                        do { try adopt(id, target: revision, path: path, occupant: occupant) } catch VaultError.conflict { continue }
                        report.applied += 1
                        return true
                    }
                    // Two documents claim one path: the smaller ID keeps it.
                    if occupant.id.lexicographicallyPrecedes(id) {
                        let aside = RevisionRecord(entry: id, revision: Self.derive("aside", target), parents: [target],
                                                   path: try asidePath(path, id), deleted: false, hash: revision.hash,
                                                   size: revision.size, kind: revision.kind, origin: "sync")
                        try db.transaction { try Catalog.record(db: db, vaultID: vaultID, aside) }
                        report.conflicts += 1
                        continue
                    }
                    // Named from the occupant's own head path (it may differ in
                    // case from `path`), exactly as the peer derives this revision.
                    var plan = self.plan(occupant, to: try asidePath(occupant.path ?? path, occupant.id), hash: occupant.hash, size: occupant.size)
                    plan.revision = Self.derive("aside", occupant.head!)
                    plan.origin = "sync"
                    try requireAbsent(plan.to!)
                    do { try run(plan); report.conflicts += 1 } catch VaultError.conflict {}
                    continue
                }
                destination = path
                revision.path = path
            }
            let plan = MutationPlan(entry: id, kind: entry.kind, base: entry.head, revision: target, parents: revision.parents,
                                    from: live ? entry.path : nil, fromHash: live ? entry.hash : nil,
                                    fromHint: live ? entry.hint : nil, to: destination, toHash: revision.hash,
                                    toSize: revision.size, origin: revision.origin)
            do {
                try run(plan)
                report.applied += 1
                return true
            } catch VaultError.conflict {
                continue // A local edit was captured as a new head; merge again.
            } catch VaultError.alreadyExists {
                _ = try reconcile() // An untracked file is in the way; capture it, then retry.
                continue
            }
        }
        throw VaultError.conflict(current: nil)
    }

    /// Merges two heads of one document into a new revision.
    private func merge(_ x: Data, _ y: Data, _ graph: inout RevisionGraph, _ report: inout SyncReport) throws -> Data {
        let (a, b) = x.lexicographicallyPrecedes(y) ? (x, y) : (y, x)
        let id = Self.derive("merge", a, b)
        let base = graph.commonAncestor(a, b)
        graph.parents[id] = [a, b]
        let r = try requireOpen()
        if try Catalog.knows(db: r.db, vaultID: vaultID, revision: id) { return id }
        guard let ra = try Catalog.revision(db: r.db, vaultID: vaultID, id: a),
              let rb = try Catalog.revision(db: r.db, vaultID: vaultID, id: b) else { throw VaultRuntimeError.inconsistentCatalog }
        let original = try base.flatMap { try Catalog.revision(db: r.db, vaultID: vaultID, id: $0) }
        let baseHash = original?.deleted == false ? original?.hash : nil
        func edited(_ side: RevisionRecord) -> Bool { baseHash == nil || side.hash != baseHash }

        var result = rb, loser: RevisionRecord?
        if ra.deleted || rb.deleted {
            // An edit outlives a concurrent delete; a mere move does not.
            if !(ra.deleted && rb.deleted) {
                let (gone, kept) = ra.deleted ? (ra, rb) : (rb, ra)
                result = edited(kept) ? kept : gone
            }
        } else {
            result.path = Self.threeWay(original?.path, ra.path, rb.path)
            if ra.hash == rb.hash || baseHash == ra.hash {
                (result.hash, result.size) = (rb.hash, rb.size)
            } else if baseHash == rb.hash {
                (result.hash, result.size) = (ra.hash, ra.size)
            } else if ra.path == SyncedVaultSettings.path && rb.path == SyncedVaultSettings.path {
                if let merged = SyncedVaultSettings.merge(
                    base: try baseHash.map { try r.objects.get($0, maximumBytes: configuration.maximumBytes) },
                    try r.objects.get(ra.hash!, maximumBytes: configuration.maximumBytes),
                    try r.objects.get(rb.hash!, maximumBytes: configuration.maximumBytes)) {
                    result.hash = try store(merged, kind: "attachment")
                    result.size = Int64(merged.count)
                }
                // Malformed settings use the deterministic winner. Both versions
                // remain in history; never create another hidden settings file.
            } else if ra.kind == "markdown", let baseHash,
                      let merged = TextMerge.merge(base: try r.objects.get(baseHash, maximumBytes: configuration.maximumBytes),
                                                   try r.objects.get(ra.hash!, maximumBytes: configuration.maximumBytes),
                                                   try r.objects.get(rb.hash!, maximumBytes: configuration.maximumBytes)),
                      let hash = try? store(merged, kind: "markdown") {
                (result.hash, result.size) = (hash, Int64(merged.count))
            } else {
                (result.hash, result.size) = (rb.hash, rb.size)
                loser = ra
            }
        }
        result.revision = id
        result.parents = [a, b]
        result.origin = "merge"
        try r.db.transaction {
            try Catalog.record(db: r.db, vaultID: vaultID, result)
            if let loser {
                // The losing version becomes its own document.
                let copy = RevisionRecord(entry: Self.derive("conflict", loser.revision), revision: Self.derive("conflict-revision", loser.revision),
                                          parents: [], path: try asidePath(loser.path, loser.revision), deleted: false,
                                          hash: loser.hash, size: loser.size, kind: loser.kind, origin: "conflict")
                if try !Catalog.knows(db: r.db, vaultID: vaultID, revision: copy.revision) {
                    try Catalog.record(db: r.db, vaultID: vaultID, copy)
                    try markPending(copy.entry)
                }
            }
        }
        report.merged += 1
        if loser != nil { report.conflicts += 1 }
        return id
    }

    /// Two documents have identical content at one path (for example both
    /// peers captured the same copied file). The smaller ID keeps the path,
    /// the other is deleted; the file itself is not touched.
    private func adopt(_ id: Data, target: RevisionRecord, path: String, occupant: CatalogEntry) throws {
        let db = try requireOpen().db
        _ = try head(occupant.path!, revision: occupant.head!) // the file must still be the occupant's version
        try db.transaction {
            if occupant.id.lexicographicallyPrecedes(id) {
                try Catalog.setHead(db: db, vaultID: vaultID, RevisionRecord(
                    entry: id, revision: Self.derive("adopt", target.revision), parents: [target.revision], path: target.path,
                    deleted: true, hash: nil, size: nil, kind: target.kind, origin: "sync"), hint: nil)
            } else {
                try Catalog.setHead(db: db, vaultID: vaultID, RevisionRecord(
                    entry: occupant.id, revision: Self.derive("adopt", occupant.head!), parents: [occupant.head!], path: occupant.path!,
                    deleted: true, hash: nil, size: nil, kind: occupant.kind, origin: "sync"), hint: nil)
                var adopted = target
                adopted.path = path
                try Catalog.setHead(db: db, vaultID: vaultID, adopted, hint: occupant.hint)
                if target.kind == "markdown", let hash = target.hash {
                    try SearchIndex.index(db: db, vaultID: vaultID, entryID: id, revisionID: target.revision,
                                          bytes: try requireOpen().objects.get(hash, maximumBytes: configuration.maximumBytes),
                                          withinTransaction: true)
                }
            }
        }
    }

    /// "folder/note.md" -> "folder/note (conflict 1a2b3c4d).md"
    private func asidePath(_ path: String, _ id: Data) throws -> String {
        var components = try VaultPath(path).components
        components[components.count - 1] = Journal.sibling(components.last!, label: "conflict " + id.hex.prefix(8))
        return components.joined(separator: "/")
    }

    private func requireAbsent(_ path: String) throws {
        guard try Catalog.live(db: requireOpen().db, vaultID: vaultID, path: path) == nil else { throw VaultError.alreadyExists(path) }
    }

    /// The side that changed the value wins; if both did, `b` (the greater revision).
    static func threeWay(_ base: String?, _ a: String, _ b: String) -> String {
        if Array(a.utf8) == Array(b.utf8) || base.map({ Array($0.utf8) == Array(a.utf8) }) == true { return b }
        if base.map({ Array($0.utf8) == Array(b.utf8) }) == true { return a }
        return b
    }

    /// A 16-byte identifier determined by its inputs.
    static func derive(_ label: String, _ parts: Data...) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(("andesite-sync-v1:" + label).utf8))
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize().prefix(16))
    }
}

/// The revisions of one document and their parents.
struct RevisionGraph {
    var parents: [Data: [Data]] = [:]

    init(db: SQLiteConnection, vaultID: Data, entry: Data) throws {
        for row in try db.queryValues("SELECT revision_id,parent1,parent2 FROM revisions WHERE vault_id=? AND entry_id=?",
                                      bindings: [.blob(vaultID), .blob(entry)]) {
            guard case .blob(let id) = row[0] else { continue }
            parents[id] = row[1...].compactMap { if case .blob(let p) = $0 { return p }; return nil }
        }
    }

    /// Revisions that no other revision builds on, in a fixed order.
    var tips: [Data] {
        let used = Set(parents.values.joined())
        return parents.keys.filter { !used.contains($0) }.sorted { $0.lexicographicallyPrecedes($1) }
    }

    func ancestors(_ start: Data) -> Set<Data> {
        var seen: Set<Data> = [start], stack = [start]
        while let next = stack.popLast() {
            for parent in parents[next] ?? [] where seen.insert(parent).inserted { stack.append(parent) }
        }
        return seen
    }

    /// The nearest common ancestor; among several equally near ones, the
    /// greatest ID, so every peer picks the same base.
    func commonAncestor(_ a: Data, _ b: Data) -> Data? {
        let common = ancestors(a).intersection(ancestors(b))
        var below = Set<Data>(), stack = common.flatMap { parents[$0] ?? [] }
        while let next = stack.popLast() {
            if below.insert(next).inserted { stack += parents[next] ?? [] }
        }
        return common.subtracting(below).max { $0.lexicographicallyPrecedes($1) }
    }
}
