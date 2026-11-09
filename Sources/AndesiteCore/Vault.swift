import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum VaultOpenError: Error, Equatable {
    case unsafeStateDirectory
    case stateHistoryRequiresMigration
    case identityUnavailable
    case systemCall(String, Int32)
}

/// An open vault: the whole engine as one Swift object.
///
/// ```swift
/// let vault = try Vault(at: "/Users/me/Notes")      // watches and indexes in the background
/// let note = try await vault.create("Ideas.md", "# Ideas\n")
/// try await vault.update("Ideas.md", "# Ideas\n[[Plans]]\n", revision: note.revisionID)
/// let hits = try await vault.search("plans")
/// try vault.close()
/// ```
///
/// Opening a vault starts everything it needs: the folder watcher, the
/// first scan and indexing, recovery snapshots and crash recovery. All of
/// it runs on one thread per vault. Calls from the app run first, ahead of
/// background work; long scans pause between batches to serve them (see
/// `VaultExecutor`). Every method is safe to call from any thread or task.
///
/// For finer control, `Options` sets limits, timing and where state is
/// kept; `startWatching`/`stopWatching`, `refresh`, `startSyncing` and
/// `collectGarbage` manage background work explicitly; and `perform`/`run`
/// give direct access to the underlying `VaultRuntime`.
///
/// State lives outside the vault, in a private directory keyed by the
/// folder's identity, so renaming the folder keeps its history and a copy
/// fails closed. A path-only marker is kept at <vault>/.andesite/vault.json.
public final class Vault: @unchecked Sendable {
    public struct Options: Sendable {
        /// The private directory holding the catalog and stored versions.
        /// Default: derived from the folder's identity under `stateRoot`.
        public var stateDirectory: String?
        /// Default: Application Support (macOS) or ~/.local/share (Linux).
        public var stateRoot: String?
        /// Watch the folder and capture outside edits automatically.
        public var watch: Bool
        public var monitor: VaultMonitorSettings
        /// Largest Markdown note (notes are parsed in memory).
        public var maximumNoteBytes: Int
        /// Largest attachment (attachments are streamed).
        public var maximumFileBytes: Int
        /// Receives one line per background event: scans, failures, sync.
        public var report: @Sendable (String) -> Void
        /// Receives typed index events from the watcher (see `VaultEvent`).
        public var onEvent: @Sendable (VaultEvent) -> Void

        public init(stateDirectory: String? = nil, stateRoot: String? = nil, watch: Bool = true,
                    monitor: VaultMonitorSettings = VaultMonitorSettings(),
                    maximumNoteBytes: Int = 16 * 1024 * 1024, maximumFileBytes: Int = 4 * 1024 * 1024 * 1024,
                    report: @escaping @Sendable (String) -> Void = { _ in },
                    onEvent: @escaping @Sendable (VaultEvent) -> Void = { _ in }) {
            self.stateDirectory = stateDirectory; self.stateRoot = stateRoot; self.watch = watch
            self.monitor = monitor; self.maximumNoteBytes = maximumNoteBytes
            self.maximumFileBytes = maximumFileBytes; self.report = report
            self.onEvent = onEvent
        }
    }

    public let directory: String
    public let stateDirectory: String
    private let executor: VaultExecutor
    private let lock = NSLock()
    private var syncing: Task<Void, Never>?
    private var closed = false

    public static var defaultStateRoot: String {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/Andesite/States"
        #elseif canImport(Darwin)
        // iOS: the app's own container, never its user-visible Documents.
        return appContainer + "/Library/Application Support/Andesite/States"
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.local/share/Andesite/States"
        #endif
    }

    /// Pure path resolution: no SQLite, filesystem writes or scanning. The
    /// key is the directory's identity (device, inode and, on macOS, birth
    /// time) so a recycled inode number cannot inherit another Vault's state.
    public static func plannedStateDirectory(vaultDirectory: String,
                                             stateRoot: String? = nil) throws -> String {
        _ = try VaultPathRegistry(vaultDirectory: vaultDirectory)
        var info = stat()
        guard lstat(vaultDirectory, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw VaultOpenError.identityUnavailable
        }
        #if canImport(Darwin)
        guard info.st_birthtimespec.tv_sec > 0 else { throw VaultOpenError.identityUnavailable }
        let identity = "vault-state-v1:\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
        #else
        // Linux exposes no portable birth time; device and inode identify the
        // directory (a recycled inode could inherit state; pass --state to pin it).
        let identity = "vault-state-v1:\(info.st_dev):\(info.st_ino)"
        #endif
        let base = stateRoot ?? defaultStateRoot
        guard base.hasPrefix("/"), base != "/", !base.hasSuffix("/"),
              !base.contains("//"), !base.contains("\0"), !base.contains("\\"),
              !base.dropFirst().split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw VaultOpenError.unsafeStateDirectory
        }
        return base + "/v1-" + ObjectStore.hash(Data(identity.utf8))
    }

    /// Opens (or first registers) the vault at `directory`, an absolute
    /// path. Opening recovers interrupted changes. Only opening creates
    /// state; a moved vault without state at its identity is refused, since
    /// it may be a copy with stale history.
    public init(at directory: String, options: Options = Options()) throws {
        let marker = try VaultPathRegistry(vaultDirectory: directory)
        let old = try marker.storedPath()
        let state: String
        if let explicit = options.stateDirectory {
            state = explicit
        } else {
            state = try Self.plannedStateDirectory(vaultDirectory: directory, stateRoot: options.stateRoot)
            if let old, old != directory,
               !FileManager.default.fileExists(atPath: state + "/catalog.sqlite") {
                throw VaultOpenError.stateHistoryRequiresMigration
            }
            try Self.createPrivateStateDirectory(state)
        }
        let runtime = try VaultRuntime(configuration: VaultConfiguration(
            vaultDirectory: directory, stateDirectory: state,
            maximumBytes: options.maximumNoteBytes, maximumFileBytes: options.maximumFileBytes))
        try marker.register()
        self.directory = directory
        self.stateDirectory = state
        executor = VaultExecutor(runtime: runtime)
        if options.watch { try startWatching(settings: options.monitor, report: options.report, onEvent: options.onEvent) }
    }

    public convenience init(at url: URL, options: Options = Options()) throws {
        try self.init(at: url.path, options: options)
    }

    deinit { try? close() }

    /// Stops background work, flushes due snapshots and releases the state
    /// lock. Waits for the call in progress; queued calls fail with `closed`.
    public func close() throws {
        let (wasClosed, task) = lock.withLock {
            defer { syncing = nil; closed = true }
            return (closed, syncing)
        }
        guard !wasClosed else { return }
        task?.cancel()
        try executor.close { try $0.shutdown() }
    }

    // MARK: Direct access

    /// Runs `body` on the vault's thread and returns its result. `work`
    /// sets its priority; a `.read` body must not change anything.
    public func perform<T: Sendable>(_ work: VaultWork = .write,
                                     _ body: @escaping @Sendable (VaultRuntime) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            executor.submit(work, body) { continuation.resume(with: $0) }
        }
    }

    /// Like `perform`, but blocks the calling thread. Never call it from
    /// inside another vault call.
    public func run<T>(_ work: VaultWork = .write, _ body: (VaultRuntime) throws -> T) throws -> T {
        try executor.run(work, body)
    }

    // MARK: Documents (paths are vault-relative, like "Folder/Note.md")

    public func status() async throws -> VaultStatus { try await perform(.read) { try $0.status() } }

    /// The live document at `path` (notes and attachments).
    public func document(_ path: String) async throws -> IndexedDocument {
        try await perform(.read) { try $0.document(path) }
    }

    /// The current document and its bytes (up to the note size limit).
    public func read(_ path: String) async throws -> (document: IndexedDocument, content: Data) {
        try await perform(.read) { try $0.read(path) }
    }

    /// Creates a file; fails if anything (or a case variant) exists there.
    @discardableResult
    public func create(_ path: String, _ content: Data) async throws -> IndexedDocument {
        try await perform { try $0.create(path, content) }
    }

    @discardableResult
    public func create(_ path: String, _ text: String) async throws -> IndexedDocument {
        try await create(path, Data(text.utf8))
    }

    /// Creates a file from a local file, streamed (for large attachments).
    @discardableResult
    public func create(_ path: String, contentsOf file: URL) async throws -> IndexedDocument {
        try await perform { try $0.create(path, contentsOf: file) }
    }

    /// Replaces the content if `revision` is still the current one;
    /// otherwise throws `VaultError.conflict` with the current revision.
    @discardableResult
    public func update(_ path: String, _ content: Data, revision: Data) async throws -> IndexedDocument {
        try await perform { try $0.update(path, content, revision: revision) }
    }

    @discardableResult
    public func update(_ path: String, _ text: String, revision: Data) async throws -> IndexedDocument {
        try await update(path, Data(text.utf8), revision: revision)
    }

    @discardableResult
    public func update(_ path: String, contentsOf file: URL, revision: Data) async throws -> IndexedDocument {
        try await perform { try $0.update(path, contentsOf: file, revision: revision) }
    }

    /// Renames or moves a file; links that point to it are rewritten.
    @discardableResult
    public func move(_ path: String, to newPath: String, revision: Data, updateLinks: Bool = true) async throws -> IndexedDocument {
        try await perform { try $0.move(path, to: newPath, revision: revision, updateLinks: updateLinks) }
    }

    public func delete(_ path: String, revision: Data) async throws {
        try await perform { try $0.delete(path, revision: revision) }
    }

    /// Makes an earlier revision current again (also undeletes).
    @discardableResult
    public func restore(_ path: String, revision: Data) async throws -> IndexedDocument {
        try await perform { try $0.restore(path, revision: revision) }
    }

    public func history(_ path: String) async throws -> [Revision] {
        try await perform(.read) { try $0.history(path) }
    }

    public func createDirectory(_ path: String) async throws {
        try await perform { try $0.createDirectory(path) }
    }

    public func moveDirectory(_ path: String, to newPath: String, updateLinks: Bool = true) async throws {
        try await perform { try $0.moveDirectory(path, to: newPath, updateLinks: updateLinks) }
    }

    // MARK: Index (throws `VaultRuntimeError.indexNotReady` until the first scan ends)

    public func documents(limit: Int = 50, offset: Int = 0, filter: ObsidianFilter? = nil) async throws -> DocumentPage {
        try await perform(.read) { try $0.documents(limit: limit, offset: offset, filter: filter) }
    }

    public func search(_ text: String, limit: Int = 50, filter: ObsidianFilter? = nil) async throws -> [SearchIndexHit] {
        try await perform(.read) { try $0.search(text, limit: limit, filter: filter) }
    }

    public func tags(limit: Int = 50, offset: Int = 0) async throws -> TagPage {
        try await perform(.read) { try $0.tags(limit: limit, offset: offset) }
    }

    public func properties(limit: Int = 50, offset: Int = 0) async throws -> PropertyPage {
        try await perform(.read) { try $0.properties(limit: limit, offset: offset) }
    }

    public func metadata(_ path: String) async throws -> NoteMetadata {
        try await perform(.read) { try $0.documentMetadata($0.document(path).id) }
    }

    /// Outgoing links, or with `.incoming` the backlinks. With `excerpts`,
    /// each mention also carries its line in the source and that line's text.
    public func links(_ path: String, direction: VaultLinkDirection = .outgoing,
                      limit: Int = 50, offset: Int = 0, excerpts: Bool = false) async throws -> VaultLinkPage {
        try await perform(.read) {
            try $0.links($0.document(path).id, direction: direction, limit: limit, offset: offset, excerpts: excerpts)
        }
    }

    public func unlinkedMentions(_ path: String, limit: Int = 50) async throws -> [UnlinkedMention] {
        try await perform(.read) { try $0.unlinkedMentions($0.document(path).id, limit: limit) }
    }

    /// Sets (or with nil removes) one frontmatter property.
    @discardableResult
    public func setProperty(_ path: String, _ name: String, to value: PropertyValue?, revision: Data) async throws -> IndexedDocument {
        try await perform { try $0.setProperty(path, name, to: value, revision: revision) }
    }

    @discardableResult
    public func addTag(_ path: String, _ tag: String, revision: Data) async throws -> IndexedDocument {
        try await perform { try $0.addTag(path, tag, revision: revision) }
    }

    @discardableResult
    public func removeTag(_ path: String, _ tag: String, revision: Data) async throws -> IndexedDocument {
        try await perform { try $0.removeTag(path, tag, revision: revision) }
    }

    // MARK: Snapshots

    public func snapshots(path: String? = nil) async throws -> [RecoverySnapshot] {
        try await perform(.read) { try $0.snapshots(path: path) }
    }

    public func snapshotContents(_ id: Data) async throws -> Data {
        try await perform(.read) { try $0.snapshotContents(id) }
    }

    public func configureSnapshots(_ policy: SnapshotPolicy) async throws {
        try await perform { try $0.configureSnapshots(policy) }
    }

    // MARK: Background work

    /// Scans the folder now and captures outside edits. The watcher does
    /// this automatically; call it to wait until the index is current.
    @discardableResult
    public func refresh() async throws -> ReconciliationReport {
        try await perform(.background) { try $0.reconcile() }
    }

    public func collectGarbage(minimumAge: TimeInterval = 7 * 86_400) async throws -> GarbageReport {
        try await perform(.background) { try $0.collectGarbage(minimumAge: minimumAge) }
    }

    /// Starts watching the folder (done by `init` unless `Options.watch`
    /// is false): an initial scan, then filesystem events, periodic
    /// rescans and snapshot promotion, all as background work.
    public func startWatching(settings: VaultMonitorSettings = VaultMonitorSettings(),
                              report: @escaping @Sendable (String) -> Void = { _ in },
                              onEvent: @escaping @Sendable (VaultEvent) -> Void = { _ in }) throws {
        let watcher = try VaultWatcher(vaultDirectory: directory, settings: settings, report: report, onEvent: onEvent)
        try run { [executor] _ in executor.setWatcher(watcher) }
    }

    public func stopWatching() throws {
        try run { [executor] _ in executor.setWatcher(nil) }
    }

    /// One two-way sync with a server (`andesite-server serve`). Requires
    /// HTTPS unless the server is on this machine.
    /// `vault` names one vault of a server hosting several (`serve-all`).
    public func sync(with server: URL, token: String, vault: String? = nil) async throws -> SyncReport {
        try await SyncClient(destination: server, token: token, vault: vault).sync(self)
    }

    /// Syncs now and then every `interval` seconds until `stopSyncing` or
    /// `close`. Failures (for example while offline) are reported and retried.
    public func startSyncing(with server: URL, token: String, every interval: TimeInterval,
                             report: @escaping @Sendable (Result<SyncReport, Error>) -> Void = { _ in }) throws {
        let client = try SyncClient(destination: server, token: token)
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let vault = self else { return }
                do { report(.success(try await client.sync(vault))) } catch { report(.failure(error)) }
                try? await Task.sleep(nanoseconds: UInt64(max(interval, 1) * 1_000_000_000))
            }
        }
        let previous: Task<Void, Never>? = lock.withLock {
            defer { syncing = closed ? nil : task }
            return closed ? task : syncing
        }
        previous?.cancel()
    }

    public func stopSyncing() {
        lock.withLock { () -> Task<Void, Never>? in defer { syncing = nil }; return syncing }?.cancel()
    }

    private static func createPrivateStateDirectory(_ path: String) throws {
        var prefix = ""
        let parts = path.split(separator: "/")
        for (index, component) in parts.enumerated() {
            prefix += "/" + component
            var info = stat()
            if lstat(prefix, &info) != 0 {
                guard errno == ENOENT else { throw VaultOpenError.unsafeStateDirectory }
                guard mkdir(prefix, 0o700) == 0 || errno == EEXIST else {
                    throw VaultOpenError.systemCall("create state directory", errno)
                }
                guard lstat(prefix, &info) == 0 else {
                    throw VaultOpenError.unsafeStateDirectory
                }
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw VaultOpenError.unsafeStateDirectory
            }
            guard info.st_mode & 0o022 == 0 || info.st_mode & mode_t(S_ISVTX) != 0
                    || isAboveAppContainer(prefix) else {
                throw VaultOpenError.unsafeStateDirectory
            }
            // Both root and per-vault state are exclusively owner accessible.
            if index + 1 >= parts.count - 1 {
                guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
                    throw VaultOpenError.unsafeStateDirectory
                }
            }
        }
    }
}

/// On iOS the sandbox, not Unix modes, keeps other apps out of this
/// app's container, and the folders above it belong to the system (in
/// the Simulator, to the Mac's user, some group-writable). Only folders
/// inside the container are held to the ownership rules.
func isAboveAppContainer(_ path: String) -> Bool {
    #if os(macOS) || !canImport(Darwin)
    return false
    #else
    let home = appContainer
    return home == path || home.hasPrefix(path + "/")
    #endif
}

#if !os(macOS) && canImport(Darwin)
/// The app's container without symlinks. On a device it is under /var, a
/// symlink to /private/var, and paths through a symlink are refused.
let appContainer: String = {
    let home = NSHomeDirectory()
    guard let resolved = realpath(home, nil) else { return home }
    defer { free(resolved) }
    return String(cString: resolved)
}()
#endif
