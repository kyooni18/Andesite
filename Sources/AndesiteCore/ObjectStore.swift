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
            touch(hash)
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

    /// Writes the object's data to the device. It becomes crash-durable at
    /// the next catalog commit, which runs with `fullfsync` and flushes the
    /// whole device cache; every reference to an object is such a commit, so
    /// a separate F_FULLFSYNC per object would only repeat that flush.
    func durabilityBarrier(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw ObjectStoreError.systemCall("sync object", errno) }
    }

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
            if isHash { immutable[key] = (Int64(s.st_size), Int64(s.st_blocks) * 512) }
            else if name.hasPrefix(".object-") { temporary[key] = Int64(s.st_blocks) * 512 }
            else { throw ObjectStoreError.corruptObject }
        }
        return (immutable.values.reduce(0) { $0 + $1.0 }, immutable.values.reduce(0) { $0 + $1.1 }, temporary.filter { immutable[$0.key] == nil }.values.reduce(0, +))
    }

    /// The byte length of a stored object, or nil if absent.
    func size(_ hash: String) -> Int64? {
        var info = stat()
        guard Self.validHash(hash), fstatat(root, hash, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        return Int64(info.st_size)
    }

    public func contains(_ hash: String) -> Bool {
        var info = stat()
        return Self.validHash(hash) && fstatat(root, hash, &info, AT_SYMLINK_NOFOLLOW) == 0 &&
            info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    /// Stores the remaining bytes of an open file without buffering it in
    /// memory. Returns the SHA-256 hash and byte count of what was copied.
    @discardableResult
    func put(from source: Int32, maximumBytes: Int) throws -> (hash: String, size: Int64) {
        let temp = ".object-" + UUID().uuidString.lowercased()
        let fd = openat(root, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw ObjectStoreError.systemCall("create temporary object", errno) }
        defer { close(fd); _ = unlinkat(root, temp, 0) }
        var hasher = SHA256()
        var size: Int64 = 0
        try Self.copy(from: source, to: fd) { chunk in
            size += Int64(chunk.count)
            guard size <= Int64(maximumBytes) else { throw ObjectStoreError.tooLarge }
            hasher.update(bufferPointer: chunk)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        try durabilityBarrier(fd)
        if linkat(root, temp, root, hash, 0) != 0 {
            guard errno == EEXIST else { throw ObjectStoreError.systemCall("publish object", errno) }
            var existing = stat()
            guard fstatat(root, hash, &existing, AT_SYMLINK_NOFOLLOW) == 0, Int64(existing.st_size) == size else {
                throw ObjectStoreError.corruptObject
            }
            touch(hash)
        }
        guard fsync(root) == 0 else { throw ObjectStoreError.systemCall("sync object directory", errno) }
        return (hash, size)
    }

    /// Streams a verified object into an open file. A damaged object is
    /// detected before the caller can publish the destination.
    func export(_ hash: String, to destination: Int32) throws {
        guard Self.validHash(hash) else { throw ObjectStoreError.invalidHash }
        let fd = openat(root, hash, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ObjectStoreError.systemCall("open object", errno) }
        defer { close(fd) }
        var hasher = SHA256()
        try Self.copy(from: fd, to: destination) { hasher.update(bufferPointer: $0) }
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == hash else {
            throw ObjectStoreError.corruptObject
        }
    }

    /// Copies in 1 MiB chunks, handing each chunk to `inspect` before writing.
    static func copy(from source: Int32, to destination: Int32,
                     inspect: (UnsafeRawBufferPointer) throws -> Void) throws {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let n = read(source, buffer.baseAddress, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw ObjectStoreError.systemCall("read", errno)
            }
            if n == 0 { return }
            let chunk = UnsafeRawBufferPointer(rebasing: buffer[0..<n])
            try inspect(chunk)
            var offset = 0
            while offset < n {
                let w = write(destination, chunk.baseAddress!.advanced(by: offset), n - offset)
                if w < 0 && errno == EINTR { continue }
                guard w > 0 else { throw ObjectStoreError.systemCall("write", errno) }
                offset += w
            }
        }
    }

    static func validHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    }

    public func get(_ hash: String, maximumBytes: Int) throws -> Data {
        guard Self.validHash(hash) else { throw ObjectStoreError.invalidHash }
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

    /// Marks an object as recently stored, so garbage collection's grace
    /// period covers content that is about to be referenced again.
    private func touch(_ name: String) { _ = utimensat(root, name, nil, AT_SYMLINK_NOFOLLOW) }

    // MARK: Resumable transfer

    private static func partial(_ hash: String) -> String { ".object-partial-" + hash }

    /// Bytes received so far of an incomplete transfer of `hash`.
    func received(_ hash: String) -> Int64 {
        var info = stat()
        guard Self.validHash(hash), fstatat(root, Self.partial(hash), &info, AT_SYMLINK_NOFOLLOW) == 0 else { return 0 }
        return Int64(info.st_size)
    }

    /// Writes one chunk of the `size`-byte object `hash` at `offset` and
    /// returns the bytes received so far. A chunk that does not continue the
    /// transfer exactly is ignored; the sender resumes from the returned
    /// offset. The complete object is published only if it hashes to `hash`.
    func receive(_ hash: String, size: Int64, offset: Int64, _ data: Data) throws -> Int64 {
        guard Self.validHash(hash), size >= 0 else { throw ObjectStoreError.invalidHash }
        if self.size(hash) == size { return size }
        let name = Self.partial(hash)
        let fd = openat(root, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw ObjectStoreError.systemCall("open partial object", errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ObjectStoreError.corruptObject }
        var current = Int64(info.st_size)
        if current > size { guard ftruncate(fd, 0) == 0 else { throw ObjectStoreError.systemCall("reset partial object", errno) }; current = 0 }
        guard offset == current, offset + Int64(data.count) <= size else { return current }
        try data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let n = pwrite(fd, raw.baseAddress!.advanced(by: written), raw.count - written, off_t(offset) + off_t(written))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ObjectStoreError.systemCall("write partial object", errno) }
                written += n
            }
        }
        let received = offset + Int64(data.count)
        guard received == size else { return received }
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw ObjectStoreError.systemCall("rewind partial object", errno) }
        let stored = try put(from: fd, maximumBytes: Int(size))
        _ = unlinkat(root, name, 0)
        // A mismatch leaves only an unreferenced object for garbage collection.
        guard stored.hash == hash else { throw ObjectStoreError.corruptObject }
        return size
    }

    /// Up to `length` bytes of a stored object, starting at `offset`.
    func chunk(_ hash: String, offset: Int64, length: Int) throws -> Data {
        guard Self.validHash(hash), offset >= 0, length >= 0 else { throw ObjectStoreError.invalidHash }
        let fd = openat(root, hash, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ObjectStoreError.systemCall("open object", errno) }
        defer { close(fd) }
        var bytes = Data(count: length), total = 0
        try bytes.withUnsafeMutableBytes { raw in
            while total < length {
                let n = pread(fd, raw.baseAddress!.advanced(by: total), length - total, off_t(offset) + off_t(total))
                if n < 0 && errno == EINTR { continue }
                guard n >= 0 else { throw ObjectStoreError.systemCall("read object", errno) }
                if n == 0 { break }
                total += n
            }
        }
        return bytes.prefix(total)
    }

    /// Opens a stored object for streaming. Objects are immutable, so the
    /// descriptor stays valid even if the object is later collected.
    func descriptor(_ hash: String) throws -> Int32 {
        guard Self.validHash(hash) else { throw ObjectStoreError.invalidHash }
        let fd = openat(root, hash, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ObjectStoreError.systemCall("open object", errno) }
        return fd
    }

    // MARK: Garbage collection

    /// Every name in the store with its size and last modification.
    func listing() throws -> [(name: String, size: Int64, modified: TimeInterval)] {
        let copy = dup(root)
        guard copy >= 0, let stream = fdopendir(copy) else { throw ObjectStoreError.systemCall("list objects", errno) }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [(String, Int64, TimeInterval)] = []
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            var info = stat()
            guard name != ".", name != "..", fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            #if canImport(Darwin)
            let modified = TimeInterval(info.st_mtimespec.tv_sec)
            #else
            let modified = TimeInterval(info.st_mtim.tv_sec)
            #endif
            result.append((name, Int64(info.st_size), modified))
        }
        return result
    }

    func remove(_ name: String) throws {
        guard unlinkat(root, name, 0) == 0 || errno == ENOENT else { throw ObjectStoreError.systemCall("remove object", errno) }
    }
}
