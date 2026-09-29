// SPDX-License-Identifier: MIT
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// User-local diagnostic bridge only. This file is never network authority and
/// contains counts/status only, not hostnames, App IDs, IPs, ports or payloads.
public actor ExternalFlowProbeSnapshotStore {
    public static let maximumBytes = 16_384
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func applicationStore() throws -> ExternalFlowProbeSnapshotStore {
        guard getuid() != 0, geteuid() == getuid(),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ExternalFlowProbeStoreError.unsafeStorage
        }
        return .init(directory: support.appendingPathComponent(
            "io.github.xiaodou997.VPNSplitter.FlowProbeBridge", isDirectory: true))
    }

    public func load() throws -> ExternalFlowProbeSnapshot? {
        try withDirectory { dir in
            let fd = openat(dir, "snapshot.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 {
                if errno == ENOENT { return nil }
                throw ExternalFlowProbeStoreError.readFailed
            }
            defer { close(fd) }
            var info = stat()
            guard Self.regular(fd), fstat(fd, &info) == 0,
                  info.st_size > 0, info.st_size <= Self.maximumBytes else {
                throw ExternalFlowProbeStoreError.unsafeStorage
            }
            var bytes = [UInt8](repeating: 0, count: Int(info.st_size) + 1)
            var used = 0
            while used < Int(info.st_size) {
                let n = bytes.withUnsafeMutableBytes { raw in
                    read(fd, raw.baseAddress!.advanced(by: used), Int(info.st_size) - used)
                }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ExternalFlowProbeStoreError.readFailed }
                used += n
            }
            guard used == info.st_size, Self.namedMatches(dir, "snapshot.json", fd) else {
                throw ExternalFlowProbeStoreError.readFailed
            }
            do {
                return try JSONDecoder().decode(ExternalFlowProbeSnapshot.self,
                    from: Data(bytes.prefix(used))).validated()
            } catch let error as ExternalFlowProbeWireError { throw error }
            catch { throw ExternalFlowProbeStoreError.invalidDocument }
        }
    }

    public func save(_ snapshot: ExternalFlowProbeSnapshot) throws {
        let value = try snapshot.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumBytes else { throw ExternalFlowProbeStoreError.writeFailed }

        try withDirectory { dir in
            let name = ".pending-" + UUID().uuidString
            let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ExternalFlowProbeStoreError.writeFailed }
            var renamed = false
            defer {
                if !renamed { _ = unlinkat(dir, name, 0) }
                close(fd)
            }
            var offset = 0
            while offset < data.count {
                let n = data.withUnsafeBytes { raw in
                    write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
                }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ExternalFlowProbeStoreError.writeFailed }
                offset += n
            }
            guard fsync(fd) == 0, Self.regular(fd),
                  renameat(dir, name, dir, "snapshot.json") == 0 else {
                throw ExternalFlowProbeStoreError.writeFailed
            }
            renamed = true
            guard fsync(dir) == 0 else { throw ExternalFlowProbeStoreError.writeFailed }
        }
    }

    private func withDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw ExternalFlowProbeStoreError.unsafeStorage
        }
        let parent = directory.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw ExternalFlowProbeStoreError.unsafeStorage
        }
        let made = directory.path.withCString { mkdir($0, 0o700) }
        guard made == 0 || errno == EEXIST else { throw ExternalFlowProbeStoreError.writeFailed }
        let dir = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard dir >= 0 else { throw ExternalFlowProbeStoreError.unsafeStorage }
        defer { close(dir) }
        var info = stat()
        guard fstat(dir, &info) == 0, info.st_uid == getuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_mode & 0o777 == 0o700 else {
            throw ExternalFlowProbeStoreError.unsafeStorage
        }
        return try body(dir)
    }

    private static func regular(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_uid == getuid() &&
            info.st_nlink == 1 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) &&
            info.st_mode & 0o777 == 0o600
    }

    private static func namedMatches(_ dir: Int32, _ name: String, _ fd: Int32) -> Bool {
        var opened = stat(), named = stat()
        return fstat(fd, &opened) == 0 &&
            fstatat(dir, name, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
            opened.st_dev == named.st_dev && opened.st_ino == named.st_ino &&
            named.st_nlink == 1 && named.st_uid == getuid() &&
            named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }
}

public enum ExternalFlowProbeStoreError: String, Error, Sendable {
    case unsafeStorage, readFailed, writeFailed, invalidDocument
}
