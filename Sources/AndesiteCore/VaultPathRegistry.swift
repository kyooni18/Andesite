import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum VaultPathRegistryError: Error, Equatable {
    case invalidDirectory
    case invalidVaultPath
    case unsafeRegistry
    case invalidContents
    case systemCall(String, Int32)
}

/// One path-only marker per Vault, stored in <vault>/.andesite/vault.json.
///
/// This does not register Vaults globally, create an index/database, or scan
/// document contents. Historical snapshot/index state remains independent.
public final class VaultPathRegistry {
    public static let directoryName = ".andesite"
    public static let filename = "vault.json"

    private let root: Int32
    private let path: String
    private let device: dev_t
    private let inode: ino_t

    public init(vaultDirectory: String) throws {
        try Self.validateAbsolutePath(vaultDirectory)
        try Self.validateVaultDirectory(vaultDirectory)
        let fd = open(vaultDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw VaultPathRegistryError.systemCall("open vault directory", errno)
        }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid() else {
            close(fd)
            throw VaultPathRegistryError.invalidVaultPath
        }
        self.root = fd
        self.path = vaultDirectory
        self.device = info.st_dev
        self.inode = info.st_ino
    }

    deinit { close(root) }

    /// Read the stored path without making or modifying a .andesite directory.
    /// A moved Vault may still contain its previous absolute path until added
    /// at the new location; no automatic filesystem reorganization occurs.
    public func storedPath() throws -> String? {
        guard let directory = try openRegistry(create: false) else { return nil }
        defer { close(directory) }
        return try Self.readPath(from: directory)
    }

    /// Create or update the path marker inside the selected Vault. Does not
    /// open any Markdown file, create an index, or start the watcher.
    @discardableResult
    public func register() throws -> Bool {
        guard let directory = try openRegistry(create: true) else {
            throw VaultPathRegistryError.unsafeRegistry
        }
        defer { close(directory) }
        return try Self.withLock(directory) {
            let previous = try Self.readPath(from: directory)
            guard previous != path else { return false }
            try Self.writePath(path, to: directory)
            return true
        }
    }

    /// Forget only this Vault's path marker. Never remove other contents from
    /// .andesite, the Vault itself, or external snapshot/index state.
    @discardableResult
    public func unregister() throws -> Bool {
        guard let directory = try openRegistry(create: false) else { return false }
        defer { close(directory) }
        return try Self.withLock(directory) {
            guard try Self.readPath(from: directory) != nil else { return false }
            guard unlinkat(directory, Self.filename, 0) == 0 else {
                throw VaultPathRegistryError.systemCall("remove vault path", errno)
            }
            guard fsync(directory) == 0 else {
                throw VaultPathRegistryError.systemCall("sync vault metadata", errno)
            }
            return true
        }
    }

    private func verifyRoot() throws {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_dev == device, info.st_ino == inode else {
            throw VaultPathRegistryError.invalidVaultPath
        }
    }

    private func openRegistry(create: Bool) throws -> Int32? {
        try verifyRoot()
        if create && mkdirat(root, Self.directoryName, mode_t(0o700)) != 0 && errno != EEXIST {
            throw VaultPathRegistryError.systemCall("create .andesite", errno)
        }
        let directory = openat(root, Self.directoryName,
                               O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            if !create && errno == ENOENT { return nil }
            if errno == ELOOP || errno == ENOTDIR { throw VaultPathRegistryError.unsafeRegistry }
            throw VaultPathRegistryError.systemCall("open .andesite", errno)
        }
        var opened = stat(), linked = stat()
        guard fstat(directory, &opened) == 0,
              fstatat(root, Self.directoryName, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              opened.st_uid == geteuid(),
              opened.st_mode & 0o077 == 0,
              opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino,
              opened.st_dev == device else {
            close(directory)
            throw VaultPathRegistryError.unsafeRegistry
        }
        return directory
    }

    private static func validateAbsolutePath(_ path: String) throws {
        guard path.hasPrefix("/"), path != "/", path.utf8.count <= 4096,
              !path.contains("\0"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              !path.hasSuffix("/"), !path.contains("//"),
              path.dropFirst().split(separator: "/").allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
              }) else { throw VaultPathRegistryError.invalidDirectory }
    }

    private static func validateVaultDirectory(_ path: String) throws {
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            var info = stat()
            guard lstat(prefix, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw VaultPathRegistryError.invalidVaultPath
            }
            if prefix == path && info.st_uid != geteuid() {
                throw VaultPathRegistryError.invalidVaultPath
            }
        }
    }

    private static func validateFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_nlink == 1,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0 else {
            throw VaultPathRegistryError.unsafeRegistry
        }
    }

    private static func readPath(from directory: Int32) throws -> String? {
        let fd = openat(directory, Self.filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw VaultPathRegistryError.unsafeRegistry }
            throw VaultPathRegistryError.systemCall("read vault path", errno)
        }
        defer { close(fd) }
        try validateFile(fd)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 1, info.st_size <= 8192 else {
            throw VaultPathRegistryError.invalidContents
        }
        var data = [UInt8](repeating: 0, count: Int(info.st_size) + 1)
        var total = 0
        while total < data.count {
            let count = data.withUnsafeMutableBytes {
                read(fd, $0.baseAddress!.advanced(by: total), $0.count - total)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw VaultPathRegistryError.systemCall("read vault path", errno) }
            if count == 0 { break }
            total += count
        }
        guard total <= 8192,
              let json = try? JSONSerialization.jsonObject(with: Data(data.prefix(total))),
              let object = json as? [String: Any],
              object.count == 1,
              let path = object["path"] as? String else {
            throw VaultPathRegistryError.invalidContents
        }
        do { try validateAbsolutePath(path) }
        catch { throw VaultPathRegistryError.invalidContents }
        return path
    }

    private static func withLock<T>(_ directory: Int32, _ body: () throws -> T) throws -> T {
        let fd = openat(directory, ".vault.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            if errno == ELOOP { throw VaultPathRegistryError.unsafeRegistry }
            throw VaultPathRegistryError.systemCall("open vault metadata lock", errno)
        }
        defer { close(fd) }
        try validateFile(fd)
        guard flock(fd, LOCK_EX) == 0 else {
            throw VaultPathRegistryError.systemCall("lock vault metadata", errno)
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    private static func writePath(_ path: String, to directory: Int32) throws {
        guard let encoded = try? JSONSerialization.data(withJSONObject: ["path": path], options: [.sortedKeys, .withoutEscapingSlashes]),
              encoded.count < 8192 else {
            throw VaultPathRegistryError.invalidContents
        }
        var bytes = encoded
        bytes.append(0x0A)
        let temporary = ".vault-\(UUID().uuidString).tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw VaultPathRegistryError.systemCall("create vault metadata staging", errno)
        }
        var published = false
        defer {
            close(fd)
            if !published { _ = unlinkat(directory, temporary, 0) }
        }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw VaultPathRegistryError.systemCall("write vault metadata", errno)
                }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw VaultPathRegistryError.systemCall("sync vault path", errno) }
        guard renameat(directory, temporary, directory, Self.filename) == 0 else {
            throw VaultPathRegistryError.systemCall("publish vault path", errno)
        }
        published = true
        guard fsync(directory) == 0 else {
            throw VaultPathRegistryError.systemCall("sync vault metadata", errno)
        }
    }
}
