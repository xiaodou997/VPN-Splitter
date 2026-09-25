// SPDX-License-Identifier: MIT
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Hold for the app model lifetime. No stale-lock deletion: the OS releases flock on exit.
/// Advisory only: old builds and same-user tools must NOT write concurrently.
public final class WorkspaceLease {
    private let descriptor: Int32
    public init(directory: URL) throws {
        guard directory.isFileURL, !directory.path.utf8.contains(0) else { throw CredentialError.workspaceInUse }
        do {
            var parent = directory.standardizedFileURL
            while parent.path != "/" {
                if (try? parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    throw CredentialError.workspaceInUse
                }
                parent.deleteLastPathComponent()
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        } catch { throw CredentialError.workspaceInUse }
        let file = directory.appendingPathComponent("workspace.lock")
        let fd = file.path.withCString { open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw CredentialError.workspaceInUse }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_nlink == 1, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw CredentialError.workspaceInUse
        }
        guard fchmod(fd, 0o600) == 0 else { close(fd); throw CredentialError.workspaceInUse }
        descriptor = fd
    }
    deinit { close(descriptor) }
}
