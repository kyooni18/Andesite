import Foundation
import Crypto
import CAndesiteFS
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Errors of the document API. Descriptions never contain file contents.
public enum VaultError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case alreadyExists(String)
    /// Optimistic concurrency failure. The document changed in the catalog
    /// or on disk since `expected`; `current` is the latest head, if any.
    case conflict(current: Data?)
    case invalidPath(String)
    case tooLarge
    case unsupported(String)
    /// The disk, or the user's quota, is full. Nothing was changed.
    case storageFull

    public var description: String {
        switch self {
        case .notFound(let path): return "not found: \(path)"
        case .alreadyExists(let path): return "already exists: \(path)"
        case .conflict: return "revision conflict: the document changed; read it again and retry"
        case .invalidPath(let path): return "invalid vault path: \(path)"
        case .tooLarge: return "content exceeds the configured size limit"
        case .unsupported(let reason): return "unsupported: \(reason)"
        case .storageFull: return "the disk is full"
        }
    }

    /// A failed system call (read `errno` immediately after it).
    static func system(_ what: String, _ code: Int32 = errno) -> VaultError {
        code == ENOSPC || code == EDQUOT ? .storageFull : .unsupported("\(what) (errno \(code))")
    }

    /// Whether `error` means the disk or quota is full, whichever layer
    /// (vault files, object store, catalog, staging) reported it.
    public static func isStorageFull(_ error: Error) -> Bool {
        switch error {
        case VaultError.storageFull: return true
        case ObjectStoreError.systemCall(_, let code): return code == ENOSPC || code == EDQUOT
        case let failure as SQLiteFailure: return failure.code & 0xff == 13 // SQLITE_FULL
        default:
            let error = error as NSError
            return (error.domain == NSPOSIXErrorDomain && (error.code == Int(ENOSPC) || error.code == Int(EDQUOT)))
                || (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
        }
    }
}

/// A directory inside the Vault, opened one component at a time without
/// following symbolic links or leaving the Vault's device. Every mutation
/// is expressed relative to such descriptors, never to path strings.
final class VaultDirectory {
    let fd: Int32
    let device: UInt64

    init(root: Int32, components: [String], create: Bool = false) throws {
        var current = dup(root)
        guard current >= 0 else { throw VaultError.unsupported("cannot open vault root") }
        var info = stat()
        guard fstat(current, &info) == 0 else { close(current); throw VaultError.unsupported("cannot stat vault root") }
        device = UInt64(info.st_dev)
        do {
            for component in components {
                var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && create {
                    guard mkdirat(current, component, 0o755) == 0 || errno == EEXIST else {
                        throw VaultError.system("cannot create directory")
                    }
                    guard fsync(current) == 0 else { throw VaultError.system("directory sync failed") }
                    next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else {
                    if errno == ENOENT { throw VaultError.notFound(component) }
                    // ELOOP/ENOTDIR: a symlink or a file where a folder is expected.
                    throw VaultError.invalidPath(component)
                }
                close(current); current = next
                guard fstat(current, &info) == 0, UInt64(info.st_dev) == device,
                      info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
                    throw VaultError.invalidPath(component)
                }
            }
            guard andesite_supported_filesystem(current) == 1 else {
                throw VaultError.unsupported("vault must be on a local filesystem")
            }
        } catch { close(current); throw error }
        fd = current
    }

    deinit { close(fd) }

    /// nil when absent. Only owned, singly linked regular files are accepted.
    func info(_ name: String) throws -> FileFingerprint? {
        var s = stat()
        if fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw VaultError.invalidPath(name)
        }
        guard s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), s.st_nlink == 1,
              UInt64(s.st_dev) == device else { throw VaultError.invalidPath(name) }
        return FileFingerprint(s, directory: fd, name: name)
    }

    func exists(_ name: String) -> Bool {
        var s = stat()
        return fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0
    }

    /// Exact on-disk spellings, needed on case-insensitive volumes.
    func names() throws -> Set<String> {
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0, let stream = fdopendir(copy) else { throw VaultError.unsupported("cannot list directory") }
        defer { closedir(stream) }
        var result = Set<String>()
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw VaultError.unsupported("cannot list directory") }
                return result
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.insert(name) }
        }
    }

    /// Streams the file through SHA-256. Returns nil when absent.
    func digest(_ name: String, maximumBytes: Int) throws -> (fingerprint: FileFingerprint, hash: String, size: Int64)? {
        guard let before = try info(name) else { return nil }
        guard before.size <= maximumBytes else { throw VaultError.tooLarge }
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw VaultError.invalidPath(name)
        }
        defer { close(file) }
        var hasher = SHA256()
        var size: Int64 = 0
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let n = read(file, buffer.baseAddress, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw VaultError.system("read failed") }
            if n == 0 { break }
            size += Int64(n)
            guard size <= maximumBytes else { throw VaultError.tooLarge }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
        }
        var after = stat()
        guard fstat(file, &after) == 0, FileFingerprint(after, directory: file) == before,
              Int64(after.st_size) == size else { throw VaultError.conflict(current: nil) }
        return (FileFingerprint(after, directory: file), hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }

    /// Writes a complete, durable file under a temporary name and then
    /// renames it to `name`, so `name` never holds partial content.
    /// `copyMetadataFrom` preserves mode and extended attributes of the
    /// file being replaced.
    func writeStage(_ name: String, object hash: String, objects: ObjectStore,
                    copyMetadataFrom original: String? = nil) throws {
        let temporary = name + ".tmp"
        _ = unlinkat(fd, temporary, 0) // only ever our own interrupted partial
        let file = openat(fd, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else { throw VaultError.system("cannot create staging file") }
        defer { close(file) }
        do {
            try objects.export(hash, to: file)
            if let original {
                let source = openat(fd, original, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard source >= 0 else { throw VaultError.conflict(current: nil) }
                defer { close(source) }
                guard andesite_copy_metadata(source, file) == 0 else {
                    throw VaultError.unsupported("file metadata cannot be preserved on this filesystem")
                }
            }
            try objects.durabilityBarrier(file)
            guard renameat(fd, temporary, fd, name) == 0 else { throw VaultError.system("cannot publish staging file") }
            try sync()
        } catch {
            _ = unlinkat(fd, temporary, 0)
            throw error
        }
    }

    func exchange(_ a: String, _ b: String) throws {
        guard andesite_exchange(fd, a, fd, b) == 0 else {
            throw errno == ENOENT ? VaultError.conflict(current: nil) : VaultError.system("atomic exchange failed")
        }
        try sync()
    }

    /// Atomic rename that never replaces an existing file. A case-only
    /// rename of the same file on a case-insensitive volume is allowed.
    func move(_ name: String, to target: VaultDirectory, _ newName: String) throws {
        if andesite_rename_noreplace(fd, name, target.fd, newName) != 0 {
            guard errno == EEXIST else {
                throw errno == ENOENT ? VaultError.conflict(current: nil) : VaultError.system("rename failed")
            }
            var a = stat(), b = stat()
            guard fstatat(fd, name, &a, AT_SYMLINK_NOFOLLOW) == 0,
                  fstatat(target.fd, newName, &b, AT_SYMLINK_NOFOLLOW) == 0,
                  a.st_dev == b.st_dev, a.st_ino == b.st_ino,
                  renameat(fd, name, target.fd, newName) == 0 else {
                throw VaultError.alreadyExists(newName)
            }
        }
        try sync()
        if target.fd != fd { try target.sync() }
    }

    func remove(_ name: String) throws {
        guard unlinkat(fd, name, 0) == 0 || errno == ENOENT else { throw VaultError.unsupported("cannot remove \(name)") }
        try sync()
    }

    func sync() throws {
        guard fsync(fd) == 0 else { throw VaultError.system("directory sync failed") }
    }
}
