// SPDX-License-Identifier: MIT
import Foundation
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// A cooperative single-writer lease, not authorization and not a secret store.
/// Only the containing App factory selects the real directory. No lock-file deletion.
final class ManagedAppLease {
    private let descriptor: Int32
    init(directory: URL, ownerUID: UInt32) throws {
        guard directory.isFileURL else { throw ManagedTransferError.unavailable }
        guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else {
            throw ManagedTransferError.unavailable
        }
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard dir >= 0 else { throw ManagedTransferError.unavailable }
        defer { close(dir) }
        var ds = stat()
        guard fstat(dir, &ds) == 0, ds.st_uid == ownerUID, ds.st_mode & 0o077 == 0 else {
            throw ManagedTransferError.unavailable
        }
        let fd = openat(dir, "control.lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ManagedTransferError.unavailable }
        var fs = stat()
        guard fstat(fd, &fs) == 0, fs.st_uid == ownerUID, fs.st_nlink == 1,
              fs.st_mode & S_IFMT == S_IFREG, fs.st_mode & 0o077 == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw ManagedTransferError.busy
        }
        descriptor = fd
    }
    deinit { close(descriptor) }
}
