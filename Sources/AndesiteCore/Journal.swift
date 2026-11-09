import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The complete desired change of one catalog entry: from its current live
/// file (`from`, `fromHash`) to a new state (`to`, `toHash`; `to == nil`
/// deletes). Local edits and remote revisions use the same plan.
struct MutationPlan: Codable {
    var entry: Data
    var kind: String
    var base: Data?
    var revision: Data
    var parents: [Data]
    var from: String?
    var fromHash: String?
    var fromHint: FileFingerprint?
    var to: String?
    var toHash: String?
    var toSize: Int64?
    var origin: String
    /// Remote revisions recorded (without changing files) in the same commit.
    var records: [RevisionRecord] = []
    /// A whole-directory rename (`from`/`to` are directory paths).
    var directory = false

    enum Action { case none, create, replace, rename, relocate, remove, moveDirectory }

    var action: Action {
        if directory { return .moveDirectory }
        switch (from, to) {
        case (nil, nil): return .none
        case (nil, .some): return .create
        case (.some, nil): return .remove
        case (let a?, let b?):
            if Array(a.utf8) == Array(b.utf8) { return fromHash == toHash ? .none : .replace }
            return fromHash == toHash ? .rename : .relocate
        }
    }
}

/// Durable intent -> filesystem steps -> catalog commit -> cleanup.
///
/// A filesystem change and a SQLite commit cannot be one transaction. The
/// intent row is durable before any file changes. After a crash, `settle`
/// observes the files: if the atomic publishing step happened the commit is
/// rolled forward, otherwise every staged artifact is discarded. The
/// forward path calls the same `settle`, so recovery logic runs every time.
/// Displaced bytes that are neither the old nor the new version are never
/// deleted; they are renamed into a visible "(recovered ...)" copy.
final class Journal {
    let db: SQLiteConnection
    let objects: ObjectStore
    let root: Int32
    let vaultID: Data
    let maximumBytes: Int
    var fault: (String) throws -> Void = Journal.environmentFault

    init(db: SQLiteConnection, objects: ObjectStore, root: Int32, vaultID: Data, maximumBytes: Int) {
        self.db = db; self.objects = objects; self.root = root
        self.vaultID = vaultID; self.maximumBytes = maximumBytes
    }

    /// Opt-in process-death harness for crash tests; inert in production.
    static func environmentFault(_ point: String) throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["ANDESITE_TEST_FAULTS"] == "1", environment["ANDESITE_TEST_KILL_POINT"] == point {
            kill(getpid(), SIGKILL)
            // The signalling thread may otherwise run on briefly before the
            // process is torn down; never let it perform another step.
            while true { pause() }
        }
    }

    // MARK: Forward path

    func run(_ plan: MutationPlan) throws {
        let id = ExternalCapture.identifier()
        try db.transaction {
            try db.executeValues("INSERT INTO mutations(id,state,plan,created_at) VALUES(?, 'intent', ?, ?)",
                                 bindings: [.blob(id), .text(try Self.encode(plan)), .real(Date().timeIntervalSince1970)])
        }
        try fault("intent")
        var failure: Error?
        do { try apply(plan, id: id) } catch { failure = error }
        guard try settle(id: id, plan: plan) else { throw failure ?? VaultError.conflict(current: plan.base) }
    }

    func recover() throws {
        for row in try db.queryValues("SELECT id,plan FROM mutations ORDER BY created_at,id") {
            guard case .blob(let id) = row[0], case .text(let json) = row[1] else {
                throw VaultRuntimeError.inconsistentCatalog
            }
            _ = try settle(id: id, plan: JSONDecoder().decode(MutationPlan.self, from: Data(json.utf8)))
        }
    }

    private func apply(_ plan: MutationPlan, id: Data) throws {
        let stage = Self.artifact(id), displaced = Self.artifact(id) + "-old"
        switch plan.action {
        case .none: return
        case .create:
            let (directory, name) = try open(plan.to!, create: true)
            guard !directory.exists(name) else { throw VaultError.alreadyExists(plan.to!) }
            try directory.writeStage(stage, object: plan.toHash!, objects: objects)
            try fault("staged")
            try directory.move(stage, to: directory, name)
            try fault("published")
        case .replace:
            let (directory, name) = try open(plan.to!)
            try verifyOriginal(directory, name, plan)
            try directory.writeStage(stage, object: plan.toHash!, objects: objects, copyMetadataFrom: name)
            try fault("staged")
            try verifyOriginal(directory, name, plan)
            try fault("verified")
            try directory.exchange(stage, name)
            try fault("published")
            if try directory.digest(stage, maximumBytes: Int.max)?.hash != plan.fromHash {
                // Another writer changed the file between the check and the
                // exchange. Put its version back; ours is still in the store.
                try directory.exchange(stage, name)
                throw VaultError.conflict(current: plan.base)
            }
        case .rename:
            let (source, name) = try open(plan.from!)
            let (target, newName) = try open(plan.to!, create: true)
            try verifyOriginal(source, name, plan)
            try source.move(name, to: target, newName)
            try fault("published")
        case .relocate:
            let (target, newName) = try open(plan.to!, create: true)
            guard !target.exists(newName) else { throw VaultError.alreadyExists(plan.to!) }
            let (source, name) = try open(plan.from!)
            try verifyOriginal(source, name, plan)
            try target.writeStage(stage, object: plan.toHash!, objects: objects, copyMetadataFrom: nil)
            try fault("staged")
            try target.move(stage, to: target, newName)
            try fault("published")
            try removeOriginal(plan, displaced: displaced)
        case .remove:
            try removeOriginal(plan, displaced: displaced)
        case .moveDirectory:
            let (source, name) = try open(plan.from!)
            let (target, newName) = try open(plan.to!, create: true)
            guard source.exists(name) else { throw VaultError.notFound(plan.from!) }
            try source.move(name, to: target, newName)
            try fault("published")
        }
    }

    /// Renames the original aside, verifies it is the expected version and
    /// only then lets the commit tombstone it. A racing edit is put back.
    private func removeOriginal(_ plan: MutationPlan, displaced: String) throws {
        let (directory, name) = try open(plan.from!)
        try verifyOriginal(directory, name, plan)
        try fault("verified")
        try directory.move(name, to: directory, displaced)
        try fault("removed")
        if try directory.digest(displaced, maximumBytes: Int.max)?.hash != plan.fromHash {
            try directory.move(displaced, to: directory, name)
            throw VaultError.conflict(current: plan.base)
        }
    }

    /// The live file must still be the catalogued head. An unchanged
    /// fingerprint is sufficient; otherwise the bytes are hashed.
    private func verifyOriginal(_ directory: VaultDirectory, _ name: String, _ plan: MutationPlan) throws {
        guard let info = try directory.info(name) else { throw VaultError.conflict(current: plan.base) }
        if let hint = plan.fromHint, info == hint { return }
        guard try directory.digest(name, maximumBytes: Int.max)?.hash == plan.fromHash else {
            throw VaultError.conflict(current: plan.base)
        }
    }

    // MARK: Settlement (shared by forward path and crash recovery)

    /// Returns true when the mutation is committed.
    @discardableResult
    func settle(id: Data, plan: MutationPlan) throws -> Bool {
        let rows = try db.queryValues("SELECT state FROM mutations WHERE id=?", bindings: [.blob(id)])
        guard case .text(let state) = rows.first?.first else { return false }
        var committed = state == "committed"
        if state == "intent" {
            if try published(plan, id: id) {
                if plan.action == .relocate, try exactlyExists(plan.from!) {
                    // Published but the original was not yet set aside. Finish
                    // that step if the original is still unchanged.
                    try? removeOriginal(plan, displaced: Self.artifact(id) + "-old")
                }
                try commit(plan, id: id)
                committed = true
            }
        }
        do {
            try cleanup(plan, id: id)
            try db.transaction { try db.executeValues("DELETE FROM mutations WHERE id=?", bindings: [.blob(id)]) }
        } catch where committed {
            // The change is committed; leftover artifacts and the plan row are
            // settled by the next recovery (for example once disk space is
            // available again), so this operation has succeeded.
            return true
        }
        try fault("done")
        return committed
    }

    /// Whether the atomic publishing step of the plan has happened.
    private func published(_ plan: MutationPlan, id: Data) throws -> Bool {
        switch plan.action {
        case .none: return true
        case .create, .relocate:
            return try digest(plan.to!)?.hash == plan.toHash
        case .replace:
            // After the exchange the stage name holds the displaced original.
            guard let (directory, _) = try? open(plan.to!) else { return false }
            return (try? directory.digest(Self.artifact(id), maximumBytes: Int.max))??.hash == plan.fromHash
        case .rename, .moveDirectory:
            return try exactlyExists(plan.to!) && !exactlyExists(plan.from!)
        case .remove:
            return try !exactlyExists(plan.from!)
        }
    }

    private func commit(_ plan: MutationPlan, id: Data) throws {
        if plan.directory { return try commitDirectory(plan, id: id) }
        var hint: FileFingerprint?
        if let to = plan.to, let observed = try digest(to), observed.hash == plan.toHash { hint = observed.fingerprint }
        let content: Data? = plan.kind == "markdown" && plan.to != nil ?
            try objects.get(plan.toHash!, maximumBytes: maximumBytes) : nil
        try fault("before-commit")
        try db.transaction {
            for record in plan.records { try Catalog.record(db: db, vaultID: vaultID, record) }
            let current = try Catalog.entry(db: db, vaultID: vaultID, id: plan.entry)
            guard current?.head == plan.base else { throw VaultRuntimeError.inconsistentCatalog }
            if current?.state == "live" {
                // Keep the replaced version as an explicit recovery point.
                try RecoverySnapshots.schedule(db: db, vaultID: vaultID, entryID: plan.entry, at: Date(),
                                               reason: "recovery", force: true)
            }
            let record = RevisionRecord(entry: plan.entry, revision: plan.revision, parents: plan.parents,
                                        path: plan.to ?? plan.from ?? "", deleted: plan.to == nil,
                                        hash: plan.to == nil ? nil : plan.toHash, size: plan.to == nil ? nil : plan.toSize,
                                        kind: plan.kind, origin: plan.origin)
            try Catalog.setHead(db: db, vaultID: vaultID, record, hint: hint)
            if let content {
                try SearchIndex.index(db: db, vaultID: vaultID, entryID: plan.entry, revisionID: plan.revision,
                                      bytes: content, withinTransaction: true)
            }
            try db.executeValues("UPDATE mutations SET state='committed' WHERE id=?", bindings: [.blob(id)])
        }
        try fault("committed")
    }

    private func commitDirectory(_ plan: MutationPlan, id: Data) throws {
        let prefix = plan.from! + "/", replacement = plan.to! + "/"
        try db.transaction {
            for entry in try Catalog.liveEntries(db: db, vaultID: vaultID, under: prefix) {
                let path = replacement + entry.path!.dropFirst(prefix.count)
                let record = RevisionRecord(entry: entry.id, revision: ExternalCapture.identifier(), parents: entry.head.map { [$0] } ?? [],
                                            path: path, deleted: false, hash: entry.hash, size: entry.size,
                                            kind: entry.kind, origin: plan.origin)
                try Catalog.setHead(db: db, vaultID: vaultID, record, hint: entry.hint)
            }
            try db.executeValues("UPDATE mutations SET state='committed' WHERE id=?", bindings: [.blob(id)])
        }
        try fault("committed")
    }

    /// Removes this operation's artifacts. Our own staged or displaced
    /// versions are already immutable objects; anything else is preserved.
    private func cleanup(_ plan: MutationPlan, id: Data) throws {
        var places: [(String, String)] = []
        if let to = plan.to, !plan.directory { places += [(to, Self.artifact(id)), (to, Self.artifact(id) + ".tmp")] }
        if let from = plan.from, !plan.directory { places.append((from, Self.artifact(id) + "-old")) }
        for (path, name) in places {
            guard let (directory, _) = try? open(path), directory.exists(name) else { continue }
            if name.hasSuffix(".tmp") { try directory.remove(name); continue }
            let hash = try? directory.digest(name, maximumBytes: Int.max)?.hash
            if let hash, hash == plan.fromHash || hash == plan.toHash {
                try directory.remove(name)
            } else {
                try preserve(directory, name, near: path)
            }
        }
    }

    private func preserve(_ directory: VaultDirectory, _ name: String, near path: String) throws {
        let original = try VaultPath(path).components.last!
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let copy = Self.sibling(original, label: "recovered " + stamp)
        try directory.move(name, to: directory, copy)
    }

    // MARK: Helpers

    static func artifact(_ id: Data) -> String { ".andesite-" + id.map { String(format: "%02x", $0) }.joined() }

    /// "note.md" -> "note (label).md"
    static func sibling(_ name: String, label: String) -> String {
        let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
        let stem = dot.map { String(name[..<$0]) } ?? name
        let suffix = dot.map { String(name[$0...]) } ?? ""
        return "\(stem) (\(label))\(suffix)"
    }

    static func encode(_ plan: MutationPlan) throws -> String {
        String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
    }

    func open(_ path: String, create: Bool = false) throws -> (VaultDirectory, String) {
        let parts = try VaultPath(path).components
        return (try VaultDirectory(root: root, components: Array(parts.dropLast()), create: create), parts.last!)
    }

    /// nil when absent or not an ordinary file we could have written.
    private func digest(_ path: String) throws -> (fingerprint: FileFingerprint, hash: String, size: Int64)? {
        guard let (directory, name) = try? open(path) else { return nil }
        return try? directory.digest(name, maximumBytes: Int.max)
    }

    /// Exact spelling check; a case-insensitive lookup would find "A.md"
    /// when asked for "a.md".
    func exactlyExists(_ path: String) throws -> Bool {
        guard let (directory, name) = try? open(path) else { return false }
        return try directory.names().contains(name)
    }
}
