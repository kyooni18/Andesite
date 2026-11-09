import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The document lifecycle. Paths are Vault-relative ("folder/note.md").
/// `revision` arguments are optimistic-concurrency preconditions: the call
/// fails with `VaultError.conflict` unless the document's current head is
/// exactly that revision (and the file on disk still matches it).
extension VaultRuntime {
    /// Creates a new file. Fails if anything already exists at `path`,
    /// including a case- or Unicode-normalization variant of it.
    @discardableResult
    public func create(_ path: String, _ content: Data) throws -> IndexedDocument {
        let path = try vaultPath(path)
        return try create(path, hash: try store(content, kind: kind(of: path)), size: Int64(content.count))
    }

    /// Creates a file from a local file's bytes, streamed (for large attachments).
    @discardableResult
    public func create(_ path: String, contentsOf file: URL) throws -> IndexedDocument {
        let path = try vaultPath(path)
        let (hash, size) = try store(contentsOf: file, kind: kind(of: path))
        return try create(path, hash: hash, size: size)
    }

    private func create(_ path: String, hash: String, size: Int64) throws -> IndexedDocument {
        guard try Catalog.live(db: requireOpen().db, vaultID: vaultID, path: path) == nil else { throw VaultError.alreadyExists(path) }
        try run(MutationPlan(entry: ExternalCapture.identifier(), kind: kind(of: path), base: nil, revision: ExternalCapture.identifier(),
                             parents: [], to: path, toHash: hash, toSize: size, origin: "local"))
        return try document(path)
    }

    /// The current document and its exact bytes (up to the Markdown size
    /// limit; use `openContent` for larger attachments).
    public func read(_ path: String) throws -> (document: IndexedDocument, content: Data) {
        let document = try self.document(path)
        guard document.byteLength <= configuration.maximumBytes else { throw VaultError.tooLarge }
        return (document, try requireOpen().objects.get(document.hash, maximumBytes: configuration.maximumBytes))
    }

    /// The current document and a read-only descriptor of its content, for
    /// streaming. The caller closes the descriptor; it may be used from any
    /// thread because stored content never changes.
    public func openContent(_ path: String) throws -> (document: IndexedDocument, descriptor: Int32) {
        let document = try self.document(path)
        return (document, try requireOpen().objects.descriptor(document.hash))
    }

    @discardableResult
    public func update(_ path: String, _ content: Data, revision: Data) throws -> IndexedDocument {
        let current = try head(path, revision: revision)
        return try update(current, hash: try store(content, kind: current.kind), size: Int64(content.count))
    }

    @discardableResult
    public func update(_ path: String, contentsOf file: URL, revision: Data) throws -> IndexedDocument {
        let current = try head(path, revision: revision)
        let (hash, size) = try store(contentsOf: file, kind: current.kind)
        return try update(current, hash: hash, size: size)
    }

    private func update(_ current: CatalogEntry, hash: String, size: Int64) throws -> IndexedDocument {
        if hash == current.hash { return try document(current.path!) }
        try run(plan(current, to: current.path, hash: hash, size: size))
        return try document(current.path!)
    }

    /// Renames or relocates a file. Missing destination folders are created.
    /// With `updateLinks`, links elsewhere that pointed at the file (and
    /// relative links inside it) are rewritten to keep resolving to the same
    /// files, wherever that can be done unambiguously.
    @discardableResult
    public func move(_ path: String, to newPath: String, revision: Data, updateLinks: Bool = true) throws -> IndexedDocument {
        let current = try head(path, revision: revision)
        let target = try vaultPath(newPath)
        guard kind(of: target) == current.kind else { throw VaultError.invalidPath(newPath) }
        if Array(target.utf8) == Array(current.path!.utf8) { return try document(target) }
        try requireFree(target, for: current)
        let affected = updateLinks ? try linksAffected(byMoving: [current]) : []
        try run(plan(current, to: target, hash: current.hash, size: current.size))
        try retarget(affected)
        return try document(target)
    }

    /// Deletes the file. Its history (and every earlier version) remains.
    public func delete(_ path: String, revision: Data) throws {
        let current = try head(path, revision: revision)
        try run(plan(current, to: nil, hash: nil, size: nil))
    }

    /// Makes an earlier revision current again at `path`: the document's
    /// current path, a new path, or the original path of a deleted document.
    @discardableResult
    public func restore(_ path: String, revision: Data) throws -> IndexedDocument {
        let r = try requireOpen()
        guard let old = try r.db.queryValues("SELECT entry_id,lower(hex(content_hash)),byte_length FROM revisions WHERE vault_id=? AND revision_id=? AND deleted=0",
                                             bindings: [.blob(vaultID), .blob(revision)]).first,
              case .blob(let entryID) = old[0], case .text(let hash) = old[1], case .integer(let size) = old[2],
              let entry = try Catalog.entry(db: r.db, vaultID: vaultID, id: entryID) else {
            throw VaultError.notFound(revision.hex)
        }
        let target = try vaultPath(path)
        guard kind(of: target) == entry.kind else { throw VaultError.invalidPath(path) }
        try journal().recover()
        if entry.state == "live" {
            let current = try head(entry.path!, revision: entry.head!)
            try requireFree(target, for: current)
            var restore = plan(current, to: target, hash: hash, size: size)
            restore.origin = "restore"
            try run(restore)
        } else {
            guard try Catalog.live(db: r.db, vaultID: vaultID, path: target) == nil else { throw VaultError.alreadyExists(target) }
            try run(MutationPlan(entry: entryID, kind: entry.kind, base: entry.head, revision: ExternalCapture.identifier(),
                                 parents: entry.head.map { [$0] } ?? [], to: target, toHash: hash, toSize: size, origin: "restore"))
        }
        return try document(target)
    }

    /// Every revision of the document at `path`, oldest first. For a path
    /// with no live document, the history of documents that used it.
    public func history(_ path: String) throws -> [Revision] {
        let r = try requireOpen()
        let path = try vaultPath(path)
        var entries: [Data] = []
        if let live = try Catalog.live(db: r.db, vaultID: vaultID, path: path) {
            entries = [live.id]
        } else {
            let key = try VaultPath(path).portabilityKey
            for row in try r.db.queryValues("SELECT DISTINCT entry_id,path FROM revisions WHERE vault_id=?", bindings: [.blob(vaultID)]) {
                if case .blob(let id) = row[0], case .text(let name) = row[1], (try? VaultPath(name).portabilityKey) == key,
                   !entries.contains(id) { entries.append(id) }
            }
        }
        guard !entries.isEmpty else { throw VaultError.notFound(path) }
        return try entries.flatMap { try Catalog.revisions(db: r.db, vaultID: vaultID, entry: $0) }
    }

    public func createDirectory(_ path: String) throws {
        let path = try vaultPath(path)
        _ = try VaultDirectory(root: requireOpen().reader.root, components: VaultPath(path).components, create: true)
    }

    /// Renames a folder with everything in it as one atomic filesystem step,
    /// then updates links to the moved files (see `move`).
    public func moveDirectory(_ path: String, to newPath: String, updateLinks: Bool = true) throws {
        let source = try vaultPath(path), target = try vaultPath(newPath)
        let sourceKey = try VaultPath(source).portabilityKey, targetKey = try VaultPath(target).portabilityKey
        guard sourceKey != targetKey, !targetKey.hasPrefix(sourceKey + "/") else { throw VaultError.invalidPath(newPath) }
        try journal().recover()
        let root = try requireOpen().reader.root
        guard (try? VaultDirectory(root: root, components: VaultPath(source).components)) != nil else { throw VaultError.notFound(source) }
        guard (try? VaultDirectory(root: root, components: VaultPath(target).components)) == nil,
              try !journal().exactlyExists(target),
              try Catalog.live(db: requireOpen().db, vaultID: vaultID, path: target) == nil,
              try Catalog.liveEntries(db: requireOpen().db, vaultID: vaultID, under: target + "/").isEmpty else {
            throw VaultError.alreadyExists(target)
        }
        let affected = updateLinks ? try linksAffected(byMoving: Catalog.liveEntries(db: requireOpen().db, vaultID: vaultID, under: source + "/")) : []
        try run(MutationPlan(entry: Data(count: 16), kind: "directory", base: nil, revision: Data(count: 16),
                             parents: [], from: source, to: target, origin: "local", directory: true))
        try retarget(affected)
    }

    /// The live document at `path`, including attachments.
    public func document(_ path: String) throws -> IndexedDocument {
        let r = try requireOpen()
        guard let e = try Catalog.live(db: r.db, vaultID: vaultID, path: try vaultPath(path)),
              let head = e.head, let hash = e.hash, let size = e.size else { throw VaultError.notFound(path) }
        let title = try r.db.queryValues("SELECT title FROM document_metadata WHERE vault_id=? AND entry_id=? AND indexed_revision=?",
                                         bindings: [.blob(vaultID), .blob(e.id), .blob(head)]).first
        var text = ""
        if case .text(let value) = title?.first { text = value }
        return IndexedDocument(id: e.id, revisionID: head, path: e.path!, title: text, hash: hash,
                               byteLength: Int(size), kind: e.kind)
    }

    // MARK: Internals shared by local and remote mutations

    func run(_ plan: MutationPlan) throws {
        try journal().recover()
        do {
            try journal().run(plan)
        } catch VaultError.conflict {
            // Another writer changed the file mid-operation. Capture its
            // version so the caller can retry against the true head.
            _ = try? reconcile()
            throw VaultError.conflict(current: try Catalog.entry(db: requireOpen().db, vaultID: vaultID, id: plan.entry)?.head)
        }
    }

    func plan(_ current: CatalogEntry, to path: String?, hash: String?, size: Int64?) -> MutationPlan {
        MutationPlan(entry: current.id, kind: current.kind, base: current.head, revision: ExternalCapture.identifier(),
                     parents: current.head.map { [$0] } ?? [], from: current.path, fromHash: current.hash,
                     fromHint: current.hint, to: path, toHash: hash, toSize: size, origin: "local")
    }

    /// The live entry at `path`, if its head is `revision` and the file on
    /// disk still matches it. A detected external change is captured first
    /// so the conflict reports the true current revision.
    func head(_ path: String, revision: Data) throws -> CatalogEntry {
        try journal().recover()
        let r = try requireOpen()
        let path = try vaultPath(path)
        guard let current = try Catalog.live(db: r.db, vaultID: vaultID, path: path) else { throw VaultError.notFound(path) }
        guard current.head == revision else { throw VaultError.conflict(current: current.head) }
        let (directory, name) = try journal().open(current.path!)
        let info = try directory.info(name)
        if let info, let hint = current.hint, info == hint { return current }
        if info != nil, try directory.digest(name, maximumBytes: Int.max)?.hash == current.hash { return current }
        _ = try? reconcile()
        throw VaultError.conflict(current: try Catalog.live(db: r.db, vaultID: vaultID, path: path)?.head)
    }

    private func requireFree(_ target: String, for current: CatalogEntry) throws {
        let occupant = try Catalog.live(db: requireOpen().db, vaultID: vaultID, path: target)
        guard occupant == nil || occupant?.id == current.id else { throw VaultError.alreadyExists(target) }
    }

    func store(_ content: Data, kind: String) throws -> String {
        guard content.count <= configuration.limit(for: kind) else { throw VaultError.tooLarge }
        if kind == "markdown", String(data: content, encoding: .utf8) == nil {
            throw VaultError.unsupported("Markdown must be valid UTF-8")
        }
        return try requireOpen().objects.put(content)
    }

    func store(contentsOf file: URL, kind: String) throws -> (hash: String, size: Int64) {
        #if canImport(Darwin)
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #else
        let fd = Glibc.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #endif
        guard fd >= 0 else { throw VaultError.notFound(file.path) }
        defer { close(fd) }
        let objects = try requireOpen().objects
        let stored: (hash: String, size: Int64)
        do { stored = try objects.put(from: fd, maximumBytes: configuration.limit(for: kind)) } catch ObjectStoreError.tooLarge { throw VaultError.tooLarge }
        if kind == "markdown", String(data: try objects.get(stored.hash, maximumBytes: configuration.maximumBytes), encoding: .utf8) == nil {
            throw VaultError.unsupported("Markdown must be valid UTF-8")
        }
        return stored
    }

    func kind(of path: String) -> String {
        path.lowercased().hasSuffix(".md") ? "markdown" : "attachment"
    }

    /// Validates a path and adopts the on-disk spelling of existing parent
    /// folders, so case-insensitive volumes never get two spellings.
    func vaultPath(_ path: String) throws -> String {
        guard let parsed = try? VaultPath(path), !parsed.components.contains(where: { $0.hasPrefix(".") }) else {
            throw VaultError.invalidPath(path)
        }
        let root = try requireOpen().reader.root
        var resolved: [String] = []
        for component in parsed.components.dropLast() {
            var spelling = component
            if let directory = try? VaultDirectory(root: root, components: resolved),
               let names = try? directory.names(), !names.contains(component) {
                let key = (try? VaultPath(component).portabilityKey) ?? component
                let matches = names.filter { (try? VaultPath($0).portabilityKey) == key }
                if matches.count == 1 { spelling = matches.first! }
            }
            resolved.append(spelling)
        }
        return (resolved + [parsed.components.last!]).joined(separator: "/")
    }
}
