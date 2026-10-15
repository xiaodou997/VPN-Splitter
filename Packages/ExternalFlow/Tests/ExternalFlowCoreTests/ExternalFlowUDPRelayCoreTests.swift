// SPDX-License-Identifier: MIT
import XCTest
@testable import ExternalFlowCore

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

private struct FakeFailure: Error {}

/// Scripted in-memory datagram source. Reads follow the script; when it is
/// exhausted the read parks until `push`, `endReads` or `close`.
private final class FakeDatagramSource: ExternalFlowUDPDatagramSource, @unchecked Sendable {
    enum Step { case batch([ExternalFlowUDPDatagram]), end, fail }
    typealias Waiter = CheckedContinuation<[ExternalFlowUDPDatagram]?, Error>

    private struct State {
        var script: [Step]
        var waiters: [Waiter] = []
        var written: [ExternalFlowUDPDatagram] = []
        var closed = false
    }
    private let state: LockedBox<State>

    init(_ script: [Step]) { state = LockedBox(State(script: script)) }

    var written: [ExternalFlowUDPDatagram] { state.withLock { $0.written } }
    var closed: Bool { state.withLock { $0.closed } }

    func endReads() {
        let waiter = state.withLock { s -> Waiter? in
            if !s.waiters.isEmpty { return s.waiters.removeFirst() }
            s.script.append(.end); return nil
        }
        waiter?.resume(returning: nil)
    }

    func readDatagrams() async throws -> [ExternalFlowUDPDatagram]? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enum Action { case resume([ExternalFlowUDPDatagram]?), fail, park }
                let action = state.withLock { s -> Action in
                    if s.closed { return .resume(nil) }
                    if !s.script.isEmpty {
                        switch s.script.removeFirst() {
                        case .batch(let batch): return .resume(batch)
                        case .end: return .resume(nil)
                        case .fail: return .fail
                        }
                    }
                    s.waiters.append(continuation); return .park
                }
                switch action {
                case .resume(let batch): continuation.resume(returning: batch)
                case .fail: continuation.resume(throwing: FakeFailure())
                case .park: break
                }
            }
        } onCancel: {
            let pending = state.withLock { s -> [Waiter] in
                let pending = s.waiters; s.waiters.removeAll(); return pending
            }
            for waiter in pending { waiter.resume(throwing: CancellationError()) }
        }
    }
    func writeDatagrams(_ datagrams: [ExternalFlowUDPDatagram]) async throws {
        try state.withLock { s in
            if s.closed { throw FakeFailure() }
            s.written.append(contentsOf: datagrams)
        }
    }
    func close() async {
        let pending = state.withLock { s -> [Waiter] in
            s.closed = true
            let pending = s.waiters; s.waiters.removeAll(); return pending
        }
        for waiter in pending { waiter.resume(returning: nil) }
    }
}

/// Scripted in-memory upstream link. Receives park until `push`, `failReceive`
/// or `close`.
private final class FakeLink: ExternalFlowUDPLink, @unchecked Sendable {
    enum Step { case data(Data), fail }
    typealias Waiter = CheckedContinuation<Data?, Error>

    private struct State {
        var script: [Step] = []
        var waiters: [Waiter] = []
        var sent: [Data] = []
        var closed = false
    }
    private let state = LockedBox(State())

    var sent: [Data] { state.withLock { $0.sent } }
    var closed: Bool { state.withLock { $0.closed } }

    func push(_ data: Data) {
        let waiter = state.withLock { s -> Waiter? in
            if !s.waiters.isEmpty { return s.waiters.removeFirst() }
            s.script.append(.data(data)); return nil
        }
        waiter?.resume(returning: data)
    }
    func failReceive() {
        let waiter = state.withLock { s -> Waiter? in
            if !s.waiters.isEmpty { return s.waiters.removeFirst() }
            s.script.append(.fail); return nil
        }
        waiter?.resume(throwing: FakeFailure())
    }

    func send(_ data: Data) async throws {
        try state.withLock { s in
            if s.closed { throw FakeFailure() }
            s.sent.append(data)
        }
    }
    func receive() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enum Action { case resume(Data?), fail, park }
                let action = state.withLock { s -> Action in
                    if s.closed { return .resume(nil) }
                    if !s.script.isEmpty {
                        switch s.script.removeFirst() {
                        case .data(let data): return .resume(data)
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
            let pending = state.withLock { s -> [Waiter] in
                let pending = s.waiters; s.waiters.removeAll(); return pending
            }
            for waiter in pending { waiter.resume(throwing: CancellationError()) }
        }
    }
    func close() async {
        let pending = state.withLock { s -> [Waiter] in
            s.closed = true
            let pending = s.waiters; s.waiters.removeAll(); return pending
        }
        for waiter in pending { waiter.resume(returning: nil) }
    }
}

private final class FakeLinkFactory: ExternalFlowUDPLinkFactory, @unchecked Sendable {
    private struct State {
        var endpoints: [ExternalFlowUDPEndpoint] = []
        var links: [FakeLink] = []
        var failOnMake = false
    }
    private let state = LockedBox(State())

    var made: [ExternalFlowUDPEndpoint] { state.withLock { $0.endpoints } }
    var links: [FakeLink] { state.withLock { $0.links } }
    var failOnMake: Bool {
        get { state.withLock { $0.failOnMake } }
        set { state.withLock { $0.failOnMake = newValue } }
    }

    func makeLink(endpoint: ExternalFlowUDPEndpoint) async throws -> any ExternalFlowUDPLink {
        try state.withLock { s in
            if s.failOnMake { throw FakeFailure() }
            let link = FakeLink()
            s.endpoints.append(endpoint)
            s.links.append(link)
            return link
        }
    }
}

final class ExternalFlowUDPRelayCoreTests: XCTestCase {
    private let endpoint1 = ExternalFlowUDPEndpoint(host: "192.0.2.1", port: 443)
    private let endpoint2 = ExternalFlowUDPEndpoint(host: "192.0.2.2", port: 443)

    private func waitUntil(_ timeout: TimeInterval = 2,
                           _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testDatagramsRelayPerEndpointAndResponsesPreserveEndpoint() async {
        let source = FakeDatagramSource([.batch([
            .init(endpoint: endpoint1, data: Data("a".utf8)),
            .init(endpoint: endpoint2, data: Data("b".utf8)),
            .init(endpoint: endpoint1, data: Data("c".utf8)),
        ])])
        let factory = FakeLinkFactory()
        let relay = ExternalFlowUDPRelay(source: source, factory: factory,
            limits: .init(maxEndpointsPerFlow: 8, maxDatagramBytes: 65_535, idleTimeout: 30))
        let run = Task { await relay.run() }
        let linksMade = await waitUntil { factory.made.count == 2 }
        XCTAssertTrue(linksMade)
        XCTAssertEqual(factory.made, [endpoint1, endpoint2])
        XCTAssertEqual(factory.links[0].sent, [Data("a".utf8), Data("c".utf8)])
        XCTAssertEqual(factory.links[1].sent, [Data("b".utf8)])
        factory.links[1].push(Data("r".utf8))
        let responseWritten = await waitUntil { source.written.count == 1 }
        XCTAssertTrue(responseWritten)
        XCTAssertEqual(source.written, [.init(endpoint: endpoint2, data: Data("r".utf8))])
        source.endReads()
        let outcome = await run.value
        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(source.closed)
        XCTAssertTrue(factory.links.allSatisfy { $0.closed })
    }

    func testEndpointLimitClosesFlowAndFails() async {
        let source = FakeDatagramSource([.batch([
            .init(endpoint: endpoint1, data: Data("a".utf8)),
            .init(endpoint: endpoint2, data: Data("b".utf8)),
        ])])
        let factory = FakeLinkFactory()
        let relay = ExternalFlowUDPRelay(source: source, factory: factory,
            limits: .init(maxEndpointsPerFlow: 1, maxDatagramBytes: 65_535, idleTimeout: 30))
        let outcome = await relay.run()
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(factory.made, [endpoint1])
        XCTAssertTrue(source.closed)
        XCTAssertTrue(factory.links[0].closed)
    }

    func testOversizedInboundDatagramFails() async {
        let source = FakeDatagramSource([.batch([
            .init(endpoint: endpoint1, data: Data(repeating: 1, count: 5)),
        ])])
        let factory = FakeLinkFactory()
        let relay = ExternalFlowUDPRelay(source: source, factory: factory,
            limits: .init(maxEndpointsPerFlow: 8, maxDatagramBytes: 4, idleTimeout: 30))
        let outcome = await relay.run()
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(factory.made.isEmpty)
        XCTAssertTrue(source.closed)
    }

    func testOversizedResponseDatagramFails() async {
        let source = FakeDatagramSource([.batch([
            .init(endpoint: endpoint1, data: Data("a".utf8)),
        ])])
        let factory = FakeLinkFactory()
        let relay = ExternalFlowUDPRelay(source: source, factory: factory,
            limits: .init(maxEndpointsPerFlow: 8, maxDatagramBytes: 4, idleTimeout: 30))
        let run = Task { await relay.run() }
        let linkMade = await waitUntil { factory.made.count == 1 }
        XCTAssertTrue(linkMade)
        factory.links[0].push(Data(repeating: 1, count: 5))
        let outcome = await run.value
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(source.closed)
    }

    func testIdleTimeoutIsNormalCompletion() async {
        let source = FakeDatagramSource([])
        let factory = FakeLinkFactory()
        let relay = ExternalFlowUDPRelay(source: source, factory: factory,
            limits: .init(maxEndpointsPerFlow: 8, maxDatagramBytes: 65_535, idleTimeout: 0.2))
        let outcome = await relay.run()
        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(source.closed)
    }

    func testReadErrorFailsAndCloses() async {
        let source = FakeDatagramSource([.fail])
        let factory = FakeLinkFactory()
        let relay = ExternalFlowUDPRelay(source: source, factory: factory,
            limits: .init(maxEndpointsPerFlow: 8, maxDatagramBytes: 65_535, idleTimeout: 30))
        let outcome = await relay.run()
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(source.closed)
    }

    func testLinkFailureFailsAndClosesEverything() async {
        let source = FakeDatagramSource([.batch([
            .init(endpoint: endpoint1, data: Data("a".utf8)),
        ])])
        let factory = FakeLinkFactory()
        let relay = ExternalFlowUDPRelay(source: source, factory: factory,
            limits: .init(maxEndpointsPerFlow: 8, maxDatagramBytes: 65_535, idleTimeout: 30))
        let run = Task { await relay.run() }
        let linkReady = await waitUntil { factory.made.count == 1 }
        XCTAssertTrue(linkReady)
        factory.links[0].failReceive()
        let outcome = await run.value
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(source.closed)
        XCTAssertTrue(factory.links[0].closed)
    }

    func testLinkFactoryFailureFails() async {
        let source = FakeDatagramSource([.batch([
            .init(endpoint: endpoint1, data: Data("a".utf8)),
        ])])
        let factory = FakeLinkFactory()
        factory.failOnMake = true
        let relay = ExternalFlowUDPRelay(source: source, factory: factory,
            limits: .init(maxEndpointsPerFlow: 8, maxDatagramBytes: 65_535, idleTimeout: 30))
        let outcome = await relay.run()
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(source.closed)
    }

    func testCancelUnblocksPendingReads() async {
        let source = FakeDatagramSource([])
        let factory = FakeLinkFactory()
        let relay = ExternalFlowUDPRelay(source: source, factory: factory,
            limits: .init(maxEndpointsPerFlow: 8, maxDatagramBytes: 65_535, idleTimeout: 30))
        let run = Task { await relay.run() }
        try? await Task.sleep(for: .milliseconds(100))
        await relay.cancel()
        let outcome = await run.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(source.closed)
    }

    func testDefaultLimitsMatchADR() {
        XCTAssertEqual(ExternalFlowUDPRelayLimits.default.maxEndpointsPerFlow, 8)
        XCTAssertEqual(ExternalFlowUDPRelayLimits.default.maxDatagramBytes, 65_535)
        XCTAssertEqual(ExternalFlowUDPRelayLimits.default.idleTimeout, 75)
    }
}
