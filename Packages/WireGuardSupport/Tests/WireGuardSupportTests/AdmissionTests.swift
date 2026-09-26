// SPDX-License-Identifier: MIT
import Foundation
import Dispatch
import Testing
@testable import WireGuardSupport
#if os(macOS)
import Darwin
#else
import Glibc
#endif

private func revision() -> SplitterRuntimeRevision {
    .init(providerInstance: UUID(), session: UUID(), generation: 2, networkEpoch: 3, credentialBinding: UUID())
}

@Suite struct RevisionTests {
    @Test func exactCurrentRevisionAccepted() throws {
        let r = revision(), gate = SplitterRevisionGate(expected: revision())
        #expect(throws: SplitterAdmissionError.staleRevision) { try gate.check(current: r) }
        let matching = SplitterRevisionGate(expected: r)
        try matching.check(current: r); try matching.check(current: r)
    }

    @Test(arguments: 0..<5) func everyRevisionFieldIsBinding(_ field: Int) {
        let r = revision()
        let changed = SplitterRuntimeRevision(providerInstance: field == 0 ? UUID() : r.providerInstance,
            session: field == 1 ? UUID() : r.session, generation: field == 2 ? 9 : r.generation,
            networkEpoch: field == 3 ? 9 : r.networkEpoch,
            credentialBinding: field == 4 ? UUID() : r.credentialBinding)
        let gate = SplitterRevisionGate(expected: r)
        #expect(throws: SplitterAdmissionError.staleRevision) { try gate.check(current: changed) }
        #expect(throws: SplitterAdmissionError.revoked) { try gate.check(current: r) }
    }

    @Test func missingRevisionRevokesWithoutFallback() {
        let r = revision(), gate = SplitterRevisionGate(expected: revision())
        #expect(throws: SplitterAdmissionError.staleRevision) { try gate.check(current: nil) }
        #expect(throws: SplitterAdmissionError.revoked) { try gate.check(current: r) }
    }

    @Test func explicitInvalidationIsPermanentAndIndependent() throws {
        let r = revision(), first = SplitterRevisionGate(expected: revision())
        let second = SplitterRevisionGate(expected: r)
        first.invalidate(); first.invalidate()
        #expect(throws: SplitterAdmissionError.revoked) { try first.check(current: first.expected) }
        try second.check(current: r)
    }

    @Test func concurrentCheckAndRevokeNeverRevives() {
        let r = revision()
        let gate = SplitterRevisionGate(expected: r)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            if index % 3 == 0 { gate.invalidate() }
            else { try? gate.check(current: r) }
        }
        #expect(throws: SplitterAdmissionError.revoked) { try gate.check(current: gate.expected) }
    }

    @Test func successfulSettingsCompletionCannotAuthorizeStaleSession() {
        let r = revision(), gate = SplitterRevisionGate(expected: revision())
        let completion = SplitterSettingsCompletion(deadline: .now() + .seconds(5))
        #expect(completion.complete(error: nil))
        if case .success = completion.wait() {} else { Issue.record("Completion expected") }
        #expect(throws: SplitterAdmissionError.staleRevision) { try gate.check(current: r) }
    }
}

// No TUN or protocol. Native file handles with an explicitly injected inspector.
@Suite(.serialized) struct DescriptorLeaseTests {
    private func source(_ body: (Int32) throws -> Void) throws {
        let file = Pipe()
        defer { try? file.fileHandleForReading.close(); try? file.fileHandleForWriting.close() }
        try body(file.fileHandleForReading.fileDescriptor)
    }

    private func lease(_ fd: Int32, owner: UUID = UUID()) throws -> SplitterTunnelDescriptorLease {
        try SplitterTunnelDescriptorLease(duplicating: fd, expectedInterfaceName: "utun7", owner: owner) { copy, name in
            #expect(copy != fd && name == "utun7")
            #expect(fcntl(copy, F_GETFD) & FD_CLOEXEC != 0)
        }
    }

    @Test func duplicateIsDistinctAndCloseDoesNotCloseSource() throws {
        try source { fd in
            let leased = try lease(fd)
            try leased.withFileDescriptor(for: leased.owner) { copy in #expect(copy != fd) }
            #expect(leased.close()); #expect(!leased.close())
            #expect(fcntl(fd, F_GETFD) >= 0)
            #expect(throws: SplitterAdmissionError.descriptorClosed) {
                try leased.withFileDescriptor(for: leased.owner) { _ in Issue.record("Must not borrow") }
            }
        }
    }

    @Test func wrongOwnerCannotBorrow() throws {
        try source { fd in
            let leased = try lease(fd); defer { leased.close() }
            #expect(throws: SplitterAdmissionError.ownerMismatch) {
                try leased.withFileDescriptor(for: UUID()) { _ in Issue.record("Must not borrow") }
            }
            try leased.withFileDescriptor(for: leased.owner) { #expect(fcntl($0, F_GETFD) >= 0) }
        }
    }

    @Test func inspectorFailureClosesOnlyDuplicate() throws {
        enum Failure: Error { case sensitiveInput }
        try source { fd in
            var copied: Int32 = -1
            #expect(throws: SplitterAdmissionError.invalidDescriptor) {
                try SplitterTunnelDescriptorLease(duplicating: fd, expectedInterfaceName: "utun1", owner: UUID()) { copy, _ in
                    copied = copy; throw Failure.sensitiveInput
                }
            }
            #expect(copied >= 0 && copied != fd)
            #expect(fcntl(copied, F_GETFD) == -1)
            #expect(fcntl(fd, F_GETFD) >= 0)
        }
    }

    @Test(arguments: ["", "en0", "utun", "utun01", "utun-1", "utun1\n", "utun99999999999", "utun一"])
    func invalidNamesFailBeforeDupOrInspection(_ name: String) throws {
        try source { fd in
            #expect(throws: SplitterAdmissionError.invalidDescriptor) {
                try SplitterTunnelDescriptorLease(duplicating: fd, expectedInterfaceName: name, owner: UUID()) { _, _ in
                    Issue.record("Must validate before inspection")
                }
            }
        }
    }

    @Test func invalidDescriptorDoesNotCallInspector() {
        for fd: Int32 in [-1, .max] {
            #expect(throws: SplitterAdmissionError.invalidDescriptor) {
                try SplitterTunnelDescriptorLease(duplicating: fd, expectedInterfaceName: "utun0", owner: UUID()) { _, _ in
                    Issue.record("Must not inspect invalid fd")
                }
            }
        }
    }

    @Test func throwingBorrowStillReleasesLock() throws {
        enum Failure: Error { case operation }
        try source { fd in
            let leased = try lease(fd)
            #expect(throws: Failure.operation) { try leased.withFileDescriptor(for: leased.owner) { _ in throw Failure.operation } }
            #expect(leased.close())
        }
    }

    @Test func closeWaitsForActiveBorrow() throws {
        try source { fd in
            let leased = try lease(fd)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let closeDone = DispatchSemaphore(value: 0), borrowDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                do {
                    try leased.withFileDescriptor(for: leased.owner) { copy in
                        entered.signal()
                        #expect(release.wait(timeout: .now() + .seconds(5)) == .success)
                        #expect(fcntl(copy, F_GETFD) >= 0)
                    }
                } catch { Issue.record("Borrow unexpectedly failed") }
                borrowDone.signal()
            }
            #expect(entered.wait(timeout: .now() + .seconds(5)) == .success)
            DispatchQueue.global().async { leased.close(); closeDone.signal() }
            #expect(closeDone.wait(timeout: .now() + .milliseconds(10)) == .timedOut)
            release.signal()
            #expect(borrowDone.wait(timeout: .now() + .seconds(5)) == .success)
            #expect(closeDone.wait(timeout: .now() + .seconds(5)) == .success)
            #expect(!leased.close())
        }
    }

    @Test func closedLeaseCannotBorrowReusedSource() throws {
        try source { fd in
            let old = try lease(fd); old.close()
            let new = try lease(fd); defer { new.close() }
            #expect(throws: SplitterAdmissionError.descriptorClosed) { try old.withFileDescriptor(for: old.owner) { _ in } }
            try new.withFileDescriptor(for: new.owner) { #expect(fcntl($0, F_GETFD) >= 0) }
        }
    }

    @Test func deinitReleasesDuplicateWithoutClosingSource() throws {
        try source { fd in
            var object: SplitterTunnelDescriptorLease? = try lease(fd)
            weak var weakObject = object
            var copy: Int32 = -1
            try object?.withFileDescriptor(for: object!.owner) { copy = $0 }
            object = nil
            #expect(weakObject == nil && fcntl(copy, F_GETFD) == -1)
            #expect(fcntl(fd, F_GETFD) >= 0)
        }
    }

    @Test func reflectionDoesNotExposeDescriptorOrOwner() throws {
        try source { fd in
            let object = try lease(fd); defer { object.close() }
            #expect(String(reflecting: object).contains("<redacted>"))
            #expect(Mirror(reflecting: object).children.isEmpty)
            #expect(!String(describing: object).contains(object.owner.uuidString))
        }
    }

    @Test func publicAcquisitionRejectsNonUTUNWithoutNetworkCalls() throws {
        try source { fd in
            #if os(macOS)
            #expect(throws: SplitterAdmissionError.invalidDescriptor) {
                try SplitterTunnelDescriptorLease(borrowing: fd, expectedInterfaceName: "utun7", owner: UUID())
            }
            #else
            #expect(throws: SplitterAdmissionError.unsupportedPlatform) {
                try SplitterTunnelDescriptorLease(borrowing: fd, expectedInterfaceName: "utun7", owner: UUID())
            }
            #endif
            #expect(fcntl(fd, F_GETFD) >= 0)
        }
    }
}
