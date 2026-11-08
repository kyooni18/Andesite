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

/// An open Vault and the one serial queue that owns it.
///
/// Every backend call runs on that queue: `run` blocks the caller,
/// `perform` suspends it. Watching, HTTP requests and sync work interleave
/// on the queue between calls, so there is exactly one SQLite owner and
/// networking never runs on it.
///
/// A path-only marker is kept at <vault>/.andesite/vault.json. Backend state
/// lives outside the Vault, keyed by the directory's physical identity, so
/// same-volume renames keep their history and copies fail closed.
public final class VaultSession: @unchecked Sendable {
    public let vaultDirectory: String
    public let stateDirectory: String
    private let queue = DispatchQueue(label: "andesite.vault")
    // Accessed only on `queue`.
    private var owner: VaultRuntime?
    private var watcher: VaultWatcher?
    private var timer: DispatchSourceTimer?

    public static var defaultStateRoot: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #if os(macOS)
        return home + "/Library/Application Support/Andesite/States"
        #else
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
            throw VaultSessionError.identityUnavailable
        }
        #if os(macOS)
        guard info.st_birthtimespec.tv_sec > 0 else { throw VaultSessionError.identityUnavailable }
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
            throw VaultSessionError.unsafeStateDirectory
        }
        return base + "/v1-" + ObjectStore.hash(Data(identity.utf8))
    }

    /// Opening is the only step allowed to create state. An explicit state
    /// directory reuses existing storage. A moved Vault without state at its
    /// computed identity is refused: it may be a copy with stale history.
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
        let runtime = try VaultRuntime(configuration: VaultConfiguration(
            vaultDirectory: vaultDirectory, stateDirectory: state))
        try marker.register()
        self.vaultDirectory = vaultDirectory
        self.stateDirectory = state
        self.owner = runtime
    }

    /// Runs `body` on the owner queue and waits for its result. Never call
    /// it from inside another `run` or `perform` body.
    public func run<T>(_ body: (AndesiteBackend) throws -> T) throws -> T {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return try queue.sync {
            guard let owner else { throw VaultSessionError.closed }
            return try body(owner)
        }
    }

    /// Runs `body` on the owner queue without blocking the calling thread.
    public func perform<T: Sendable>(_ body: @escaping @Sendable (AndesiteBackend) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let owner = self.owner else { return continuation.resume(throwing: VaultSessionError.closed) }
                continuation.resume(with: Result { try body(owner) })
            }
        }
    }

    @discardableResult
    public func reconcile() throws -> ReconciliationReport { try run { try $0.reconcile() } }

    /// Starts monitoring the Vault: an initial scan, then filesystem events
    /// and periodic rescans, all as short jobs on the owner queue.
    public func startWatching(settings: VaultMonitorSettings = VaultMonitorSettings(),
                              report: @escaping @Sendable (String) -> Void = { _ in }) throws {
        try run { owner in
            guard self.timer == nil else { return }
            let watcher = try VaultWatcher(runtime: owner, vaultDirectory: self.vaultDirectory,
                                           settings: settings, report: report)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + settings.polling, repeating: settings.polling)
            timer.setEventHandler { [weak self] in self?.watcher?.tick() }
            self.watcher = watcher
            self.timer = timer
            timer.resume()
        }
    }

    /// Stops watching, flushes due snapshots and releases the state lock.
    public func close() throws {
        dispatchPrecondition(condition: .notOnQueue(queue))
        try queue.sync {
            timer?.cancel()
            timer = nil
            watcher = nil
            guard let owner else { return }
            defer { self.owner = nil }
            try owner.shutdown()
        }
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
