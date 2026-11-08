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
    case tooManyVaults
    case systemCall(String, Int32)
}

/// A deliberately minimal, per-user list of selected Vault directory paths.
///
/// ~/.andesite/vaults.json stores only an array of absolute paths. No note
/// contents, SQLite catalog, state location, snapshot, inode or FTS data enter
/// this registry. Existing per-vault state directories remain independent.
///
/// The registry never scans or opens the contents of a selected Vault.
public final class VaultPathRegistry {
    public static let filename = "vaults.json"
    private static let maximumPaths = 1_000
    private static let maximumFileBytes = 512 * 1024

    private let root: Int32

    public init(directory: String = FileManager.default.homeDirectoryForCurrentUser.path + "/.andesite") throws {
        try Self.validateAbsolutePath(directory)
        if mkdir(directory, 0o700) != 0 && errno != EEXIST {
            throw VaultPathRegistryError.systemCall("create registry directory", errno)
        }
        try Self.validateDirectory(directory, privateDirectory: true)
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw VaultPathRegistryError.systemCall("open registry directory", errno) }
        root = fd
        do {
            try locked {
                if try !Self.exists(Self.filename, in: root) {
                    try Self.writePaths([], to: root)
                } else {
                    _ = try Self.readPaths(from: root)
                }
            }
        } catch {
            close(fd)
            throw error
        }
    }

    deinit { close(root) }

    /// Lists saved selections even when an external-drive vault is offline.
    public func list() throws -> [String] {
        try locked { try Self.readPaths(from: root) }
    }

    /// Only registration checks that a vault exists. Does not scan documents.
    @discardableResult
    public func add(_ path: String) throws -> Bool {
        try Self.validateDirectory(path, privateDirectory: false)
        return try locked {
            var paths = try Self.readPaths(from: root)
            if paths.contains(path) { return false }
            guard paths.count < Self.maximumPaths else { throw VaultPathRegistryError.tooManyVaults }
            paths.append(path)
            try Self.writePaths(paths.sorted(), to: root)
            return true
        }
    }

    /// Removal is safe if an external drive is disconnected: no vault data is
    /// touched, and no state files, snapshots or histories are ever removed.
    @discardableResult
    public func remove(_ path: String) throws -> Bool {
        try Self.validateAbsolutePath(path)
        return try locked {
            var paths = try Self.readPaths(from: root)
            guard let offset = paths.firstIndex(of: path) else { return false }
            paths.remove(at: offset)
            try Self.writePaths(paths, to: root)
            return true
        }
    }

    private func locked<T>(_ action: () throws -> T) throws -> T {
        let fd = openat(root, ".vaults.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            if errno == ELOOP { throw VaultPathRegistryError.unsafeRegistry }
            throw VaultPathRegistryError.systemCall("open registry lock", errno)
        }
        defer { close(fd) }
        try Self.validateFile(fd)
        guard flock(fd, LOCK_EX) == 0 else {
            throw VaultPathRegistryError.systemCall("lock registry", errno)
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try action()
    }

    private static func validateAbsolutePath(_ path: String) throws {
        guard path.hasPrefix("/"), path != "/", path.utf8.count <= 4096,
              !path.contains("\0"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              !path.hasSuffix("/"), !path.contains("//"),
              path.dropFirst().split(separator: "/").allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
              })
        else { throw VaultPathRegistryError.invalidDirectory }
    }

    private static func validateDirectory(_ path: String, privateDirectory: Bool) throws {
        try validateAbsolutePath(path)
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            var information = stat()
            guard lstat(prefix, &information) == 0,
                  information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw VaultPathRegistryError.invalidVaultPath
            }
            // All parent directory entries are real directories, never links.
            // An existing vault must belong to the caller, as with VaultRuntime.
            if prefix == path {
                guard information.st_uid == geteuid() else {
                    throw VaultPathRegistryError.invalidVaultPath
                }
                if privateDirectory && information.st_mode & 0o077 != 0 {
                    throw VaultPathRegistryError.unsafeRegistry
                }
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

    private static func exists(_ name: String, in directory: Int32) throws -> Bool {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw VaultPathRegistryError.systemCall("stat registry", errno)
    }

    private static func readPaths(from directory: Int32) throws -> [String] {
        let fd = openat(directory, Self.filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP { throw VaultPathRegistryError.unsafeRegistry }
            throw VaultPathRegistryError.systemCall("read registry", errno)
        }
        defer { close(fd) }
        try validateFile(fd)
        var statInfo = stat()
        guard fstat(fd, &statInfo) == 0,
              statInfo.st_size >= 0,
              statInfo.st_size <= Self.maximumFileBytes else {
            throw VaultPathRegistryError.invalidContents
        }
        var bytes = [UInt8](repeating: 0, count: Int(statInfo.st_size) + 1)
        var total = 0
        while total < bytes.count {
            let count = bytes.withUnsafeMutableBytes {
                read(fd, $0.baseAddress!.advanced(by: total), $0.count - total)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw VaultPathRegistryError.systemCall("read registry", errno) }
            if count == 0 { break }
            total += count
        }
        guard total <= Self.maximumFileBytes,
              let paths = try? JSONDecoder().decode([String].self, from: Data(bytes.prefix(total))),
              paths.count <= Self.maximumPaths, paths == Array(Set(paths)).sorted() else {
            throw VaultPathRegistryError.invalidContents
        }
        for path in paths {
            do { try validateAbsolutePath(path) }
            catch { throw VaultPathRegistryError.invalidContents }
        }
        return paths
    }

    private static func writePaths(_ paths: [String], to directory: Int32) throws {
        guard paths.count <= Self.maximumPaths,
              let encoded = try? JSONEncoder().encode(paths), encoded.count <= Self.maximumFileBytes - 1
        else { throw VaultPathRegistryError.tooManyVaults }
        var bytes = encoded
        bytes.append(0x0A)

        let temp = ".vaults-\(UUID().uuidString).tmp"
        let fd = openat(directory, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VaultPathRegistryError.systemCall("create registry staging", errno) }
        var completed = false
        defer {
            close(fd)
            if !completed { _ = unlinkat(directory, temp, 0) }
        }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw VaultPathRegistryError.systemCall("write registry", errno)
                }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw VaultPathRegistryError.systemCall("sync registry", errno) }
        guard renameat(directory, temp, directory, Self.filename) == 0 else {
            throw VaultPathRegistryError.systemCall("publish registry", errno)
        }
        completed = true
        guard fsync(directory) == 0 else { throw VaultPathRegistryError.systemCall("sync registry directory", errno) }
    }
}
