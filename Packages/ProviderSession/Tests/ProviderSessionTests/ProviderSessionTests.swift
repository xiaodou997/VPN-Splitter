// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import ProviderSession

private func identity(generation: UInt64 = 1) -> ProviderSessionIdentity {
    .init(provider: UUID(), session: UUID(), profile: UUID(), credential: UUID(),
          ownershipNonce: UUID(), generation: generation, networkEpoch: 1)
}
private final class Current: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ProviderSessionIdentity?
    init(_ value: ProviderSessionIdentity?) { self.value = value }
    func get() -> ProviderSessionIdentity? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: ProviderSessionIdentity?) { lock.lock(); self.value = value; lock.unlock() }
}

@MainActor
private final class Clock: SessionDeadlineScheduler {
    var now: Duration = .zero
    final class Token: SessionDeadlineCancellation {
        var cancelled = false
        let action: @MainActor @Sendable () -> Void
        init(_ action: @escaping @MainActor @Sendable () -> Void) { self.action = action }
        func cancel() { cancelled = true }
        func fireEvenIfCancelled() { action() }
    }
    var tokens: [Token] = []
    func schedule(after delay: Duration, action: @escaping @MainActor @Sendable () -> Void) -> any SessionDeadlineCancellation {
        let token = Token(action); tokens.append(token); return token
    }
    func fire() { tokens.last!.fireEvenIfCancelled() }
}

@MainActor
private final class Backend: PreparedProviderBackend {
    let identity: ProviderSessionIdentity
    var calls: [String] = []
    var onStart: (@Sendable (Result<Void, ProviderSessionFailure>) -> Void)?
    var onStop: (@Sendable (Result<Void, ProviderSessionFailure>) -> Void)?
    var immediateStart: Result<Void, ProviderSessionFailure>?
    var immediateStop: Result<Void, ProviderSessionFailure>?
    init(_ identity: ProviderSessionIdentity) { self.identity = identity }
    func start(completion: @escaping @Sendable (Result<Void, ProviderSessionFailure>) -> Void) {
        calls.append("start"); onStart = completion
        if let immediateStart { completion(immediateStart) }
    }
    func invalidate() { calls.append("invalidate") }
    func stop(completion: @escaping @Sendable (Result<Void, ProviderSessionFailure>) -> Void) {
        calls.append("stop"); onStop = completion
        if let immediateStop { completion(immediateStop) }
    }
    func discard() { calls.append("discard") }
}

@MainActor
private final class Rig {
    let id = identity()
    let clock = Clock()
    let current: Current
    var controller: ProviderSessionController!
    var loaded: (@Sendable (Result<any PreparedProviderBackend, ProviderSessionFailure>) -> Void)?
    var starts: [Result<Void, ProviderSessionFailure>] = []
    var stops: [Result<Void, ProviderSessionFailure>] = []
    var events: [ProviderSessionEvent] = []
    var loadCount = 0
    init() throws {
        current = Current(id)
        controller = ProviderSessionController(identity: id, currentIdentity: current.get,
            timeouts: try .init(), scheduler: clock, event: { [weak self] in self?.events.append($0) })
    }
    func begin() {
        controller.start(load: { [self] supplied, completion in
            #expect(supplied == id); loadCount += 1; loaded = completion
        }, completion: { [weak self] in self?.starts.append($0) })
    }
    func stop() { controller.stop { [weak self] in self?.stops.append($0) } }
    func prepare() async -> Backend {
        begin(); let backend = Backend(id); loaded?(.success(backend))
        await settle(); return backend
    }
    func run() async -> Backend {
        let backend = await prepare(); backend.onStart?(.success(())); await settle(); return backend
    }
}
@MainActor private func settle() async { for _ in 0..<30 { await Task.yield() } }
private func failure(_ result: Result<Void, ProviderSessionFailure>?) -> ProviderSessionFailure? {
    if case .failure(let error) = result { return error }; return nil
}
private func success(_ result: Result<Void, ProviderSessionFailure>?) -> Bool {
    if case .success = result { return true }; return false
}

@Test @MainActor func normalLifecycleNeedsSeparateMatchingTeardown() async throws {
    let r = try Rig(); let b = await r.run()
    #expect(r.controller.phase == .running); #expect(success(r.starts.first))
    #expect(!r.controller.observeSystemTeardown(for: r.id))
    r.stop(); #expect(b.calls == ["start", "invalidate", "stop"])
    b.onStop?(.success(())); await settle()
    #expect(success(r.stops.first)); #expect(r.controller.phase == .awaitingSystemTeardown)
    #expect(!r.controller.observeSystemTeardown(for: identity()))
    #expect(r.controller.observeSystemTeardown(for: r.id)); #expect(r.controller.phase == .closed)
    #expect(!r.controller.observeSystemTeardown(for: r.id))
    #expect(r.events == [.backendReady, .backendQuiescent, .systemTeardownObserved])
}

@Test @MainActor func staleAtEntryDoesNotLoadCredentials() throws {
    let r = try Rig(); r.current.set(nil); r.begin()
    #expect(r.loadCount == 0); #expect(failure(r.starts.first) == .staleIdentity)
    #expect(r.controller.phase == .awaitingSystemTeardown)
}

@Test @MainActor func cancellationDuringLoadDiscardsLateResource() async throws {
    let r = try Rig(); r.begin(); r.stop()
    #expect(failure(r.starts.first) == .cancelled); #expect(success(r.stops.first))
    let b = Backend(r.id); r.loaded?(.success(b)); await settle()
    #expect(b.calls == ["discard"]); #expect(r.starts.count == 1)
    #expect(r.controller.phase == .awaitingSystemTeardown)
}

@Test @MainActor func loadTimeoutNeverStartsLateCredentials() async throws {
    let r = try Rig(); r.begin(); r.clock.fire()
    #expect(failure(r.starts.first) == .credentialTimeout)
    let b = Backend(r.id); r.loaded?(.success(b)); await settle()
    #expect(b.calls == ["discard"]); #expect(r.controller.phase == .awaitingSystemTeardown)
}

@Test @MainActor func loadErrorIsPreservedWithoutStarting() async throws {
    let r = try Rig(); r.begin(); r.loaded?(.failure(.credentialUnavailable)); await settle()
    #expect(failure(r.starts.first) == .credentialUnavailable)
    #expect(r.controller.phase == .awaitingSystemTeardown)
}

@Test @MainActor func identityChangedDuringCredentialReadDiscards() async throws {
    let r = try Rig(); r.begin(); r.current.set(identity())
    let b = Backend(r.id); r.loaded?(.success(b)); await settle()
    #expect(b.calls == ["discard"]); #expect(failure(r.starts.first) == .staleIdentity)
}

@Test @MainActor func wrongResourceIdentityDoesNotStart() async throws {
    let r = try Rig(); r.begin(); let b = Backend(identity())
    r.loaded?(.success(b)); await settle()
    #expect(b.calls == ["discard"]); #expect(failure(r.starts.first) == .staleIdentity)
}

@Test @MainActor func duplicateResourceCallbackDoesNotDiscardActiveObject() async throws {
    let r = try Rig(); let b = await r.prepare()
    r.loaded?(.success(b)); r.loaded?(.failure(.credentialUnavailable)); await settle()
    #expect(b.calls == ["start"]); #expect(r.starts.isEmpty)
    let other = Backend(r.id); r.loaded?(.success(other)); await settle()
    #expect(other.calls == ["discard"]); #expect(b.calls == ["start"])
}

@Test @MainActor func stopDuringStartWaitsForStartSettlementBeforeStop() async throws {
    let r = try Rig(); let b = await r.prepare(); r.stop()
    #expect(b.calls == ["start", "invalidate"]); #expect(r.stops.isEmpty)
    #expect(failure(r.starts.first) == .cancelled); #expect(r.controller.phase == .drainingStart)
    b.onStart?(.success(())); await settle()
    #expect(b.calls.filter { $0 == "stop" }.count == 1); #expect(r.starts.count == 1)
    #expect(!r.events.contains(.backendReady)); #expect(r.stops.isEmpty)
    b.onStop?(.success(())); await settle()
    #expect(success(r.stops.first)); #expect(r.controller.phase == .awaitingSystemTeardown)
}

@Test @MainActor func startFailureStillDrainsPotentialPartialSettings() async throws {
    let r = try Rig(); let b = await r.prepare(); b.onStart?(.failure(.backendStart)); await settle()
    #expect(failure(r.starts.first) == .backendStart); #expect(r.controller.phase == .stopping)
    #expect(b.calls == ["start", "invalidate", "stop"])
    b.onStop?(.success(())); await settle(); #expect(r.controller.phase == .awaitingSystemTeardown)
}

@Test @MainActor func staleAfterStartCannotPublishReady() async throws {
    let r = try Rig(); let b = await r.prepare(); r.current.set(nil)
    b.onStart?(.success(())); await settle()
    #expect(failure(r.starts.first) == .staleIdentity); #expect(!r.events.contains(.backendReady))
    #expect(r.controller.phase == .stopping)
}

@Test @MainActor func startTimeoutAndLateSuccessAreCleanedNotRevived() async throws {
    let r = try Rig(); let b = await r.prepare(); r.clock.fire()
    #expect(failure(r.starts.first) == .startTimeout); #expect(r.controller.phase == .drainingStart)
    b.onStart?(.success(())); await settle(); #expect(r.controller.phase == .stopping)
    b.onStop?(.success(())); await settle()
    #expect(r.starts.count == 1); #expect(!r.events.contains(.backendReady))
}

@Test @MainActor func stopTimeoutDoesNotClaimQuiescenceOrSystemRemoval() async throws {
    let r = try Rig(); let b = await r.run(); r.stop(); r.clock.fire()
    #expect(failure(r.stops.first) == .cleanupUnconfirmed)
    #expect(!r.events.contains(.backendQuiescent)); #expect(!r.controller.observeSystemTeardown(for: r.id))
    b.onStop?(.success(())); await settle()
    #expect(r.stops.count == 1); #expect(r.controller.phase == .awaitingSystemTeardown)
    #expect(r.events.filter { $0 == .backendQuiescent }.count == 1)
}

@Test @MainActor func timedOutDrainStillStopsWhenStartEventuallySettles() async throws {
    let r = try Rig(); let b = await r.prepare(); r.stop(); r.clock.fire()
    #expect(r.controller.phase == .cleanupUnconfirmed); #expect(!b.calls.contains("stop"))
    b.onStart?(.failure(.backendStart)); await settle()
    #expect(b.calls.filter { $0 == "stop" }.count == 1)
    b.onStop?(.success(())); await settle()
    #expect(r.controller.phase == .awaitingSystemTeardown); #expect(r.stops.count == 1)
}

@Test @MainActor func stopErrorStaysUnconfirmedAndIgnoresDuplicateSuccess() async throws {
    let r = try Rig(); let b = await r.run(); r.stop()
    b.onStop?(.failure(.backendStop)); await settle()
    b.onStop?(.success(())); await settle()
    #expect(failure(r.stops.first) == .cleanupUnconfirmed); #expect(r.controller.phase == .cleanupUnconfirmed)
    #expect(!r.controller.observeSystemTeardown(for: r.id))
}

@Test @MainActor func duplicateStartAndStopCallbacksCompleteOnlyOnce() async throws {
    let r = try Rig(); let b = await r.run()
    b.onStart?(.failure(.backendStart)); b.onStart?(.success(())); await settle()
    #expect(r.starts.count == 1); #expect(r.controller.phase == .running)
    r.stop(); r.stop(); b.onStop?(.success(())); b.onStop?(.success(())); await settle()
    #expect(r.stops.count == 2); #expect(r.stops.allSatisfy(success))
    #expect(b.calls.filter { $0 == "stop" }.count == 1)
}

@Test @MainActor func staleCancelledTimerCannotAffectNewPhase() async throws {
    let r = try Rig(); let b = await r.prepare(); let loadTimer = r.clock.tokens[0]
    loadTimer.fireEvenIfCancelled(); #expect(r.controller.phase == .starting)
    b.onStart?(.success(())); await settle()
    r.clock.tokens[1].fireEvenIfCancelled(); #expect(r.controller.phase == .running)
    #expect(r.starts.count == 1)
}

@Test @MainActor func identityInvalidationStopsRunningSessionWithoutRetry() async throws {
    let r = try Rig(); let b = await r.run(); r.current.set(nil); r.controller.contextChanged()
    #expect(r.controller.phase == .stopping); #expect(b.calls.last == "stop")
    #expect(r.events.contains(.failed(.staleIdentity)))
    r.begin(); #expect(failure(r.starts.last) == .invalidState); #expect(r.loadCount == 1)
}

@Test @MainActor func stoppedControllerNeverRestartsEvenAfterMatchingTeardown() async throws {
    let r = try Rig(); r.stop(); #expect(r.controller.observeSystemTeardown(for: r.id))
    r.begin(); #expect(failure(r.starts.first) == .invalidState); #expect(r.loadCount == 0)
}

@Test @MainActor func repeatStartCannotReplaceFirstCompletion() async throws {
    let r = try Rig(); r.begin(); r.begin()
    #expect(r.loadCount == 1); #expect(failure(r.starts.first) == .invalidState)
    r.loaded?(.failure(.credentialUnavailable)); await settle()
    #expect(r.starts.count == 2); #expect(failure(r.starts.last) == .credentialUnavailable)
}

@Test @MainActor func tooManyStopWaitersAreBoundedWithoutSubmittingMoreStops() async throws {
    let r = try Rig(); let b = await r.run()
    for _ in 0..<17 { r.stop() }
    #expect(failure(r.stops.first) == .tooManyWaiters)
    b.onStop?(.success(())); await settle()
    #expect(r.stops.count == 17); #expect(b.calls.filter { $0 == "stop" }.count == 1)
}

@Test @MainActor func synchronousCallbacksAreNotLost() async throws {
    let r = try Rig(); let b = Backend(r.id)
    b.immediateStart = .success(()); b.immediateStop = .success(())
    r.controller.start(load: { _, cb in cb(.success(b)) }, completion: { r.starts.append($0) })
    await settle(); #expect(r.controller.phase == .running)
    r.stop(); await settle(); #expect(success(r.starts.first)); #expect(success(r.stops.first))
}

@Test @MainActor func failureCallbackCannotReenterAndStartAgain() throws {
    let r = try Rig(); r.current.set(nil)
    r.controller.start(load: { _, _ in Issue.record("Must not load") }, completion: { _ in r.begin() })
    #expect(failure(r.starts.first) == .invalidState); #expect(r.loadCount == 0)
}

@Test @MainActor func cancelledLoaderAfterOwnerReleasedDiscardsWithoutStart() async throws {
    let id = identity(); let c = Current(id); let clock = Clock()
    var callback: (@Sendable (Result<any PreparedProviderBackend, ProviderSessionFailure>) -> Void)?
    var controller: ProviderSessionController? = .init(identity: id, currentIdentity: c.get,
        timeouts: try .init(), scheduler: clock, event: { _ in })
    controller?.start(load: { _, cb in callback = cb }, completion: { _ in })
    controller?.stop(completion: { _ in }); controller = nil
    let b = Backend(id); callback?(.success(b)); await settle()
    #expect(b.calls == ["discard"])
}

@Test func timeoutsRejectInvalidBounds() throws {
    for value: Duration in [.zero, .seconds(-1), .seconds(301)] {
        #expect(throws: ProviderSessionFailure.configurationRejected) { try ProviderSessionTimeouts(load: value) }
        #expect(throws: ProviderSessionFailure.configurationRejected) { try ProviderSessionTimeouts(start: value) }
        #expect(throws: ProviderSessionFailure.configurationRejected) { try ProviderSessionTimeouts(stop: value) }
    }
}

@Test @MainActor func realSchedulerFiresAndCancelledTaskDoesNotFire() async {
    let scheduler = TaskSessionDeadlineScheduler()
    var fired = false; var cancelled = false
    let first = scheduler.schedule(after: .milliseconds(1)) { fired = true }
    let second = scheduler.schedule(after: .milliseconds(1)) { cancelled = true }
    second.cancel()
    try? await Task.sleep(for: .milliseconds(30))
    #expect(fired); #expect(!cancelled); first.cancel()
}

@Test @MainActor func delayedTimerCannotAuthorizeOverdueCredentialCallback() async throws {
    let r = try Rig(); r.begin(); r.clock.now = .seconds(16)
    let b = Backend(r.id); r.loaded?(.success(b)); await settle()
    #expect(failure(r.starts.first) == .credentialTimeout)
    #expect(b.calls == ["discard"])
}

@Test @MainActor func delayedTimerCannotAuthorizeOverdueStartCallback() async throws {
    let r = try Rig(); let b = await r.prepare(); r.clock.now = .seconds(21)
    b.onStart?(.success(())); await settle()
    #expect(failure(r.starts.first) == .startTimeout)
    #expect(!r.events.contains(.backendReady)); #expect(r.controller.phase == .stopping)
}

@Test @MainActor func delayedStopTimerReportsDeadlineBeforeLateQuiescence() async throws {
    let r = try Rig(); let b = await r.run(); r.stop(); r.clock.now = .seconds(11)
    b.onStop?(.success(())); await settle()
    #expect(failure(r.stops.first) == .cleanupUnconfirmed)
    #expect(r.controller.phase == .awaitingSystemTeardown)
    #expect(r.events.contains(.backendQuiescent))
}

@Test @MainActor func backendCallbacksFromDetachedTaskAreSerialized() async throws {
    let r = try Rig(); let b = await r.prepare()
    let callback = b.onStart
    await Task.detached { callback?(.success(())); callback?(.failure(.backendStart)) }.value
    await settle(); #expect(r.starts.count == 1)
    // Callback order from arbitrary executors is not an authority to bypass the first-result gate.
    #expect(r.controller.phase == .running || r.controller.phase == .stopping)
}

@Test @MainActor func oldControllerLateCallbacksCannotTouchNewController() async throws {
    let old = try Rig(); let oldBackend = await old.prepare(); old.stop()
    let new = try Rig(); let newBackend = await new.run()
    oldBackend.onStart?(.success(())); await settle()
    oldBackend.onStop?(.success(())); await settle()
    #expect(new.controller.phase == .running); #expect(newBackend.calls == ["start"])
    #expect(old.controller.phase == .awaitingSystemTeardown)
}
