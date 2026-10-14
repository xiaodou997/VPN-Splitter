// SPDX-License-Identifier: MIT
import XCTest
import PolicyCore
import ExternalCore
import ExternalFlowWire
@testable import ExternalFlowCore

/// Scripted in-memory pipe. Reads follow the script; when the script is
/// exhausted the read suspends until `push`, `finishReads` or `close`.
private struct FakeFailure: Error {}

/// NSLock is unavailable directly inside async contexts; this box confines all
/// locking to synchronous helpers.
private final class LockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}

private final class FakePipe: ExternalFlowPipe, @unchecked Sendable {
    enum Step { case data(Data), eof, fail }

    private struct State {
        var script: [Step]
        var waiters: [CheckedContinuation<Data?, Error>] = []
        var written: [Data] = []
        var writeClosed = false
        var closed = false
        var writeError: (any Error)?
    }
    private let state: LockedBox<State>

    init(_ script: [Step]) { state = LockedBox(State(script: script)) }

    var written: [Data] { state.withLock { $0.written } }
    var writeClosed: Bool { state.withLock { $0.writeClosed } }
    var closed: Bool { state.withLock { $0.closed } }
    var writeError: (any Error)? {
        get { state.withLock { $0.writeError } }
        set { state.withLock { $0.writeError = newValue } }
    }

    func push(_ data: Data) {
        let waiter = state.withLock { s -> CheckedContinuation<Data?, Error>? in
            if !s.waiters.isEmpty { return s.waiters.removeFirst() }
            s.script.append(.data(data)); return nil
        }
        waiter?.resume(returning: data)
    }
    func finishReads() {
        let waiter = state.withLock { s -> CheckedContinuation<Data?, Error>? in
            if !s.waiters.isEmpty { return s.waiters.removeFirst() }
            s.script.append(.eof); return nil
        }
        waiter?.resume(returning: nil)
    }

    func readChunk(maxBytes: Int) async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enum Action { case resume(Data?), fail, park }
                let action = state.withLock { s -> Action in
                    if s.closed { return .resume(nil) }
                    if !s.script.isEmpty {
                        switch s.script.removeFirst() {
                        case .data(let data): return .resume(data)
                        case .eof: return .resume(nil)
                        case .fail: return .fail
                        }
                    }
                    s.waiters.append(continuation); return .park
                }
                switch action {
                case .resume(let data): continuation.resume(returning: data)
                case .fail: continuation.resume(throwing: FakeFailure())
                case .park: break
                }
            }
        } onCancel: {
            let pending = state.withLock { s -> [CheckedContinuation<Data?, Error>] in
                let pending = s.waiters; s.waiters.removeAll(); return pending
            }
            for waiter in pending { waiter.resume(throwing: CancellationError()) }
        }
    }
    func writeChunk(_ data: Data) async throws {
        try state.withLock { s in
            if s.closed { throw FakeFailure() }
            if let error = s.writeError { throw error }
            s.written.append(data)
        }
    }
    func closeWrite() async { state.withLock { $0.writeClosed = true } }
    func close() async {
        let pending = state.withLock { s -> [CheckedContinuation<Data?, Error>] in
            s.closed = true
            let pending = s.waiters; s.waiters.removeAll(); return pending
        }
        for waiter in pending { waiter.resume(returning: nil) }
    }
}

final class ExternalFlowRelayCoreTests: XCTestCase {
    func testBidirectionalCopyCompletes() async {
        let local = FakePipe([.data(Data("GET / HTTP/1.1\r\n\r\n".utf8)), .eof])
        let remote = FakePipe([.data(Data("HTTP/1.1 200 OK\r\n\r\n".utf8)), .eof])
        let relay = ExternalFlowRelay(local: local, remote: remote,
                                      limits: .init(maxConcurrent: 1, chunkBytes: 1024, idleTimeout: 30))
        let outcome = await relay.run()
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(remote.written, [Data("GET / HTTP/1.1\r\n\r\n".utf8)])
        XCTAssertEqual(local.written, [Data("HTTP/1.1 200 OK\r\n\r\n".utf8)])
        XCTAssertTrue(remote.writeClosed); XCTAssertTrue(local.writeClosed)
        XCTAssertTrue(local.closed); XCTAssertTrue(remote.closed)
    }

    func testReadErrorFailsAndClosesBothSides() async {
        let local = FakePipe([.fail])
        let remote = FakePipe([.data(Data("x".utf8))])
        let relay = ExternalFlowRelay(local: local, remote: remote,
                                      limits: .init(maxConcurrent: 1, chunkBytes: 1024, idleTimeout: 30))
        let outcome = await relay.run()
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(local.closed); XCTAssertTrue(remote.closed)
    }

    func testWriteFailureFailsAndClosesBothSides() async {
        let local = FakePipe([.data(Data("ping".utf8))])
        let remote = FakePipe([])
        remote.writeError = ExternalFlowRelayRegistry.AdmitError.limitReached
        let relay = ExternalFlowRelay(local: local, remote: remote,
                                      limits: .init(maxConcurrent: 1, chunkBytes: 1024, idleTimeout: 30))
        let outcome = await relay.run()
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(local.closed); XCTAssertTrue(remote.closed)
    }

    func testCancelUnblocksPendingRead() async {
        let local = FakePipe([])
        let remote = FakePipe([])
        let relay = ExternalFlowRelay(local: local, remote: remote,
                                      limits: .init(maxConcurrent: 1, chunkBytes: 1024, idleTimeout: 30))
        let task = Task { await relay.run() }
        try? await Task.sleep(for: .milliseconds(100))
        await relay.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(local.closed); XCTAssertTrue(remote.closed)
    }

    func testIdleTimeoutFails() async {
        let local = FakePipe([])
        let remote = FakePipe([])
        let relay = ExternalFlowRelay(local: local, remote: remote,
                                      limits: .init(maxConcurrent: 1, chunkBytes: 1024, idleTimeout: 0.2))
        let outcome = await relay.run()
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(local.closed); XCTAssertTrue(remote.closed)
    }

    func testRegistryAdmitsUpToLimit() async {
        let registry = ExternalFlowRelayRegistry(limits: .init(maxConcurrent: 2, chunkBytes: 1024, idleTimeout: 1))
        try? await registry.admit(); try? await registry.admit()
        do {
            try await registry.admit()
            XCTFail("expected limitReached")
        } catch {}
        await registry.release()
        try? await registry.admit()
        let count = await registry.activeCount
        XCTAssertEqual(count, 2)
    }
}

final class ExternalFlowCompilationTests: XCTestCase {
    func testWireExportCompilesToPolicy() throws {
        let wire = try ExternalFlowRulesWire(profileName: "flow", rules: [
            .init(kind: .domainSuffix, target: "example.com"),
            .init(kind: .application, target: "Chrome", applicationIdentifier: "com.google.Chrome"),
            .init(kind: .ipCIDR, target: "203.0.113.0/24"),
        ]).validated()
        let policy = try ExternalFlowPolicy(rulesWire: wire)
        assertDirect(policy.evaluate(.init(sourceAppSigningIdentifier: nil,
                                           remoteHostname: "www.example.com", destinationIPv4: nil)))
        assertDirect(policy.evaluate(.init(sourceAppSigningIdentifier: "com.google.Chrome",
                                           remoteHostname: nil, destinationIPv4: nil)))
        assertDirect(policy.evaluate(.init(sourceAppSigningIdentifier: nil, remoteHostname: nil,
                                           destinationIPv4: try IPv4Address("203.0.113.9"))))
        XCTAssertEqual(policy.evaluate(.init(sourceAppSigningIdentifier: nil, remoteHostname: "other.test",
                                             destinationIPv4: try IPv4Address("192.0.2.1"))), .systemDefault)
    }

    private func assertDirect(_ decision: ExternalFlowDecision, file: StaticString = #filePath,
                              line: UInt = #line) {
        guard case .direct = decision else {
            return XCTFail("expected direct, got \(decision)", file: file, line: line)
        }
    }

    func testInvalidRuleSetRejectedAsWhole() {
        let bad = ExternalFlowRulesWire(profileName: "flow", rules: [
            .init(kind: .domain, target: "ok.test"),
            .init(kind: .domain, target: "not a domain"),
        ])
        XCTAssertThrowsError(try ExternalFlowPolicy(rulesWire: bad))
        let unresolved = ExternalFlowRulesWire(profileName: "flow", rules: [
            .init(kind: .application, target: "Chrome"),
        ])
        XCTAssertThrowsError(try ExternalFlowPolicy(rulesWire: unresolved))
    }

    func testWireBoundsEnforced() {
        XCTAssertThrowsError(try ExternalFlowRulesWire(profileName: "", rules: [
            .init(kind: .domain, target: "a.test"),
        ]).validated())
        XCTAssertThrowsError(try ExternalFlowRulesWire(profileName: "flow",
            rules: (0...64).map { _ in .init(kind: .domain, target: "a.test") }).validated())
        XCTAssertThrowsError(try ExternalFlowRulesWire(profileName: "flow", rules: [
            .init(kind: .application, target: "Chrome", applicationIdentifier: "bad id"),
        ]).validated())
        XCTAssertThrowsError(try ExternalFlowRulesWire(profileName: "flow", rules: []).validated())
    }

    func testDescriptorEndpointParsing() throws {
        let ip = ExternalFlowDescriptor(sourceAppSigningIdentifier: nil, remoteHostname: nil,
                                        remoteEndpointHost: "81.69.116.102")
        XCTAssertEqual(ip.destinationIPv4, try IPv4Address("81.69.116.102"))
        let host = ExternalFlowDescriptor(sourceAppSigningIdentifier: nil, remoteHostname: "a.test",
                                          remoteEndpointHost: "a.test")
        XCTAssertNil(host.destinationIPv4)
        let empty = ExternalFlowDescriptor(sourceAppSigningIdentifier: nil, remoteHostname: nil,
                                           remoteEndpointHost: nil)
        XCTAssertNil(empty.destinationIPv4)
    }
}
