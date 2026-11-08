import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ObjectStoreError: Error, Equatable {
    case invalidHash
    case corruptObject
    case tooLarge
    case systemCall(String, Int32)
}

/// Immutable, content-addressed objects in a private, pre-existing directory.
/// Synchronous: use a bounded blocking executor. Object persistence is not a
/// substitute for a journal or an atomic transaction with SQLite.
public final class ObjectStore {
    private let root: Int32
    public init(directory: String) throws {
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ObjectStoreError.systemCall("open object directory", errno) }
        root = fd
    }
    deinit { close(root) }

    public static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Does not replace an existing name. A corrupt existing object is reported,
    /// never overwritten. The temporary file is private and never a vault file.
    @discardableResult
    public func put(_ bytes: Data) throws -> String {
        let hash = Self.hash(bytes)
        var existing = stat()
        if fstatat(root, hash, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            // Dedup without even writing a redundant temporary copy. Verification
            // is still mandatory; a damaged object is never repaired in place.
            guard try get(hash, maximumBytes: bytes.count) == bytes else { throw ObjectStoreError.corruptObject }
            // An earlier interrupted put may have linked but not synced the name.
            guard fsync(root) == 0 else { throw ObjectStoreError.systemCall("sync object directory", errno) }
            let fd = openat(root, hash, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ObjectStoreError.systemCall("open object barrier", errno) }
            defer { close(fd) }
            try durabilityBarrier(fd)
            return hash
        }
        guard errno == ENOENT else { throw ObjectStoreError.systemCall("check object", errno) }
        let temp = ".object-" + UUID().uuidString.lowercased()
        let fd = openat(root, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw ObjectStoreError.systemCall("create temporary object", errno) }
        defer { close(fd); _ = unlinkat(root, temp, 0) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ObjectStoreError.systemCall("write object", errno)
                }
                guard n > 0 else { throw ObjectStoreError.systemCall("write object", EIO) }
                offset += n
            }
        }
        try durabilityBarrier(fd)
        if linkat(root, temp, root, hash, 0) != 0 {
            guard errno == EEXIST else { throw ObjectStoreError.systemCall("publish object", errno) }
            guard try get(hash, maximumBytes: bytes.count) == bytes else { throw ObjectStoreError.corruptObject }
        }
        guard fsync(root) == 0 else { throw ObjectStoreError.systemCall("sync object directory", errno) }
        // Flush after the directory entry as well, on the OBJECT volume (which
        // may differ from the destination or SQLite volume).
        try durabilityBarrier(fd)
        return hash
    }

    private func durabilityBarrier(_ fd: Int32) throws {
        #if canImport(Darwin)
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw ObjectStoreError.systemCall("full sync object", errno) }
        #else
        guard fsync(fd) == 0 else { throw ObjectStoreError.systemCall("sync object", errno) }
        #endif
    }

    /// Accounting only; does not authorize removal of anything in the store.
    func storageUsage() throws -> (logical: Int64, allocated: Int64, temporary: Int64) {
        let copy = openat(root, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0, let stream = fdopendir(copy) else { throw ObjectStoreError.systemCall("enumerate object storage", errno) }
        defer { closedir(stream) }
        var immutable: [String: (Int64, Int64)] = [:], temporary: [String: Int64] = [:]
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw ObjectStoreError.systemCall("read object storage", errno) }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var s = stat()
            guard fstatat(root, name, &s, AT_SYMLINK_NOFOLLOW) == 0, s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ObjectStoreError.corruptObject }
            let key = "\(s.st_dev):\(s.st_ino)"
            let isHash = name.utf8.count == 64 && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            if isHash { immutable[key] = (s.st_size, Int64(s.st_blocks) * 512) }
            else if name.hasPrefix(".object-") { temporary[key] = Int64(s.st_blocks) * 512 }
            else { throw ObjectStoreError.corruptObject }
        }
        return (immutable.values.reduce(0) { $0 + $1.0 }, immutable.values.reduce(0) { $0 + $1.1 }, temporary.filter { immutable[$0.key] == nil }.values.reduce(0, +))
    }

    public func get(_ hash: String, maximumBytes: Int) throws -> Data {
        guard hash.utf8.count == 64 && hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ObjectStoreError.invalidHash
        }
        guard maximumBytes >= 0 else { throw ObjectStoreError.tooLarge }
        let fd = openat(root, hash, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ObjectStoreError.systemCall("open object", errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ObjectStoreError.systemCall("stat object", errno) }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw ObjectStoreError.corruptObject }
        guard info.st_size >= 0, info.st_size <= maximumBytes else { throw ObjectStoreError.tooLarge }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw ObjectStoreError.systemCall("read object", errno)
            }
            if n == 0 { break }
            guard n <= maximumBytes - bytes.count else { throw ObjectStoreError.tooLarge }
            bytes.append(contentsOf: buffer[0..<n])
        }
        guard Self.hash(bytes) == hash else { throw ObjectStoreError.corruptObject }
        return bytes
    }
}
