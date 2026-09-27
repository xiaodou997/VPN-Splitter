// SPDX-License-Identifier: MIT
import Foundation
import ExternalCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Root-local write-ahead intent, NOT a serialized route ownership receipt.
/// Startup NEVER deletes routes from this file. A new invocation may only audit
/// all planned prefixes and clear the marker after independent all-scope absence.
public final class ExternalLeaseFileJournal: ExternalLeaseJournaling {
    private struct Header: Codable {
        let schema: String
        let session: UUID
        let routes: [ExternalLeaseRoute]
    }
    private let directoryFD: Int32
    private let lockFD: Int32
    private let owner: uid_t
    private var activeFD: Int32 = -1
    private var count = 0
    private var auditedRoutes: [ExternalLeaseRoute]?
    private static let schema = "external-lease-intent-v1"
    private static let events: Set<String> = ["willAdd", "addAcknowledged", "addReadback", "willRemove", "removeReadback", "alreadyAbsent"]
    public static func foregroundHost() throws -> ExternalLeaseFileJournal {
        guard getuid() == 0, geteuid() == 0 else { throw ExternalLeaseFailure.consentRequired }
        // Parent is OS-owned. Never use HOME, SUDO_UID, a user-provided filename, or
        // a path inside the writable checkout for root journal/lock publication.
        return try .init(directory: URL(fileURLWithPath: "/private/var/run/io.github.xiaodou997.VPNSplitter.ExternalLease"), owner: 0)
    }
    // Internal injection for temporary-file tests. Production uses only foregroundHost().
    init(directory: URL, owner: uid_t) throws {
        let made = directory.path.withCString { mkdir($0, 0o700) }
        guard made == 0 || errno == EEXIST else { throw ExternalLeaseFailure.journalFailed }
        let dir = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard dir >= 0 else { throw ExternalLeaseFailure.journalFailed }
        var info = stat()
        guard fstat(dir, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == owner, info.st_mode & 0o777 == 0o700 else {
            close(dir); throw ExternalLeaseFailure.journalFailed
        }
        let lock = openat(dir, "lease.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { close(dir); throw ExternalLeaseFailure.journalFailed }
        guard Self.regular(lock, owner: owner), flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock); close(dir); throw ExternalLeaseFailure.journalFailed
        }
        directoryFD = dir; lockFD = lock; self.owner = owner
    }
    deinit {
        if activeFD >= 0 { close(activeFD) }
        close(lockFD); close(directoryFD) // Never unlink a lock to release it.
    }
    public func begin(session: UUID, routes: [ExternalLeaseRoute]) throws {
        guard activeFD < 0, (1...8).contains(routes.count) else { throw ExternalLeaseFailure.journalFailed }
        let data: Data
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(Header(schema: Self.schema, session: session, routes: routes)) + Data([10])
        } catch { throw ExternalLeaseFailure.journalFailed }
        guard data.count <= 8192 else { throw ExternalLeaseFailure.journalFailed }
        let fd = openat(directoryFD, "active", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ExternalLeaseFailure.recoveryRequired }
        activeFD = fd; count = routes.count
        guard Self.regular(fd, owner: owner) else { throw ExternalLeaseFailure.journalFailed }
        // A failed/partial write leaves its marker and blocks another lease. No
        // route write occurs until both file and directory synchronization succeed.
        try writeAll(data, to: fd)
        guard fsync(fd) == 0, fsync(directoryFD) == 0 else { throw ExternalLeaseFailure.journalFailed }
    }
    public func record(_ event: String, index: Int) throws {
        guard activeFD >= 0, index >= 0, index < count, Self.events.contains(event) else {
            throw ExternalLeaseFailure.journalFailed
        }
        try writeAll(Data("\(index) \(event)\n".utf8), to: activeFD)
        guard fsync(activeFD) == 0 else { throw ExternalLeaseFailure.journalFailed }
    }
    public func finish() throws {
        guard activeFD >= 0, Self.regular(activeFD, owner: owner), namedFileMatchesDescriptor() else {
            throw ExternalLeaseFailure.journalFailed
        }
        guard unlinkat(directoryFD, "active", 0) == 0 else { throw ExternalLeaseFailure.journalFailed }
        let fd = activeFD; activeFD = -1; close(fd)
        guard fsync(directoryFD) == 0 else { throw ExternalLeaseFailure.journalFailed }
    }
    /// Reads only our bounded private marker. No material from it can authorize
    /// RTM_DELETE or recreate a native receipt after process/observation loss.
    public func auditCandidates() throws -> [ExternalLeaseRoute] {
        guard activeFD < 0 else { throw ExternalLeaseFailure.invalidState }
        let fd = openat(directoryFD, "active", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0, Self.regular(fd, owner: owner) else {
            if fd >= 0 { close(fd) }; throw ExternalLeaseFailure.journalFailed
        }
        activeFD = fd
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0, info.st_size <= 16_384 else { throw ExternalLeaseFailure.journalFailed }
        var bytes = [UInt8](repeating: 0, count: 16_385); var used = 0
        while used < bytes.count {
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: used), $0.count - used) }
            if n == 0 { break }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw ExternalLeaseFailure.journalFailed }
            used += n
        }
        guard used <= 16_384, let newline = bytes.prefix(used).firstIndex(of: 10), newline <= 8192 else {
            throw ExternalLeaseFailure.journalFailed
        }
        do {
            let header = try JSONDecoder().decode(Header.self, from: Data(bytes.prefix(newline)))
            guard header.schema == Self.schema, (1...8).contains(header.routes.count),
                  Set(header.routes).count == header.routes.count,
                  header.routes.allSatisfy({ (24...32).contains($0.destination.prefixLength) &&
                      (1...32).contains($0.interface.utf8.count) && $0.interface.utf8.allSatisfy {
                          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45
                      } }) else { throw ExternalLeaseFailure.journalFailed }
            count = header.routes.count; auditedRoutes = header.routes
            return header.routes
        } catch { throw ExternalLeaseFailure.journalFailed }
    }
    public func clearAuditedAbsence(routes: [ExternalLeaseRoute], observation: ExternalObservation,
                                    uptime: TimeInterval) throws {
        try observation.checkFresh(now: uptime)
        guard activeFD >= 0, auditedRoutes == routes, count == routes.count, !routes.isEmpty,
              routes.allSatisfy({ item in !observation.routes.contains { row in
                  row.destination.prefixLength >= item.destination.prefixLength && item.destination.contains(row.destination.networkAddress)
              } }) else { throw ExternalLeaseFailure.recoveryRequired }
        try finish() // Removes only the audit marker, never a kernel route.
    }
    private func namedFileMatchesDescriptor() -> Bool {
        var opened = stat(), named = stat()
        return fstat(activeFD, &opened) == 0 && fstatat(directoryFD, "active", &named, AT_SYMLINK_NOFOLLOW) == 0 &&
            opened.st_dev == named.st_dev && opened.st_ino == named.st_ino && named.st_nlink == 1 &&
            named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && named.st_uid == owner
    }
    private static func regular(_ fd: Int32, owner: uid_t) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) &&
            info.st_uid == owner && info.st_nlink == 1 && info.st_mode & 0o777 == 0o600
    }
    private func writeAll(_ data: Data, to fd: Int32) throws {
        var done = 0
        while done < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: done), $0.count - done) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw ExternalLeaseFailure.journalFailed }
            done += n
        }
    }
}
