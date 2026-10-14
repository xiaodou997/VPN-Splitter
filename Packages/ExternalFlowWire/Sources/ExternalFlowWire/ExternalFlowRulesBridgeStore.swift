// SPDX-License-Identifier: MIT
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// User-local rules bridge for the FLOW-02 trial channel. The main app writes
/// the selected profile's rules here after an explicit user action; the Flow
/// Probe App reads them on explicit reload and copies them into the provider
/// configuration. Same-user processes could forge this file, so it only
/// expresses DIRECT intent — the provider re-validates and re-compiles the
/// whole set and rejects it entirely on any error. It never contains
/// credentials, live hostnames, or traffic metadata.
public actor ExternalFlowRulesBridgeStore {
    public static let maximumBytes = 65_536
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func applicationStore() throws -> ExternalFlowRulesBridgeStore {
        guard getuid() != 0, geteuid() == getuid(),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ExternalFlowRulesBridgeStoreError.unsafeStorage
        }
        return .init(directory: support.appendingPathComponent(
            "io.github.xiaodou997.VPNSplitter.FlowProbeBridge", isDirectory: true))
    }

    public func load() throws -> ExternalFlowRulesWire? {
        try withDirectory { dir in
            let fd = openat(dir, "rules.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 {
                if errno == ENOENT { return nil }
                throw ExternalFlowRulesBridgeStoreError.readFailed
            }
            defer { close(fd) }
            var info = stat()
            guard Self.regular(fd), fstat(fd, &info) == 0,
                  info.st_size > 0, info.st_size <= Self.maximumBytes else {
                throw ExternalFlowRulesBridgeStoreError.unsafeStorage
            }
            var bytes = [UInt8](repeating: 0, count: Int(info.st_size) + 1)
            var used = 0
            while used < Int(info.st_size) {
                let n = bytes.withUnsafeMutableBytes { raw in
                    read(fd, raw.baseAddress!.advanced(by: used), Int(info.st_size) - used)
                }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ExternalFlowRulesBridgeStoreError.readFailed }
                used += n
            }
            guard used == info.st_size, Self.namedMatches(dir, "rules.json", fd) else {
                throw ExternalFlowRulesBridgeStoreError.readFailed
            }
            do {
                return try JSONDecoder().decode(ExternalFlowRulesWire.self,
                    from: Data(bytes.prefix(used))).validated()
            } catch let error as ExternalFlowRulesWireError { throw error }
            catch { throw ExternalFlowRulesBridgeStoreError.invalidDocument }
        }
    }

    public func save(_ rules: ExternalFlowRulesWire) throws {
        let value = try rules.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumBytes else { throw ExternalFlowRulesBridgeStoreError.writeFailed }

        try withDirectory { dir in
            let name = ".pending-" + UUID().uuidString
            let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ExternalFlowRulesBridgeStoreError.writeFailed }
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
                guard n > 0 else { throw ExternalFlowRulesBridgeStoreError.writeFailed }
                offset += n
            }
            guard fsync(fd) == 0, Self.regular(fd),
                  renameat(dir, name, dir, "rules.json") == 0 else {
                throw ExternalFlowRulesBridgeStoreError.writeFailed
            }
            renamed = true
            guard fsync(dir) == 0 else { throw ExternalFlowRulesBridgeStoreError.writeFailed }
        }
    }

    private func withDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw ExternalFlowRulesBridgeStoreError.unsafeStorage
        }
        let parent = directory.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw ExternalFlowRulesBridgeStoreError.unsafeStorage
        }
        let made = directory.path.withCString { mkdir($0, 0o700) }
        guard made == 0 || errno == EEXIST else { throw ExternalFlowRulesBridgeStoreError.writeFailed }
        let dir = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard dir >= 0 else { throw ExternalFlowRulesBridgeStoreError.unsafeStorage }
        defer { close(dir) }
        var info = stat()
        guard fstat(dir, &info) == 0, info.st_uid == getuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_mode & 0o777 == 0o700 else {
            throw ExternalFlowRulesBridgeStoreError.unsafeStorage
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

public enum ExternalFlowRulesBridgeStoreError: String, Error, Sendable {
    case unsafeStorage, readFailed, writeFailed, invalidDocument
}
