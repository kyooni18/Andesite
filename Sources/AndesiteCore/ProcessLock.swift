import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ProcessLockError: Error, Equatable {
    case unavailable
    case unsafeLockFile
    case systemCall(String, Int32)
}

/// Holds an advisory lock for the lifetime of this object. This coordinates
/// Andesite instances using the same state directory only; it does not lock
/// vault files or coordinate ordinary editors. The state directory must be
/// private, pre-existing, and configured outside every vault.
public final class ProcessLock {
    private let descriptor: Int32

    public init(stateDirectory: String) throws {
        let root = open(stateDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw ProcessLockError.systemCall("open state directory", errno) }
        defer { close(root) }
        let fd = openat(root, "server.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
        guard fd >= 0 else { throw ProcessLockError.systemCall("open lock file", errno) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = errno; close(fd); throw ProcessLockError.systemCall("stat lock file", error)
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_nlink == 1 else {
            close(fd); throw ProcessLockError.unsafeLockFile
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno; close(fd)
            if error == EWOULDBLOCK || error == EAGAIN { throw ProcessLockError.unavailable }
            throw ProcessLockError.systemCall("acquire lock", error)
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}
