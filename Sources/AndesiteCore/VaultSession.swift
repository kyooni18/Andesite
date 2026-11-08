import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum VaultSessionError: Error, Equatable {
    case unsafeStateDirectory
    case stateHistoryRequiresMigration
    case identityUnavailable
    case closed
    case systemCall(String, Int32)
}

/// Opening a selected Vault connects the existing backend explicitly.
/// Merely registering the path never scans notes or initializes SQLite.
///
/// A path-only marker remains at <vault>/.andesite/vault.json. Backend state
/// stays outside the Vault, keyed by physical directory identity rather
/// than its pathname. Same-volume renames reuse the same catalog; copies to
/// another volume cannot be assumed to be identical and fail closed.
public final class VaultSession {
    public let vaultDirectory: String
    public let stateDirectory: String
    private let marker: VaultPathRegistry
    private var owner: VaultRuntime?

    public var runtime: VaultRuntime {
        get throws {
            guard let owner else { throw VaultSessionError.closed }
            return owner
        }
    }

    /// In-process, transport-free backend facade for an embedded app.
    /// It shares the session's single owner and cannot outlive the session.
    public var backend: AndesiteBackend {
        get throws { try runtime }
    }

    public static var defaultStateRoot: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #if os(macOS)
        return home + "/Library/Application Support/Andesite/States"
        #else
        return home + "/.local/share/Andesite/States"
        #endif
    }

    /// Pure path resolution: no SQLite, filesystem writes or scanner.
    /// Require directory birth time on macOS to avoid accidental reuse of a
    /// previous Vault's state after its inode number is recycled.
    public static func plannedStateDirectory(vaultDirectory: String,
                                             stateRoot: String? = nil) throws -> String {
        _ = try VaultPathRegistry(vaultDirectory: vaultDirectory)
        var info = stat()
        guard lstat(vaultDirectory, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw VaultSessionError.identityUnavailable
        }
        #if os(macOS)
        guard info.st_birthtimespec.tv_sec > 0 else { throw VaultSessionError.identityUnavailable }
        let identity = "vault-state-v1:\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
        let key = ObjectStore.hash(Data(identity.utf8))
        let base = stateRoot ?? defaultStateRoot
        guard base.hasPrefix("/"), base != "/", !base.hasSuffix("/"),
              !base.contains("//"), !base.contains("\0"), !base.contains("\\"),
              !base.dropFirst().split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw VaultSessionError.unsafeStateDirectory
        }
        return base + "/v1-" + key
        #else
        throw VaultSessionError.identityUnavailable
        #endif
    }

    /// Opening is the only step allowed to create state. Passing an explicit
    /// state directory reuses the old manual CLI storage rather than starting
    /// a fresh history in the automatic location.
    ///
    /// If a moved Vault has no state at its computed identity, refuse a new
    /// empty index: it may have been copied to another disk with old history.
    public init(vaultDirectory: String, stateRoot: String? = nil,
                stateDirectory explicitState: String? = nil) throws {
        let marker = try VaultPathRegistry(vaultDirectory: vaultDirectory)
        let old = try marker.storedPath()
        let state: String
        if let explicitState {
            state = explicitState
        } else {
            state = try Self.plannedStateDirectory(vaultDirectory: vaultDirectory, stateRoot: stateRoot)
            if let old, old != vaultDirectory,
               !FileManager.default.fileExists(atPath: state + "/catalog.sqlite") {
                throw VaultSessionError.stateHistoryRequiresMigration
            }
            try Self.createPrivateStateDirectory(state)
        }
        let backend = try VaultRuntime(configuration: VaultConfiguration(
            vaultDirectory: vaultDirectory, stateDirectory: state))
        // Identity and any same-volume rebind have succeeded. Only now
        // update the marker; its contents remain the single absolute path.
        try marker.register()
        self.vaultDirectory = vaultDirectory
        self.stateDirectory = state
        self.marker = marker
        self.owner = backend
    }

    @discardableResult
    public func reconcile() throws -> ReconciliationReport {
        try runtime.reconcile()
    }

    #if os(macOS)
    /// One synchronous owner handles the watcher and same-user HTTP reads.
    /// The caller closes this session to flush snapshots and release locks.
    public func watch(shouldStop: () -> Bool = { VaultMonitor.stopRequested },
                      report: (String) -> Void = { _ in }) throws {
        let backend = try runtime
        let monitor = try VaultMonitor(runtime: backend, vaultDirectory: vaultDirectory)
        let api = try VaultLocalHTTP(runtime: backend, stateDirectory: stateDirectory)
        report("vault-api socket=\(api.socketPath) transport=unix-http access=same-user")
        try monitor.run(shouldStop: shouldStop, onIdle: { ready in
            try api.poll(indexReady: ready)
        }, report: report)
    }
    #endif

    public func close() throws {
        guard let backend = owner else { return }
        defer { owner = nil }
        try backend.shutdown()
    }

    private static func createPrivateStateDirectory(_ path: String) throws {
        var prefix = ""
        let parts = path.split(separator: "/")
        for (index, component) in parts.enumerated() {
            prefix += "/" + component
            var info = stat()
            if lstat(prefix, &info) != 0 {
                guard errno == ENOENT else { throw VaultSessionError.unsafeStateDirectory }
                guard mkdir(prefix, 0o700) == 0 || errno == EEXIST else {
                    throw VaultSessionError.systemCall("create state directory", errno)
                }
                guard lstat(prefix, &info) == 0 else {
                    throw VaultSessionError.unsafeStateDirectory
                }
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  (info.st_mode & 0o022 == 0 || info.st_mode & mode_t(S_ISVTX) != 0) else {
                throw VaultSessionError.unsafeStateDirectory
            }
            // Both root and per-vault state are exclusively owner accessible.
            if index + 1 >= parts.count - 1 {
                guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
                    throw VaultSessionError.unsafeStateDirectory
                }
            }
        }
    }
}
