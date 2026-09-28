// SPDX-License-Identifier: MIT
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// User-local documents, not a privileged Helper or recovery journal. Cooperative
/// writers share a non-unlinked lock; expectedRevision prevents stale editors replacing newer data.
public actor ExternalProfileStore {
    public static let maximumBytes = 262_144
    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    public static func applicationStore() throws -> ExternalProfileStore {
        guard getuid() != 0, geteuid() == getuid(),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ExternalProfileError.unsafeStorage
        }
        // Only this new application-specific folder. No LocalDev data/keychain migration.
        return ExternalProfileStore(directory: support.appendingPathComponent("io.github.xiaodou997.VPNSplitter.ExternalProfiles", isDirectory: true))
    }
    public func load() throws -> ExternalProfileWorkspace {
        try withDirectory { dir in try Self.read(dir) }
    }
    public func save(_ candidate: ExternalProfileWorkspace, expectedRevision: UUID?) throws -> ExternalProfileWorkspace {
        var next = try candidate.validated()
        guard candidate.revision == expectedRevision else { throw ExternalProfileError.staleRevision }
        return try withDirectory { dir in
            let current = try Self.read(dir)
            guard current.revision == expectedRevision else { throw ExternalProfileError.staleRevision }
            next.revision = UUID()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data: Data
            do { data = try encoder.encode(next) } catch { throw ExternalProfileError.writeFailed }
            guard data.count <= Self.maximumBytes else { throw ExternalProfileError.limitExceeded }
            let name = ".pending-" + UUID().uuidString
            let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ExternalProfileError.writeFailed }
            var renamed = false
            defer {
                if !renamed && Self.namedMatches(dir: dir, name: name, fd: fd) { _ = unlinkat(dir, name, 0) }
                close(fd)
            }
            try Self.write(data, fd: fd)
            guard fsync(fd) == 0 else { throw ExternalProfileError.writeFailed }
            // Re-read while holding the cooperative lock. No claims of atomic CAS
            // against arbitrary non-cooperating same-user writes outside this store.
            guard try Self.read(dir) == current else { throw ExternalProfileError.staleRevision }
            guard renameat(dir, name, dir, "profiles.json") == 0 else { throw ExternalProfileError.writeFailed }
            renamed = true
            guard fsync(dir) == 0 else { throw ExternalProfileError.saveUncertain }
            do {
                guard try Self.read(dir) == next else { throw ExternalProfileError.saveUncertain }
            } catch { throw ExternalProfileError.saveUncertain }
            return next
        }
    }
    private func withDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        guard directory.isFileURL, directory.path.hasPrefix("/"), getuid() == geteuid() else {
            throw ExternalProfileError.unsafeStorage
        }
        // The standard Application Support parent is OS/user managed. Validate our
        // own leaf with no-follow; never chmod or remove a pre-existing foreign path.
        let parent = directory.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else { throw ExternalProfileError.unsafeStorage }
        let made = directory.path.withCString { mkdir($0, 0o700) }
        guard made == 0 || errno == EEXIST else { throw ExternalProfileError.writeFailed }
        let dir = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard dir >= 0 else { throw ExternalProfileError.unsafeStorage }
        defer { close(dir) }
        var info = stat()
        guard fstat(dir, &info) == 0, info.st_uid == getuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_mode & 0o777 == 0o700 else { throw ExternalProfileError.unsafeStorage }
        let lock = openat(dir, "profiles.lock", O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw ExternalProfileError.unsafeStorage }
        defer { close(lock) } // Never unlink the lock inode.
        guard Self.regular(lock), Self.namedMatches(dir: dir, name: "profiles.lock", fd: lock) else {
            throw ExternalProfileError.unsafeStorage
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw ExternalProfileError.busy }
            throw ExternalProfileError.unsafeStorage
        }
        return try body(dir)
    }
    private static func regular(_ fd: Int32) -> Bool {
        var value = stat()
        return fstat(fd, &value) == 0 && value.st_uid == getuid() && value.st_nlink == 1 &&
            value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && value.st_mode & 0o777 == 0o600
    }
    private static func namedMatches(dir: Int32, name: String, fd: Int32) -> Bool {
        var opened = stat(), named = stat()
        return fstat(fd, &opened) == 0 && fstatat(dir, name, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
            opened.st_dev == named.st_dev && opened.st_ino == named.st_ino && named.st_nlink == 1 &&
            named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }
    private static func read(_ dir: Int32) throws -> ExternalProfileWorkspace {
        let fd = openat(dir, "profiles.json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return ExternalProfileWorkspace() }
            throw ExternalProfileError.unsafeStorage
        }
        defer { close(fd) }
        var info = stat()
        guard regular(fd), fstat(fd, &info) == 0, info.st_size > 0, info.st_size <= maximumBytes else {
            throw ExternalProfileError.unsafeStorage
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size) + 1)
        var used = 0
        while used < bytes.count {
            let n = bytes.withUnsafeMutableBytes { buffer in
                #if canImport(Darwin)
                return Darwin.read(fd, buffer.baseAddress!.advanced(by: used), buffer.count - used)
                #else
                return Glibc.read(fd, buffer.baseAddress!.advanced(by: used), buffer.count - used)
                #endif
            }
            if n == 0 { break }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw ExternalProfileError.readFailed }
            used += n
        }
        guard used == info.st_size, regular(fd), namedMatches(dir: dir, name: "profiles.json", fd: fd) else {
            throw ExternalProfileError.readFailed
        }
        do {
            return try JSONDecoder().decode(ExternalProfileWorkspace.self, from: Data(bytes.prefix(used))).validated(persisted: true)
        } catch let failure as ExternalProfileError { throw failure }
        catch { throw ExternalProfileError.invalidDocument }
    }
    private static func write(_ data: Data, fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { buffer in
                #if canImport(Darwin)
                return Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                #else
                return Glibc.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                #endif
            }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw ExternalProfileError.writeFailed }
            offset += n
        }
    }
}
