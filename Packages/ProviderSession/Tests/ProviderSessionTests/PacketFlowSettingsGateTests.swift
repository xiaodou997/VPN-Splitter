// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import ProviderSession

@MainActor
private final class Clock: SessionDeadlineScheduler {
    final class Token: SessionDeadlineCancellation {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    var now: Duration = .zero
    var timers: [(Duration, Token, @MainActor @Sendable () -> Void)] = []
    func schedule(after delay: Duration, action: @escaping @MainActor @Sendable () -> Void) -> any SessionDeadlineCancellation {
        let token = Token(); timers.append((now + delay, token, action)); return token
    }
    func advance(_ value: Duration, deliver: Bool = true) {
        now += value
        guard deliver else { return }
        let due = timers.filter { $0.0 <= now }; timers.removeAll { $0.0 <= now }
        for (_, token, action) in due where !token.cancelled { action() }
    }
}
@MainActor
private final class Settings {
    let clock = Clock()
    var apply: (@Sendable (Bool) -> Void)?
    var clear: (@Sendable (Bool) -> Void)?
    var events: [PacketFlowSettingsGate.Event] = []
    var applyCount = 0
    var clearCount = 0
    lazy var gate = try! PacketFlowSettingsGate(scheduler: clock, apply: { [self] reply in
        applyCount += 1; apply = reply
    }, clear: { [self] reply in clearCount += 1; clear = reply }, event: { [self] in events.append($0) })
}
@MainActor
final class PacketFlowSettingsGateTests: XCTestCase {
    private func settle() async { for _ in 0..<12 { await Task.yield() } }
    func testApplyThenClearAcknowledgement() async {
        let s = Settings(); var result: Result<Void, ProviderSessionFailure>?
        s.gate.apply { result = $0 }; XCTAssertNil(result)
        s.apply?(true); await settle(); XCTAssertNoThrow(try result?.get())
        s.gate.remove { result = $0 }; XCTAssertEqual(s.clearCount, 1)
        s.clear?(true); await settle(); XCTAssertTrue(s.gate.clearAcknowledged)
        XCTAssertEqual(s.events, [.applySubmitted, .applyAcknowledged, .clearSubmitted, .clearAcknowledged])
    }
    func testFailedApplyStillRequiresClear() async {
        let s = Settings(); var failed = false
        s.gate.apply { if case .failure(.backendStart) = $0 { failed = true } }
        s.apply?(false); await settle(); XCTAssertTrue(failed)
        s.gate.remove { _ in }; XCTAssertEqual(s.clearCount, 1)
    }
    func testApplyTimeoutDoesNotCancelNativeWrite() async {
        let s = Settings(); var failure: ProviderSessionFailure?
        s.gate.apply { if case .failure(let f) = $0 { failure = f } }
        s.clock.advance(.seconds(5)); XCTAssertEqual(failure, .startTimeout)
        s.gate.remove { _ in }; XCTAssertEqual(s.clearCount, 0)
        s.apply?(true); await settle(); XCTAssertEqual(s.clearCount, 1)
        XCTAssertFalse(s.events.contains(.applyAcknowledged))
    }
    func testLateApplyWithoutTimerDeliveryNeverStarts() async {
        let s = Settings(); var failure: ProviderSessionFailure?
        s.gate.apply { if case .failure(let f) = $0 { failure = f } }
        s.clock.advance(.seconds(5), deliver: false); s.apply?(true); await settle()
        XCTAssertEqual(failure, .startTimeout)
    }
    func testCancelBeforeSettingsAckCannotStart() async {
        let s = Settings(); var count = 0
        s.gate.apply { result in count += 1; if case .success = result { XCTFail("revoked") } }
        s.gate.invalidate(); s.gate.remove { _ in }
        XCTAssertEqual(s.clearCount, 0); s.apply?(true); await settle()
        XCTAssertEqual(count, 1); XCTAssertEqual(s.clearCount, 1)
    }
    func testNoApplyDoesNotCreateClearMutation() {
        let s = Settings(); var succeeded = false
        s.gate.remove { if case .success = $0 { succeeded = true } }
        XCTAssertTrue(succeeded); XCTAssertEqual(s.clearCount, 0)
    }
    func testNeverReturningApplyIsUnconfirmedNotClean() {
        let s = Settings(); var failure: ProviderSessionFailure?
        s.gate.apply { _ in }; s.gate.remove { if case .failure(let f) = $0 { failure = f } }
        s.clock.advance(.seconds(6)); XCTAssertEqual(failure, .cleanupUnconfirmed)
        XCTAssertEqual(s.clearCount, 0); XCTAssertTrue(s.gate.cleanupUnconfirmed)
    }
    func testLateApplyAfterStopTimeoutStillClearsExactlyOnce() async {
        let s = Settings(); var stops = 0
        s.gate.apply { _ in }; s.gate.remove { _ in stops += 1 }
        s.clock.advance(.seconds(6)); s.apply?(true); s.apply?(false); await settle()
        XCTAssertEqual(s.clearCount, 1); s.clear?(true); await settle()
        XCTAssertEqual(stops, 1); XCTAssertTrue(s.gate.cleanupUnconfirmed)
    }
    func testClearErrorIsUnconfirmed() async {
        let s = Settings(); var failure: ProviderSessionFailure?
        s.gate.apply { _ in }; s.apply?(true); await settle()
        s.gate.remove { if case .failure(let f) = $0 { failure = f } }
        s.clear?(false); await settle(); XCTAssertEqual(failure, .cleanupUnconfirmed)
    }
    func testLateClearWithoutTimerCannotPass() async {
        let s = Settings(); var failure: ProviderSessionFailure?
        s.gate.apply { _ in }; s.apply?(true); await settle()
        s.gate.remove { if case .failure(let f) = $0 { failure = f } }
        s.clock.advance(.seconds(6), deliver: false); s.clear?(true); await settle()
        XCTAssertEqual(failure, .cleanupUnconfirmed); XCTAssertTrue(s.gate.clearAcknowledged)
    }
    func testDuplicateCallbacksDoNotRepeatCompletion() async {
        let s = Settings(); var starts = 0; var stops = 0
        s.gate.apply { _ in starts += 1 }; s.apply?(true); s.apply?(false); await settle()
        s.gate.remove { _ in stops += 1 }; s.clear?(true); s.clear?(false); await settle()
        XCTAssertEqual(starts, 1); XCTAssertEqual(stops, 1); XCTAssertFalse(s.gate.cleanupUnconfirmed)
    }
    func testGateIsSingleUse() async {
        let s = Settings(); s.gate.apply { _ in }; s.apply?(true); await settle()
        s.gate.apply { if case .failure(.invalidState) = $0 {} else { XCTFail("reused") } }
        XCTAssertEqual(s.applyCount, 1)
    }
    func testInvalidatedBeforeApplyDoesNotMutate() {
        let s = Settings(); s.gate.invalidate(); s.gate.apply { _ in }
        XCTAssertEqual(s.applyCount, 0)
    }
    func testClearTimeoutDoesNotUpgradeOnLateAck() async {
        let s = Settings(); var outcomes = 0
        s.gate.apply { _ in }; s.apply?(true); await settle()
        s.gate.remove { _ in outcomes += 1 }; s.clock.advance(.seconds(6))
        s.clear?(true); await settle()
        XCTAssertEqual(outcomes, 1); XCTAssertTrue(s.gate.cleanupUnconfirmed)
    }
    func testInvalidTimeoutRejected() {
        XCTAssertThrowsError(try PacketFlowSettingsGate(timeout: .zero, apply: { _ in }, clear: { _ in }))
        XCTAssertThrowsError(try PacketFlowSettingsGate(timeout: .seconds(61), apply: { _ in }, clear: { _ in }))
    }
    func testReentrantRemoveFromApplyCompletion() async {
        let s = Settings()
        s.gate.apply { _ in s.gate.remove { _ in } }
        s.apply?(true); await settle(); XCTAssertEqual(s.clearCount, 1)
    }
    func testRealControllerWaitsForSettingsAndEngineBeforeReady() async throws {
        let s = Settings(); let backend = Pipeline(settings: s)
        let controller = ProviderSessionController(identity: backend.identity, currentIdentity: { backend.identity },
            timeouts: try .init(), scheduler: s.clock, event: { _ in })
        var started = false
        controller.start(load: { _, ready in ready(.success(backend)) }) { if case .success = $0 { started = true } }
        await settle(); XCTAssertEqual(backend.engineStarts, 0)
        s.apply?(true); await settle(); XCTAssertEqual(backend.engineStarts, 1); XCTAssertFalse(started)
        backend.engineReady?(.success(())); await settle(); XCTAssertTrue(started)
        var stopped = false
        controller.stop { if case .success = $0 { stopped = true } }; await settle()
        XCTAssertEqual(backend.engineStops, 1); XCTAssertEqual(s.clearCount, 0)
        backend.stoppedEngine?(); await settle(); XCTAssertEqual(s.clearCount, 1); XCTAssertFalse(stopped)
        s.clear?(true); await settle(); XCTAssertTrue(stopped)
        XCTAssertEqual(controller.phase, .awaitingSystemTeardown) // not .closed / not OS restoration
    }
    func testRealControllerCancelDuringSettingsNeverStartsEngine() async throws {
        let s = Settings(); let backend = Pipeline(settings: s)
        let controller = ProviderSessionController(identity: backend.identity, currentIdentity: { backend.identity },
            timeouts: try .init(), scheduler: s.clock, event: { _ in })
        controller.start(load: { _, ready in ready(.success(backend)) }) { _ in }
        await settle(); controller.stop { _ in }; await settle()
        XCTAssertEqual(backend.engineStarts, 0); XCTAssertEqual(s.clearCount, 0)
        backend.stoppedEngine?(); s.apply?(true); await settle()
        XCTAssertEqual(backend.engineStarts, 0); XCTAssertEqual(s.clearCount, 1)
    }
}
@MainActor
private final class Pipeline: PreparedProviderBackend {
    nonisolated let identity = ProviderSessionIdentity(provider: UUID(), session: UUID(), profile: UUID(),
        credential: UUID(), ownershipNonce: UUID(), generation: 1, networkEpoch: 1)
    let settings: Settings
    var engineStarts = 0; var engineStops = 0
    var engineReady: (@Sendable (Result<Void, ProviderSessionFailure>) -> Void)?
    var stoppedEngine: (() -> Void)?
    init(settings: Settings) { self.settings = settings }
    func start(completion: @escaping @Sendable (Result<Void, ProviderSessionFailure>) -> Void) {
        settings.gate.apply { [self] result in
            switch result {
            case .success: engineStarts += 1; engineReady = completion
            case .failure: completion(result)
            }
        }
    }
    func invalidate() { settings.gate.invalidate() }
    func stop(completion: @escaping @Sendable (Result<Void, ProviderSessionFailure>) -> Void) {
        engineStops += 1
        stoppedEngine = { [self] in settings.gate.remove { completion($0) } }
    }
    func discard() { invalidate() }
}
