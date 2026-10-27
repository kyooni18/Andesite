import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum VaultReadError: Error, Equatable {
    case invalidPath
    case systemCall(String, Int32)
    case unsafeFile
    case tooLarge
    case unstable
}

/// Validates the wire spelling of a vault-relative path. This does not establish
/// namespace uniqueness; that requires a catalog-wide portability-key check.
public struct VaultPath: Sendable, Equatable {
    public let components: [String]
    public init(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw VaultReadError.invalidPath
        }
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw VaultReadError.invalidPath
        }
        components = pieces
    }
}

private struct Fingerprint: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanos: Int64
    let changeSeconds: Int64
    let changeNanos: Int64

    init(_ s: stat) {
        device = UInt64(s.st_dev); inode = UInt64(s.st_ino); size = Int64(s.st_size)
        #if canImport(Darwin)
        modificationSeconds = Int64(s.st_mtimespec.tv_sec); modificationNanos = Int64(s.st_mtimespec.tv_nsec)
        changeSeconds = Int64(s.st_ctimespec.tv_sec); changeNanos = Int64(s.st_ctimespec.tv_nsec)
        #else
        modificationSeconds = Int64(s.st_mtim.tv_sec); modificationNanos = Int64(s.st_mtim.tv_nsec)
        changeSeconds = Int64(s.st_ctim.tv_sec); changeNanos = Int64(s.st_ctim.tv_nsec)
        #endif
    }
}

/// Synchronous descriptor-relative observation. Run on a bounded blocking
/// executor, never an NIO event loop. This is a building block, not a watcher,
/// catalog publication, durable capture, or proof that an editor has finished.
public final class VaultReader {
    private let root: Int32
    private let rootDevice: UInt64

    public init(rootPath: String) throws {
        let fd = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw VaultReadError.systemCall("open root", errno) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = errno; close(fd); throw VaultReadError.systemCall("stat root", error)
        }
        root = fd
        rootDevice = UInt64(info.st_dev)
    }
    deinit { close(root) }

    /// Requires two matching byte and metadata observations separated by the
    /// caller-specified debounce. Even matching observations cannot rule out
    /// unobserved writes or a writer paused between edits.
    public func readStable(_ path: VaultPath, maximumBytes: Int, debounce: TimeInterval = 0.25) throws -> Data {
        guard maximumBytes >= 0, debounce >= 0, debounce.isFinite else { throw VaultReadError.invalidPath }
        return try readStable(path, maximumBytes: maximumBytes, betweenObservations: {
            Thread.sleep(forTimeInterval: debounce)
        })
    }

    // Internal seam for deterministic race tests. The caller must still run
    // this synchronous function on a blocking executor.
    func readStable(_ path: VaultPath, maximumBytes: Int, betweenObservations: () throws -> Void) throws -> Data {
        let first = try observe(path, maximumBytes: maximumBytes)
        try betweenObservations()
        let second = try observe(path, maximumBytes: maximumBytes)
        guard first.0 == second.0, first.1 == second.1 else { throw VaultReadError.unstable }
        return second.1
    }

    private func observe(_ path: VaultPath, maximumBytes: Int) throws -> (Fingerprint, Data) {
        var directory = dup(root)
        guard directory >= 0 else { throw VaultReadError.systemCall("dup root", errno) }
        defer { close(directory) }
        for component in path.components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw VaultReadError.systemCall("open directory", errno) }
            var info = stat()
            guard fstat(next, &info) == 0 else {
                let error = errno; close(next); throw VaultReadError.systemCall("stat directory", error)
            }
            guard UInt64(info.st_dev) == rootDevice else { close(next); throw VaultReadError.unsafeFile }
            close(directory); directory = next
        }
        let name = path.components.last!
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw VaultReadError.systemCall("open file", errno) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw VaultReadError.systemCall("stat file", errno) }
        guard (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), before.st_nlink == 1,
              UInt64(before.st_dev) == rootDevice else { throw VaultReadError.unsafeFile }
        guard before.st_size >= 0, before.st_size <= maximumBytes else { throw VaultReadError.tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw VaultReadError.systemCall("read file", errno)
            }
            if n == 0 { break }
            guard n <= maximumBytes - data.count else { throw VaultReadError.tooLarge }
            data.append(contentsOf: buffer[0..<n])
        }
        var after = stat(), atPath = stat()
        guard fstat(fd, &after) == 0 else { throw VaultReadError.systemCall("restat file", errno) }
        guard fstatat(directory, name, &atPath, AT_SYMLINK_NOFOLLOW) == 0 else { throw VaultReadError.unstable }
        guard (atPath.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), atPath.st_nlink == 1,
              Fingerprint(before) == Fingerprint(after), Fingerprint(after) == Fingerprint(atPath),
              data.count == after.st_size else { throw VaultReadError.unstable }
        return (Fingerprint(after), data)
    }
}
