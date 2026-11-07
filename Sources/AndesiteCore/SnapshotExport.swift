import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// External export only. A complete synced file is published with linkat's
/// no-replace semantics. No symlink traversal, existing-target truncation, or
/// export into vault/state (including differently cased root aliases) is allowed.
enum SnapshotExport {
    static func publish(_ bytes: Data, to destination: String, excluding roots: [String]) throws {
        guard destination.hasPrefix("/"), destination != "/" else { throw SnapshotError.unsafeExport }
        let path = try VaultPath(String(destination.dropFirst()))
        var excluded: [(dev_t, ino_t)] = []
        for root in roots {
            var info = stat()
            guard lstat(root, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw SnapshotError.unsafeExport }
            excluded.append((info.st_dev, info.st_ino))
        }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw SnapshotError.unsafeExport }
        defer { close(directory) }
        for component in path.components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw SnapshotError.unsafeExport }
            var info = stat()
            guard fstat(next, &info) == 0,
                  info.st_mode & 0o022 == 0 || info.st_mode & mode_t(S_ISVTX) != 0,
                  !excluded.contains(where: { $0.0 == info.st_dev && $0.1 == info.st_ino }) else {
                close(next); throw SnapshotError.unsafeExport
            }
            close(directory); directory = next
        }
        var parent = stat()
        guard fstat(directory, &parent) == 0, parent.st_uid == geteuid() else { throw SnapshotError.unsafeExport }
        let temporary = ".andesite-export-" + UUID().uuidString.lowercased()
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SnapshotError.unsafeExport }
        defer { close(fd); _ = unlinkat(directory, temporary, 0) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw ObjectStoreError.systemCall("write export", errno) }
                offset += written
            }
        }
        #if canImport(Darwin)
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw ObjectStoreError.systemCall("sync export", errno) }
        #else
        guard fsync(fd) == 0 else { throw ObjectStoreError.systemCall("sync export", errno) }
        #endif
        guard linkat(directory, temporary, directory, path.components.last!, 0) == 0 else { throw SnapshotError.unsafeExport }
        guard fsync(directory) == 0 else { throw ObjectStoreError.systemCall("sync export directory", errno) }
    }
}
