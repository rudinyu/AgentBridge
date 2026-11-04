import Darwin
import Foundation

/// Cross-process advisory locking shared by the private stores. Each store
/// keeps its own lock-file location and error messages; this type owns the
/// open, integrity checks, EINTR retry and unlock so they behave the same.
enum PrivateLockFile {
    enum Failure {
        /// The lock file could not be opened (or is missing when not created).
        case unavailable
        /// The path is not a private regular file owned by this user.
        case notPrivateFile
        /// `flock` failed for a reason other than an interrupted wait.
        case lockFailed
    }

    /// Locks the file at `url`, creating it with owner-only permissions.
    static func withLock<T>(
        at url: URL,
        exclusive: Bool = true,
        error: (Failure) -> Error,
        _ operation: () throws -> T
    ) throws -> T {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw error(.unavailable) }
        defer { _ = close(descriptor) }
        return try withLockedDescriptor(descriptor, exclusive: exclusive, securePermissions: true, error: error, operation)
    }

    /// Locks `fileName` relative to an already-validated directory descriptor.
    /// With `create: false` a missing lock file reports `.unavailable`.
    static func withLock<T>(
        named fileName: String,
        in directoryDescriptor: Int32,
        create: Bool,
        exclusive: Bool = true,
        securePermissions: Bool = true,
        error: (Failure) -> Error,
        _ operation: () throws -> T
    ) throws -> T {
        let flags = (securePermissions ? O_RDWR : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW | (create ? O_CREAT : 0)
        let descriptor = fileName.withCString { openat(directoryDescriptor, $0, flags, mode_t(0o600)) }
        guard descriptor >= 0 else { throw error(.unavailable) }
        defer { _ = close(descriptor) }
        return try withLockedDescriptor(descriptor, exclusive: exclusive, securePermissions: securePermissions, error: error, operation)
    }

    private static func withLockedDescriptor<T>(
        _ descriptor: Int32,
        exclusive: Bool,
        securePermissions: Bool,
        error: (Failure) -> Error,
        _ operation: () throws -> T
    ) throws -> T {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == getuid(), metadata.st_nlink == 1,
              !securePermissions || fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw error(.notPrivateFile)
        }
        while flock(descriptor, exclusive ? LOCK_EX : LOCK_SH) != 0 {
            if errno == EINTR { continue }
            throw error(.lockFailed)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
