import Foundation
import CAndesiteFS
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

    /// The fingerprint of `name` in `directory` (or, with an empty name, of
    /// the open file `directory`). On Linux the birth time, which `stat`
    /// lacks, comes from `statx` where the filesystem records it.
    init(_ s: stat, directory: Int32, name: String = "") {
        device = UInt64(s.st_dev); inode = UInt64(s.st_ino); size = Int64(s.st_size)
        #if canImport(Darwin)
        modificationSeconds = Int64(s.st_mtimespec.tv_sec); modificationNanos = Int64(s.st_mtimespec.tv_nsec)
        changeSeconds = Int64(s.st_ctimespec.tv_sec); changeNanos = Int64(s.st_ctimespec.tv_nsec)
        birthSeconds = Int64(s.st_birthtimespec.tv_sec); birthNanos = Int64(s.st_birthtimespec.tv_nsec)
        #else
        modificationSeconds = Int64(s.st_mtim.tv_sec); modificationNanos = Int64(s.st_mtim.tv_nsec)
        changeSeconds = Int64(s.st_ctim.tv_sec); changeNanos = Int64(s.st_ctim.tv_nsec)
        var seconds: Int64 = 0, nanoseconds: Int64 = 0
        if andesite_birth_time(directory, name, &seconds, &nanoseconds) == 0 {
            birthSeconds = seconds; birthNanos = nanoseconds
        } else {
            birthSeconds = nil; birthNanos = nil
        }
        #endif
    }

    /// The later of the content and metadata change times, in seconds.
    var changedAt: Double {
        max(Double(modificationSeconds) + Double(modificationNanos) / 1e9, Double(changeSeconds) + Double(changeNanos) / 1e9)
    }

    var renameIdentity: String? {
        guard let birthSeconds, let birthNanos, birthSeconds != 0 || birthNanos != 0 else { return nil }
        return "\(device):\(inode):\(birthSeconds):\(birthNanos)"
    }
}

public struct ScannedFile: Sendable {
    public let path: VaultPath
    public let fingerprint: FileFingerprint
    public var kind: String { path.components.last!.lowercased().hasSuffix(".md") ? "markdown" : "attachment" }
}

/// Synchronous descriptor-relative observation. Run on a bounded blocking
/// executor, never an NIO event loop. This is a building block, not a watcher,
/// catalog publication, durable capture, or proof that an editor has finished.
public final class VaultReader {
    let root: Int32
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

    func verifyRoot() throws {
        var info = stat()
        guard lstat(rootPath, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              UInt64(info.st_dev) == rootDevice, UInt64(info.st_ino) == rootInode else { throw VaultReadError.unstable }
    }

    /// Every trackable file: Markdown notes and attachments. A failed
    /// enumeration never returns a partial listing.
    ///
    /// Hidden names (".obsidian", ".git", ".trash", ".andesite", journal
    /// artifacts, editor swap files) are skipped like Obsidian skips them.
    /// Only `.andesite/settings.json` is captured for sync, as an attachment;
    /// it is excluded from the public file list and link index.
    /// Every regular file in the vault. `visiting` runs before each folder
    /// is read (a scan uses it to give way to user requests).
    public func files(visiting: () throws -> Void = {}) throws -> [ScannedFile] {
        try verifyRoot()
        var paths: [ScannedFile] = []
        var namespace = Set<String>()
        func visit(_ fd: Int32, _ prefix: String) throws {
            try visiting()
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
                if prefix == ".andesite/" {
                    guard name == "settings.json" else { continue }
                } else if name.hasPrefix(".") && !(prefix.isEmpty && name == ".andesite") { continue }
                let path = try VaultPath(prefix + name)
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw VaultReadError.unstable }
                guard namespace.insert(path.portabilityKey).inserted else { throw VaultReadError.invalidPath }
                guard UInt64(info.st_dev) == rootDevice else { throw VaultReadError.unsafeFile }
                switch info.st_mode & mode_t(S_IFMT) {
                case mode_t(S_IFDIR):
                    guard prefix != ".andesite/" else { continue }
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw VaultReadError.unsafeFile }
                    defer { close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else { throw VaultReadError.unstable }
                    try visit(child, prefix + name + "/")
                case mode_t(S_IFREG) where info.st_nlink == 1:
                    guard prefix != "" || name != ".andesite" else { continue }
                    paths.append(ScannedFile(path: path, fingerprint: FileFingerprint(info, directory: fd, name: name)))
                default:
                    // Symlinks, hard-linked files and special files are never
                    // followed or indexed; Andesite cannot replace them safely.
                    continue
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
                if errno == ENOENT { try verifyRoot(); return true }
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

    /// Streams the file into `objects`, provided it is still exactly the
    /// file that was scanned (`expected`) and does not change while read.
    /// The caller waits a debounce between scanning and capturing, so a file
    /// being written is seen as unstable rather than captured half-written.
    func capture(_ path: VaultPath, expected: FileFingerprint, into objects: ObjectStore,
                 maximumBytes: Int) throws -> (hash: String, size: Int64) {
        let directory = try parent(path)
        defer { close(directory) }
        let name = path.components.last!
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw VaultReadError.unstable }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw VaultReadError.systemCall("stat file", errno) }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_nlink == 1,
              UInt64(before.st_dev) == rootDevice else { throw VaultReadError.unsafeFile }
        guard FileFingerprint(before, directory: fd) == expected else { throw VaultReadError.unstable }
        guard before.st_size <= maximumBytes else { throw VaultReadError.tooLarge }
        let stored: (hash: String, size: Int64)
        do { stored = try objects.put(from: fd, maximumBytes: maximumBytes) } catch ObjectStoreError.tooLarge { throw VaultReadError.unstable }
        var after = stat(), atPath = stat()
        guard fstat(fd, &after) == 0, fstatat(directory, name, &atPath, AT_SYMLINK_NOFOLLOW) == 0,
              FileFingerprint(after, directory: fd) == expected, FileFingerprint(atPath, directory: directory, name: name) == expected,
              stored.size == Int64(after.st_size) else { throw VaultReadError.unstable }
        return stored
    }

    /// The current fingerprint of a regular file, without following links.
    func fingerprint(_ path: VaultPath) throws -> FileFingerprint {
        let directory = try parent(path)
        defer { close(directory) }
        var info = stat()
        guard fstatat(directory, path.components.last!, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw VaultReadError.unstable }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else { throw VaultReadError.unsafeFile }
        return FileFingerprint(info, directory: directory, name: path.components.last!)
    }

    /// The containing directory, opened without following links.
    private func parent(_ path: VaultPath) throws -> Int32 {
        try verifyRoot()
        var directory = dup(root)
        guard directory >= 0 else { throw VaultReadError.systemCall("dup root", errno) }
        for component in path.components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { close(directory); throw VaultReadError.unstable }
            var info = stat()
            guard fstat(next, &info) == 0, UInt64(info.st_dev) == rootDevice else {
                close(next); close(directory); throw VaultReadError.unsafeFile
            }
            close(directory); directory = next
        }
        return directory
    }
}
