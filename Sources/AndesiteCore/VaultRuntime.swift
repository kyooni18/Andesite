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
    case unsupportedRemovalOrRename(String)
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
}

public struct VaultStatus: Sendable {
    public let vaultID: Data
    public let state: String
    public let entries: Int
    public let revisions: Int
    public let openIncidents: Int
}

/// Synchronous, deliberately non-Sendable owner. Use on one blocking executor;
/// no database/reader/store escapes. shutdown closes the connection before lock release.
public final class VaultRuntime {
    private struct Resources {
        let db: SQLiteConnection
        let reader: VaultReader
        let objects: ObjectStore
    }
    private var resources: Resources?
    private var processLock: ProcessLock?
    private let configuration: VaultConfiguration
    public let vaultID: Data

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
            guard rows.count == 1, rows[0].count == 2, case .blob(let existing) = rows[0][0], rows[0][1] == .text(rootIdentity) else { throw VaultRuntimeError.identityMismatch }
            id = existing
        }
        self.configuration = c
        self.vaultID = id
        self.processLock = lock
        self.resources = Resources(db: db, reader: reader, objects: objects)
        try setState("scanRequired")
        try verifyObjects()
        let directory = open(state, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw VaultRuntimeError.unsafeState }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw VaultRuntimeError.unsafeState }
    }

    public func shutdown() {
        resources = nil
        processLock = nil
    }

    deinit { shutdown() }

    public func status() throws -> VaultStatus {
        guard let r = resources else { throw VaultRuntimeError.closed }
        func count(_ table: String, _ suffix: String = "") throws -> Int {
            Int(try r.db.scalarText("SELECT count(*) FROM \(table) \(suffix)") ?? "") ?? 0
        }
        return try VaultStatus(vaultID: vaultID, state: r.db.scalarText("SELECT state FROM vaults") ?? "unknown", entries: count("entries"), revisions: count("revisions"), openIncidents: count("incidents", "WHERE status='open'"))
    }

    /// Search refreshes canonical files first; failed/partial scans never expose
    /// the previous index as current. A result is an observation, not a live FS snapshot.
    public func search(_ phrase: String, limit: Int = 50) throws -> [SearchIndexHit] {
        _ = try reconcile()
        guard let r = resources else { throw VaultRuntimeError.closed }
        return try SearchIndex.search(db: r.db, vaultID: vaultID, phrase: phrase, limit: limit)
    }

    public func reconcile() throws -> ReconciliationReport {
        guard let r = resources else { throw VaultRuntimeError.closed }
        try setState("scanning")
        do {
            try verifyObjects()
            let paths = try r.reader.markdownPaths()
            var keys: [String: String] = [:]
            for path in paths {
                let spelling = path.components.joined(separator: "/")
                guard keys.updateValue(spelling, forKey: path.portabilityKey) == nil else { throw VaultRuntimeError.portabilityCollision(spelling) }
            }
            for row in try r.db.queryValues("SELECT path,path_key FROM entries WHERE state='live'") {
                guard case .text(let name) = row[0], case .text(let key) = row[1] else { throw VaultRuntimeError.inconsistentCatalog }
                guard let observed = keys[key] else { throw VaultRuntimeError.unsupportedRemovalOrRename(name) }
                // Compare UTF-8 rather than Swift's canonically equivalent String equality.
                guard Array(observed.utf8) == Array(name.utf8) else { throw VaultRuntimeError.portabilityCollision(name) }
            }
            var report = ReconciliationReport()
            report.discovered = paths.count
            for path in paths {
                do {
                    let captured = try ExternalCapture.capture(db: r.db, reader: r.reader, objects: r.objects, vaultID: vaultID, path: path, maximumBytes: configuration.maximumBytes, debounce: configuration.debounce)
                    // Index only verified immutable bytes, never a second mutable-file read.
                    let bytes = try r.objects.get(captured.contentHash, maximumBytes: configuration.maximumBytes)
                    try SearchIndex.index(db: r.db, vaultID: vaultID, entryID: captured.entryID, revisionID: captured.revisionID, bytes: bytes)
                    if captured.sequence == nil { report.unchanged += 1 } else { report.revisionsCreated += 1 }
                } catch ExternalCaptureError.invalidMarkdown { report.invalidMarkdown += 1 }
            }
            // Catch namespace changes during ingestion. No deletion inference, ever.
            let after = try r.reader.markdownPaths()
            guard after.map({ Array($0.components.joined(separator: "/").utf8) }) == paths.map({ Array($0.components.joined(separator: "/").utf8) }) else { throw VaultReadError.unstable }
            try setState(report.invalidMarkdown == 0 ? "ready" : "quarantined")
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
              try r.db.queryValues("SELECT 1 FROM entries e LEFT JOIN revisions r ON r.vault_id=e.vault_id AND r.entry_id=e.id AND r.revision_id=e.head_revision WHERE e.state='live' AND (r.revision_id IS NULL OR r.deleted!=0) LIMIT 1").isEmpty else { throw VaultRuntimeError.inconsistentCatalog }
        for row in try r.db.queryValues("SELECT lower(hex(hash)),length,durable_location FROM objects") {
            guard case .text(let hash) = row[0], case .integer(let length) = row[1], row[2] == .text(hash), length >= 0, length <= Int.max else { throw VaultRuntimeError.inconsistentCatalog }
            let bytes = try r.objects.get(hash, maximumBytes: Int(length))
            guard bytes.count == Int(length) else { throw VaultRuntimeError.inconsistentCatalog }
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
