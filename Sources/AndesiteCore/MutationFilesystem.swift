import Foundation
import CAndesiteFS
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum MutationError: Error, CustomStringConvertible {
    case conflict(String)
    case unfinished
    case unsupportedPlatform
    public var description: String {
        switch self {
        case .conflict(let message): return "Restoration conflict: \(message). Inspect mutation-journal; preserve journal artifacts and use snapshot-export for manual recovery."
        case .unfinished: return "Unresolved mutation journal; ordinary reconciliation/restoration is blocked. Inspect mutation-journal and export snapshots; do not remove retained artifacts."
        case .unsupportedPlatform: return "In-place restoration requires qualified macOS metadata/exchange semantics; use snapshot-export on this platform."
        }
    }
}

struct DirectoryIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    init(_ s: stat) { device = UInt64(s.st_dev); inode = UInt64(s.st_ino) }
}

/// Anchored no-follow handles, not string-based rename. Reopens the complete
/// chain before/after publication. This detects namespace changes, not a kernel
/// content CAS or a lock on other applications (see the documented race limits).
final class MutationFilesystem {
    let directory: Int32
    let name: String
    let identities: [DirectoryIdentity]
    private let rootPath: String
    private let path: VaultPath
    init(root: String, path: VaultPath, expected: [DirectoryIdentity]? = nil) throws {
        rootPath = root; self.path = path; name = path.components.last!
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MutationError.conflict("cannot open filesystem root") }
        var chain: [DirectoryIdentity] = []
        do {
            let components = root.split(separator: "/").map(String.init) + Array(path.components.dropLast())
            var vaultDevice: UInt64?
            for (i, component) in components.enumerated() {
                let child = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw MutationError.conflict("unsafe or missing parent directory") }
                close(fd); fd = child
                var s = stat()
                guard fstat(fd, &s) == 0,
                      s.st_mode & 0o022 == 0 || s.st_mode & mode_t(S_ISVTX) != 0 else { throw MutationError.conflict("writable parent directory") }
                let rootCount = root.split(separator: "/").count
                if i == rootCount - 1 { vaultDevice = UInt64(s.st_dev) }
                if let vaultDevice { guard vaultDevice == UInt64(s.st_dev), s.st_uid == geteuid(), s.st_mode & 0o022 == 0 else { throw MutationError.conflict("unsafe vault parent or mount crossing") } }
                chain.append(DirectoryIdentity(s))
            }
            if let expected { guard expected == chain else { throw MutationError.conflict("parent directory identity changed") } }
        } catch { close(fd); throw error }
        guard andesite_supported_filesystem(fd) == 1 else { close(fd); throw MutationError.unsupportedPlatform }
        directory = fd; identities = chain
    }
    deinit { close(directory) }
    func verifyChain() throws {
        _ = try MutationFilesystem(root: rootPath, path: path, expected: identities)
    }
    func info(_ name: String) throws -> stat? {
        var s = stat()
        if fstatat(directory, name, &s, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw MutationError.conflict("cannot inspect target or artifact")
        }
        guard s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), s.st_nlink == 1, s.st_uid == geteuid(),
              s.st_mode & 0o7000 == 0, UInt64(s.st_dev) == identities.last!.device else { throw MutationError.conflict("target or artifact is not an owned, singly linked ordinary file") }
        return s
    }
    func observe(_ name: String, maximumBytes: Int) throws -> ObservedFile {
        guard let before = try info(name) else { throw MutationError.conflict("missing target or artifact") }
        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MutationError.conflict("cannot open target or artifact") }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, FileFingerprint(s) == FileFingerprint(before), s.st_size >= 0, s.st_size <= maximumBytes else { throw MutationError.conflict("unstable or oversized file") }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0, n <= maximumBytes - bytes.count else { throw MutationError.conflict("read failed or file grew") }
            if n == 0 { break }
            bytes.append(contentsOf: buffer[..<n])
        }
        guard fstat(fd, &s) == 0, let after = try info(name),
              FileFingerprint(s) == FileFingerprint(before), FileFingerprint(after) == FileFingerprint(before), bytes.count == s.st_size else { throw MutationError.conflict("file changed during read") }
        return ObservedFile(fingerprint: FileFingerprint(s), bytes: bytes)
    }
    func stage(_ bytes: Data, artifact: String, original: FileFingerprint, fault: (String) throws -> Void) throws -> FileFingerprint {
        let source = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { throw MutationError.conflict("cannot open original metadata") }
        defer { close(source) }
        var s = stat()
        guard fstat(source, &s) == 0, FileFingerprint(s) == original else { throw MutationError.conflict("original changed before staging") }
        let fd = openat(directory, artifact, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MutationError.conflict("exclusive stage creation failed") }
        defer { close(fd) } // Never unlink: incomplete artifacts are diagnostic evidence.
        try fault("stage-created")
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw MutationError.conflict("stage write failed") }
                offset += n
            }
        }
        guard andesite_copy_metadata(source, fd) == 0 else { throw MutationError.conflict("metadata cannot be preserved on this filesystem") }
        try Self.syncFile(fd)
        try syncDirectory()
        try Self.syncFile(fd) // barrier AFTER publishing/syncing the staging name
        guard fstat(fd, &s) == 0 else { throw MutationError.conflict("cannot stat staged file") }
        try fault("stage-written")
        return FileFingerprint(s)
    }
    static func syncFile(_ fd: Int32) throws {
        #if canImport(Darwin)
        let result = fcntl(fd, F_FULLFSYNC)
        #else
        let result = fsync(fd)
        #endif
        guard result == 0 else { throw MutationError.conflict("required file durability barrier unavailable") }
    }
    func syncDirectory() throws {
        guard fsync(directory) == 0 else { throw MutationError.conflict("required directory sync unavailable") }
    }
    func exchange(artifact: String) throws {
        guard andesite_exchange(directory, artifact, name) == 0 else { throw MutationError.conflict("atomic exchange unavailable or failed") }
    }
    func syncPublished() throws {
        try syncDirectory()
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw MutationError.conflict("published file disappeared") }
        defer { close(fd) }
        try Self.syncFile(fd)
    }
}

extension FileFingerprint {
    func sameInode(as other: FileFingerprint) -> Bool {
        device == other.device && inode == other.inode && birthSeconds == other.birthSeconds && birthNanos == other.birthNanos
    }
}
