// SPDX-License-Identifier: MIT
import Foundation
import XCTest
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif
@testable import ProviderConfiguration

/// Real filesystem operations only in a newly created temporary test directory.
/// These do not validate App signing, Keychain, NE preferences or macOS flock behavior.
final class ManagedAppLeaseTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
    func testNewAndExistingDirectoryCanOpenAfterRelease() throws {
        try withDirectory { root in
            let dir = root.appendingPathComponent("managed")
            var first: ManagedAppLease? = try ManagedAppLease(directory: dir, ownerUID: getuid())
            XCTAssertNotNil(first); first = nil
            let next = try ManagedAppLease(directory: dir, ownerUID: getuid())
            withExtendedLifetime(next) { XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("control.lock").path)) }
        }
    }
    func testConcurrentWriterRejectedWithoutRemovingLock() throws {
        try withDirectory { root in
            let dir = root.appendingPathComponent("managed")
            let first = try ManagedAppLease(directory: dir, ownerUID: getuid())
            try withExtendedLifetime(first) { XCTAssertThrowsError(try ManagedAppLease(directory: dir, ownerUID: getuid())) }
        }
    }
    func testDirectorySymlinkRejected() throws {
        try withDirectory { root in
            let target = root.appendingPathComponent("target")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let link = root.appendingPathComponent("managed")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try ManagedAppLease(directory: link, ownerUID: getuid()))
        }
    }
    func testLockSymlinkRejected() throws {
        try withDirectory { root in
            let dir = root.appendingPathComponent("managed")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let target = root.appendingPathComponent("target"); try Data([1]).write(to: target)
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("control.lock"), withDestinationURL: target)
            XCTAssertThrowsError(try ManagedAppLease(directory: dir, ownerUID: getuid()))
            XCTAssertEqual(try Data(contentsOf: target), Data([1]))
        }
    }
    func testBroadDirectoryPermissionsRejectedWithoutRepairingThem() throws {
        try withDirectory { root in
            let dir = root.appendingPathComponent("managed")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            XCTAssertEqual(chmod(dir.path, 0o755), 0)
            XCTAssertThrowsError(try ManagedAppLease(directory: dir, ownerUID: getuid()))
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("control.lock").path))
        }
    }
    func testWrongOwnerRejected() throws {
        try withDirectory { root in
            XCTAssertThrowsError(try ManagedAppLease(directory: root.appendingPathComponent("managed"), ownerUID: getuid() &+ 1))
        }
    }
}
