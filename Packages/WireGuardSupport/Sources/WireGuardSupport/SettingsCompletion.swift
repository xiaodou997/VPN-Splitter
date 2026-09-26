// SPDX-License-Identifier: MIT
import Foundation
import Dispatch

/// One settings request, one waiter, one terminal result. Copied byte-for-byte
/// into the isolated WireGuardKit build. No Provider or network calls here.
/// @unchecked is confined to storage protected by lock; the deadline is immutable.
final class SplitterSettingsCompletion: @unchecked Sendable {
    enum Outcome {
        case success
        case failure(any Error)
        case timedOut
    }

    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private let deadline: DispatchTime
    private var outcome: Outcome?

    init(deadline: DispatchTime) { self.deadline = deadline }

    /// The callback never owns an Adapter, so a late completion cannot restart it.
    /// A callback queued until after the deadline is not accepted as success.
    @discardableResult
    func complete(error: (any Error)?) -> Bool {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return false }
        let inTime = DispatchTime.now() < deadline
        if inTime {
            outcome = error.map(Outcome.failure) ?? .success
        } else {
            outcome = .timedOut
        }
        lock.unlock()
        signal.signal()
        return inTime
    }

    /// Must not block the queue that delivers the OS completion. This timeout
    /// bounds our wait only: it does not cancel or roll back the OS request.
    func wait() -> Outcome {
        _ = signal.wait(timeout: deadline)
        lock.lock()
        defer { lock.unlock() }
        if let outcome { return outcome }
        outcome = .timedOut
        return .timedOut
    }
}

// Shared admission support is copied with the completion gate into WireGuardKit.
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

public enum SplitterAdmissionError: Error, Equatable, Sendable {
    case revoked, staleRevision, configurationChanged, invalidDescriptor
    case descriptorClosed, ownerMismatch, unsupportedPlatform
}

/// Caller-maintained identity, not OS discovery or proof of Provider ownership.
public struct SplitterRuntimeRevision: Equatable, Sendable {
    public let providerInstance: UUID
    public let session: UUID
    public let generation: UInt64
    public let networkEpoch: UInt64
    public let credentialBinding: UUID

    public init(providerInstance: UUID, session: UUID, generation: UInt64,
                networkEpoch: UInt64, credentialBinding: UUID) {
        self.providerInstance = providerInstance; self.session = session
        self.generation = generation; self.networkEpoch = networkEpoch
        self.credentialBinding = credentialBinding
    }
}

/// Once revoked or observed stale this gate cannot be revived by an ABA revision.
/// Checking never claims to cancel an in-flight system call or undo its effects.
public final class SplitterRevisionGate: @unchecked Sendable {
    public let expected: SplitterRuntimeRevision
    private let lock = NSLock()
    private var revoked = false
    public init(expected: SplitterRuntimeRevision) { self.expected = expected }
    public func invalidate() { lock.lock(); revoked = true; lock.unlock() }
    public func check(current: SplitterRuntimeRevision?) throws {
        lock.lock(); defer { lock.unlock() }
        guard !revoked else { throw SplitterAdmissionError.revoked }
        guard current == expected else {
            revoked = true
            throw SplitterAdmissionError.staleRevision
        }
    }
}

/// Owns a duplicate of ONE explicitly supplied descriptor, never a process scan.
/// The caller must obtain the descriptor AND expected name from its own Provider.
/// Matching an interface name is not proof that the Provider owns that interface.
public final class SplitterTunnelDescriptorLease: @unchecked Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let interfaceName: String
    public let owner: UUID
    private let lock = NSLock()
    private var descriptor: Int32?

    public convenience init(borrowing descriptor: Int32, expectedInterfaceName: String, owner: UUID) throws {
        #if os(macOS)
        try self.init(duplicating: descriptor, expectedInterfaceName: expectedInterfaceName,
                      owner: owner, inspect: Self.inspectUTUN)
        #else
        throw SplitterAdmissionError.unsupportedPlatform
        #endif
    }

    // Internal injection tests real dup/close without making a TUN or using Apple APIs.
    init(duplicating source: Int32, expectedInterfaceName: String, owner: UUID,
         inspect: (Int32, String) throws -> Void) throws {
        guard source >= 0, Self.isInterfaceName(expectedInterfaceName) else {
            throw SplitterAdmissionError.invalidDescriptor
        }
        let copied = fcntl(source, F_DUPFD_CLOEXEC, 0)
        guard copied >= 0 else { throw SplitterAdmissionError.invalidDescriptor }
        do { try inspect(copied, expectedInterfaceName) }
        catch {
            splitterCloseDescriptor(copied)
            // Never propagate arbitrary inspector text into logs or diagnostics.
            throw SplitterAdmissionError.invalidDescriptor
        }
        self.descriptor = copied; self.interfaceName = expectedInterfaceName; self.owner = owner
    }

    static func isInterfaceName(_ name: String) -> Bool {
        let suffix = name.dropFirst(4)
        return name.hasPrefix("utun") && (1...10).contains(suffix.count)
            && suffix.utf8.allSatisfy { (48...57).contains($0) }
            && (suffix == "0" || suffix.first != "0")
    }

    /// Synchronous, non-reentrant borrow. Do not retain the fd or call close in body.
    /// Close waits for this scope, so fd reuse cannot change the object during handoff.
    public func withFileDescriptor<T>(for owner: UUID, _ body: (Int32) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard self.owner == owner else { throw SplitterAdmissionError.ownerMismatch }
        guard let descriptor else { throw SplitterAdmissionError.descriptorClosed }
        return try body(descriptor)
    }

    @discardableResult
    public func close() -> Bool {
        lock.lock()
        guard let descriptor else { lock.unlock(); return false }
        self.descriptor = nil; lock.unlock()
        // Never retry close by fd number: another thread may already have reused it.
        splitterCloseDescriptor(descriptor)
        return true
    }
    deinit { close() }
    public var description: String { "SplitterTunnelDescriptorLease(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    #if os(macOS)
    private static func inspectUTUN(_ descriptor: Int32, _ expectedName: String) throws {
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout.size(ofValue: address))
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(descriptor, $0, &length)
            }
        }
        guard result == 0, length >= 2, Int32(address.ss_family) == AF_SYSTEM else {
            throw SplitterAdmissionError.invalidDescriptor
        }
        var kind: Int32 = 0
        var kindLength = socklen_t(MemoryLayout.size(ofValue: kind))
        guard getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &kind, &kindLength) == 0,
              kind == SOCK_DGRAM else { throw SplitterAdmissionError.invalidDescriptor }
        var name = [UInt8](repeating: 0, count: Int(IFNAMSIZ))
        var nameLength = socklen_t(name.count)
        let status = name.withUnsafeMutableBytes {
            getsockopt(descriptor, 2 /* SYSPROTO_CONTROL */, 2 /* UTUN_OPT_IFNAME */,
                       $0.baseAddress, &nameLength)
        }
        guard status == 0, nameLength > 0, Int(nameLength) <= name.count,
              let end = name.prefix(Int(nameLength)).firstIndex(of: 0),
              String(decoding: name[..<end], as: UTF8.self) == expectedName else {
            throw SplitterAdmissionError.invalidDescriptor
        }
    }
    #endif
}

private func splitterCloseDescriptor(_ descriptor: Int32) {
    #if os(macOS)
    _ = Darwin.close(descriptor)
    #elseif os(Linux)
    _ = Glibc.close(descriptor)
    #endif
}
