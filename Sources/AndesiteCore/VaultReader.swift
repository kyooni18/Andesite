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

    public var portabilityKey: String {
        components.joined(separator: "/").precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}

public struct FileFingerprint: Equatable, Sendable, Codable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modificationSeconds: Int64
    public let modificationNanos: Int64
    public let changeSeconds: Int64
    public let changeNanos: Int64
    // Optional for compatibility with v3/v4 hints. Device/inode alone is not
    // sufficient for cross-path identity: inodes can be reused.
    public let birthSeconds: Int64?
    public let birthNanos: Int64?

    init(_ s: stat) {
        device = UInt64(s.st_dev); inode = UInt64(s.st_ino); size = Int64(s.st_size)
        #if canImport(Darwin)
        modificationSeconds = Int64(s.st_mtimespec.tv_sec); modificationNanos = Int64(s.st_mtimespec.tv_nsec)
        changeSeconds = Int64(s.st_ctimespec.tv_sec); changeNanos = Int64(s.st_ctimespec.tv_nsec)
        birthSeconds = Int64(s.st_birthtimespec.tv_sec); birthNanos = Int64(s.st_birthtimespec.tv_nsec)
        #else
        modificationSeconds = Int64(s.st_mtim.tv_sec); modificationNanos = Int64(s.st_mtim.tv_nsec)
        changeSeconds = Int64(s.st_ctim.tv_sec); changeNanos = Int64(s.st_ctim.tv_nsec)
        birthSeconds = nil; birthNanos = nil
        #endif
    }

    var renameIdentity: String? {
        guard let birthSeconds, let birthNanos, birthSeconds != 0 || birthNanos != 0 else { return nil }
        return "\(device):\(inode):\(birthSeconds):\(birthNanos)"
    }
}

public struct ScannedMarkdownFile: Sendable {
    public let path: VaultPath
    public let fingerprint: FileFingerprint
}

public struct ObservedFile: Sendable {
    public let fingerprint: FileFingerprint
    public let bytes: Data
}

/// Synchronous descriptor-relative observation. Run on a bounded blocking
/// executor, never an NIO event loop. This is a building block, not a watcher,
/// catalog publication, durable capture, or proof that an editor has finished.
public final class VaultReader {
    private let root: Int32
    private let rootDevice: UInt64
    private let rootInode: UInt64
    private let rootPath: String

    public init(rootPath: String) throws {
        let fd = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw VaultReadError.systemCall("open root", errno) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = errno; close(fd); throw VaultReadError.systemCall("stat root", error)
        }
        root = fd
        rootDevice = UInt64(info.st_dev)
        rootInode = UInt64(info.st_ino)
        self.rootPath = rootPath
    }
    deinit { close(root) }

    private func verifyRoot() throws {
        var info = stat()
        guard lstat(rootPath, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              UInt64(info.st_dev) == rootDevice, UInt64(info.st_ino) == rootInode else { throw VaultReadError.unstable }
    }

    /// A failed enumeration never returns a partial listing.
    public func markdownPaths() throws -> [VaultPath] {
        try markdownFiles().map(\.path)
    }

    public func markdownFiles() throws -> [ScannedMarkdownFile] {
        try verifyRoot()
        var paths: [ScannedMarkdownFile] = []
        var namespace = Set<String>()
        func visit(_ fd: Int32, _ prefix: String) throws {
            let copy = dup(fd)
            guard copy >= 0 else { throw VaultReadError.systemCall("dup scan", errno) }
            guard let stream = fdopendir(copy) else { close(copy); throw VaultReadError.systemCall("open scan", errno) }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let item = readdir(stream) else {
                    guard errno == 0 else { throw VaultReadError.systemCall("read directory", errno) }
                    break
                }
                let name: String? = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(validatingCString: $0) }
                }
                guard let name else { throw VaultReadError.invalidPath }
                if name == "." || name == ".." { continue }
                let path = try VaultPath(prefix + name)
                guard !name.lowercased().hasPrefix(".andesite"), namespace.insert(path.portabilityKey).inserted else { throw VaultReadError.invalidPath }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw VaultReadError.unstable }
                guard UInt64(info.st_dev) == rootDevice else { throw VaultReadError.unsafeFile }
                switch info.st_mode & mode_t(S_IFMT) {
                case mode_t(S_IFDIR):
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw VaultReadError.unsafeFile }
                    defer { close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else { throw VaultReadError.unstable }
                    try visit(child, prefix + name + "/")
                case mode_t(S_IFREG):
                    guard info.st_nlink == 1 else { throw VaultReadError.unsafeFile }
                    if name.lowercased().hasSuffix(".md") { paths.append(ScannedMarkdownFile(path: path, fingerprint: FileFingerprint(info))) }
                default: throw VaultReadError.unsafeFile
                }
            }
        }
        let fd = openat(root, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw VaultReadError.systemCall("open scan root", errno) }
        defer { close(fd) }
        try visit(fd, "")
        try verifyRoot()
        return paths.sorted { $0.path.components.joined(separator: "/").utf8.lexicographicallyPrecedes($1.path.components.joined(separator: "/").utf8) }
    }

    /// Only ENOENT confirms absence. A complete scan must precede this check.
    public func confirmAbsent(_ path: VaultPath) throws -> Bool {
        try verifyRoot()
        var directory = dup(root)
        guard directory >= 0 else { throw VaultReadError.systemCall("dup root", errno) }
        defer { close(directory) }
        for component in path.components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if errno == ENOENT { return true }
                throw VaultReadError.systemCall("check absent parent", errno)
            }
            var info = stat()
            guard fstat(next, &info) == 0, UInt64(info.st_dev) == rootDevice else { close(next); throw VaultReadError.unsafeFile }
            close(directory); directory = next
        }
        var info = stat()
        if fstatat(directory, path.components.last!, &info, AT_SYMLINK_NOFOLLOW) == 0 { return false }
        guard errno == ENOENT else { throw VaultReadError.systemCall("check absence", errno) }
        try verifyRoot()
        return true
    }

    /// Requires two matching byte and metadata observations separated by the
    /// caller-specified debounce. Even matching observations cannot rule out
    /// unobserved writes or a writer paused between edits.
    public func readStable(_ path: VaultPath, maximumBytes: Int, debounce: TimeInterval = 0.25) throws -> Data {
        guard maximumBytes >= 0, debounce >= 0, debounce.isFinite else { throw VaultReadError.invalidPath }
        return try observeStable(path, maximumBytes: maximumBytes, debounce: debounce).bytes
    }

    public func observeStable(_ path: VaultPath, maximumBytes: Int, debounce: TimeInterval = 0.25) throws -> ObservedFile {
        guard maximumBytes >= 0, debounce >= 0, debounce.isFinite else { throw VaultReadError.invalidPath }
        return try observeStable(path, maximumBytes: maximumBytes, betweenObservations: {
            Thread.sleep(forTimeInterval: debounce)
        })
    }

    // Internal seam for deterministic race tests. The caller must still run
    // this synchronous function on a blocking executor.
    func readStable(_ path: VaultPath, maximumBytes: Int, betweenObservations: () throws -> Void) throws -> Data {
        try observeStable(path, maximumBytes: maximumBytes, betweenObservations: betweenObservations).bytes
    }

    private func observeStable(_ path: VaultPath, maximumBytes: Int, betweenObservations: () throws -> Void) throws -> ObservedFile {
        let first = try observe(path, maximumBytes: maximumBytes)
        try betweenObservations()
        let second = try observe(path, maximumBytes: maximumBytes)
        guard first.0 == second.0, first.1 == second.1 else { throw VaultReadError.unstable }
        return ObservedFile(fingerprint: second.0, bytes: second.1)
    }

    private func observe(_ path: VaultPath, maximumBytes: Int) throws -> (FileFingerprint, Data) {
        try verifyRoot()
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
              FileFingerprint(before) == FileFingerprint(after), FileFingerprint(after) == FileFingerprint(atPath),
              data.count == after.st_size else { throw VaultReadError.unstable }
        return (FileFingerprint(after), data)
    }
}
