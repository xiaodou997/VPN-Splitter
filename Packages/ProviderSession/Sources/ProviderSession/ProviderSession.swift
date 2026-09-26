// SPDX-License-Identifier: MIT
import Foundation

/// An in-process identity, NOT an IPC credential, authorization proof or serialized secret.
/// The host must advance/revoke currentIdentity for every policy/topology/credential change.
public struct ProviderSessionIdentity: Equatable, Sendable {
    public let provider: UUID
    public let session: UUID
    public let profile: UUID
    public let credential: UUID
    public let ownershipNonce: UUID
    public let generation: UInt64
    public let networkEpoch: UInt64

    public init(provider: UUID, session: UUID, profile: UUID, credential: UUID,
                ownershipNonce: UUID, generation: UInt64, networkEpoch: UInt64) {
        self.provider = provider; self.session = session; self.profile = profile
        self.credential = credential; self.ownershipNonce = ownershipNonce
        self.generation = generation; self.networkEpoch = networkEpoch
    }
}

/// Static failures only. Never store framework error strings, raw configuration or keys.
public enum ProviderSessionFailure: String, Error, Sendable {
    case invalidState, staleIdentity, credentialUnavailable, configurationRejected
    case cancelled, credentialTimeout, startTimeout, backendStart, backendStop
    case cleanupUnconfirmed, tooManyWaiters
}

public enum ProviderSessionPhase: String, Sendable {
    case idle, loading, starting, running, drainingStart, stopping
    case awaitingSystemTeardown, cleanupUnconfirmed, closed
}

public enum ProviderSessionEvent: Equatable, Sendable {
    /// Backend start succeeded; this is NOT a handshake, egress or routing verification.
    case backendReady
    case failed(ProviderSessionFailure)
    /// Backend is no longer active. It does NOT mean OS routes/DNS were removed.
    case backendQuiescent
    /// Only the caller's separately observed teardown can cause this event.
    case systemTeardownObserved
}

/// Prepared resources must not apply settings/open a tunnel before start is called.
/// Methods return promptly. Callbacks may be synchronous or delayed; stopping is ordered
/// AFTER the start callback settles. invalidate revokes permissions; it is NOT OS cancel.
@MainActor
public protocol PreparedProviderBackend: AnyObject, Sendable {
    var identity: ProviderSessionIdentity { get }
    func start(completion: @escaping @Sendable (Result<Void, ProviderSessionFailure>) -> Void)
    func invalidate()
    func stop(completion: @escaping @Sendable (Result<Void, ProviderSessionFailure>) -> Void)
    /// Idempotently release an object that was NEVER started. Must not apply OS settings.
    func discard()
}

@MainActor
public protocol SessionDeadlineCancellation: AnyObject {
    func cancel()
}

@MainActor
public protocol SessionDeadlineScheduler {
    /// Monotonic elapsed time; callbacks also check this instead of trusting timer ordering.
    var now: Duration { get }
    func schedule(after delay: Duration, action: @escaping @MainActor @Sendable () -> Void)
        -> any SessionDeadlineCancellation
}

@MainActor
public final class TaskSessionDeadlineScheduler: SessionDeadlineScheduler {
    private let origin = ContinuousClock.now
    public var now: Duration { origin.duration(to: .now) }
    public init() {}
    public func schedule(after delay: Duration, action: @escaping @MainActor @Sendable () -> Void)
        -> any SessionDeadlineCancellation {
        Token(task: Task { @MainActor in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        })
    }
    private final class Token: SessionDeadlineCancellation {
        let task: Task<Void, Never>
        init(task: Task<Void, Never>) { self.task = task }
        func cancel() { task.cancel() }
        deinit { task.cancel() }
    }
}

public struct ProviderSessionTimeouts: Sendable {
    public let load: Duration
    public let start: Duration
    public let stop: Duration
    public init(load: Duration = .seconds(15), start: Duration = .seconds(20),
                stop: Duration = .seconds(10)) throws {
        guard load > .zero, start > .zero, stop > .zero,
              load <= .seconds(300), start <= .seconds(300), stop <= .seconds(300) else {
            throw ProviderSessionFailure.configurationRejected
        }
        self.load = load; self.start = start; self.stop = stop
    }
}

/// One controller = one Provider attempt. Terminal states never become idle again.
/// The owner MUST retain this object until pending callbacks and native teardown finish.
/// No Keychain, network, process, settings or credential serialization API is used here.
@MainActor
public final class ProviderSessionController {
    public typealias Completion = @MainActor (Result<Void, ProviderSessionFailure>) -> Void
    public typealias Loader = @MainActor (ProviderSessionIdentity,
        @escaping @Sendable (Result<any PreparedProviderBackend, ProviderSessionFailure>) -> Void) -> Void

    public let identity: ProviderSessionIdentity
    public private(set) var phase: ProviderSessionPhase = .idle
    private let currentIdentity: @Sendable () -> ProviderSessionIdentity?
    private let event: @MainActor (ProviderSessionEvent) -> Void
    private let scheduler: any SessionDeadlineScheduler
    private let timeouts: ProviderSessionTimeouts
    private var deadline: (any SessionDeadlineCancellation)?
    private var deadlineID: UUID?
    private var deadlineAt: Duration?
    private var backend: (any PreparedProviderBackend)?
    private weak var acceptedBackend: (any PreparedProviderBackend)?
    private var startCompletion: Completion?
    private var stopCompletions: [Completion] = []
    private var loadSettled = false
    private var startSettled = false
    private var stopSubmitted = false
    private var stopSettled = false
    private var quiescenceReported = false

    public init(identity: ProviderSessionIdentity,
                currentIdentity: @escaping @Sendable () -> ProviderSessionIdentity?,
                timeouts: ProviderSessionTimeouts,
                scheduler: any SessionDeadlineScheduler = TaskSessionDeadlineScheduler(),
                event: @escaping @MainActor (ProviderSessionEvent) -> Void) {
        self.identity = identity; self.currentIdentity = currentIdentity
        self.timeouts = timeouts; self.scheduler = scheduler; self.event = event
    }

    public func start(load: Loader, completion: @escaping Completion) {
        guard phase == .idle else { completion(.failure(.invalidState)); return }
        startCompletion = completion
        guard currentIdentity() == identity else {
            becomeQuiescent(failingStart: .staleIdentity); return
        }
        phase = .loading
        arm(after: timeouts.load)
        load(identity) { [weak self] result in
            Task { @MainActor in
                guard let self else {
                    if case .success(let unused) = result { unused.discard() }
                    return
                }
                self.loaded(result)
            }
        }
    }

    /// The host calls this when current identity/policy/network/credential is invalidated.
    /// This is not itself an OS observer and does not rewrite rules to DIRECT.
    public func contextChanged() {
        requestStop(reason: .staleIdentity, completion: nil)
    }

    public func stop(completion: @escaping Completion) {
        requestStop(reason: .cancelled, completion: completion)
    }

    /// Only use after a separate, matching Provider/manager teardown observation.
    /// A successful stop callback by itself is NOT that observation.
    @discardableResult
    public func observeSystemTeardown(for observed: ProviderSessionIdentity) -> Bool {
        guard observed == identity, phase == .awaitingSystemTeardown, quiescenceReported else { return false }
        phase = .closed
        event(.systemTeardownObserved)
        return true
    }

    private func loaded(_ result: Result<any PreparedProviderBackend, ProviderSessionFailure>) {
        guard !loadSettled else {
            if case .success(let unused) = result, unused !== acceptedBackend { unused.discard() }
            return
        }
        loadSettled = true
        expireIfDue()
        guard phase == .loading else {
            if case .success(let unused) = result { unused.discard() }
            return
        }
        clearDeadline()
        switch result {
        case .failure(let error): becomeQuiescent(failingStart: error)
        case .success(let prepared):
            guard currentIdentity() == identity, prepared.identity == identity else {
                prepared.discard(); becomeQuiescent(failingStart: .staleIdentity); return
            }
            acceptedBackend = prepared; backend = prepared
            phase = .starting
            arm(after: timeouts.start)
            prepared.start { [weak self] result in
                Task { @MainActor in self?.started(result) }
            }
        }
    }

    private func started(_ result: Result<Void, ProviderSessionFailure>) {
        guard !startSettled else { return }
        startSettled = true
        expireIfDue()
        switch phase {
        case .starting:
            clearDeadline()
            if currentIdentity() != identity {
                beginBackendStop(); failStart(.staleIdentity); return
            }
            switch result {
            case .success:
                phase = .running
                // State and handler are settled before user code can re-enter.
                let completion = startCompletion; startCompletion = nil
                event(.backendReady)
                completion?(.success(()))
            case .failure(let error): beginBackendStop(); failStart(error)
            }
        case .drainingStart, .cleanupUnconfirmed: beginBackendStop()
        default: break
        }
    }

    private func requestStop(reason: ProviderSessionFailure, completion: Completion?) {
        switch phase {
        case .closed, .awaitingSystemTeardown: completion?(.success(())); return
        case .cleanupUnconfirmed: completion?(.failure(.cleanupUnconfirmed)); return
        default: break
        }
        if let completion {
            guard stopCompletions.count < 16 else { completion(.failure(.tooManyWaiters)); return }
            stopCompletions.append(completion)
        }
        switch phase {
        case .idle: becomeQuiescent()
        case .loading:
            becomeQuiescent(failingStart: reason) // A late prepared object is discarded, never started.
        case .starting:
            phase = .drainingStart
            backend?.invalidate()
            arm(after: timeouts.stop)
            failStart(reason)
        case .running:
            beginBackendStop()
            if reason != .cancelled { event(.failed(reason)) }
        case .drainingStart, .stopping: break
        default: break
        }
    }

    private func beginBackendStop() {
        guard !stopSubmitted, let backend else { return }
        stopSubmitted = true
        phase = .stopping
        backend.invalidate()
        arm(after: timeouts.stop)
        backend.stop { [weak self] result in
            Task { @MainActor in self?.stopped(result) }
        }
    }

    private func stopped(_ result: Result<Void, ProviderSessionFailure>) {
        guard !stopSettled else { return }
        stopSettled = true
        expireIfDue()
        clearDeadline()
        switch result {
        case .success: backend = nil; becomeQuiescent()
        case .failure:
            phase = .cleanupUnconfirmed
            finishStops(.failure(.cleanupUnconfirmed))
            event(.failed(.cleanupUnconfirmed))
            // Retain uncertain resources. No success, automatic rebuild or guessed rollback.
        }
    }

    private func expired(_ token: UUID) {
        guard deadlineID == token else { return }
        clearDeadline()
        switch phase {
        case .loading: becomeQuiescent(failingStart: .credentialTimeout)
        case .starting:
            phase = .drainingStart
            backend?.invalidate()
            arm(after: timeouts.stop)
            failStart(.startTimeout)
        case .drainingStart, .stopping:
            phase = .cleanupUnconfirmed
            finishStops(.failure(.cleanupUnconfirmed))
            event(.failed(.cleanupUnconfirmed))
            // Late start/stop callbacks are still drained. Timeout is not native cancellation.
        default: break
        }
    }

    private func failStart(_ error: ProviderSessionFailure) {
        let completion = startCompletion; startCompletion = nil
        completion?(.failure(error))
        event(.failed(error))
    }

    private func becomeQuiescent(failingStart error: ProviderSessionFailure? = nil) {
        clearDeadline()
        phase = .awaitingSystemTeardown
        let shouldReport = !quiescenceReported
        // Remove pending handlers before any callback can re-enter the controller.
        let stops = stopCompletions; stopCompletions.removeAll()
        if let error { failStart(error) }
        if shouldReport { quiescenceReported = true; event(.backendQuiescent) }
        for completion in stops { completion(.success(())) }
    }

    private func finishStops(_ result: Result<Void, ProviderSessionFailure>) {
        let pending = stopCompletions; stopCompletions.removeAll()
        for completion in pending { completion(result) }
    }

    private func arm(after delay: Duration) {
        clearDeadline()
        let token = UUID(); deadlineID = token; deadlineAt = scheduler.now + delay
        deadline = scheduler.schedule(after: delay) { [weak self] in self?.expired(token) }
    }
    private func expireIfDue() {
        if let token = deadlineID, let due = deadlineAt, scheduler.now >= due { expired(token) }
    }
    private func clearDeadline() {
        deadlineID = nil; deadlineAt = nil; deadline?.cancel(); deadline = nil
    }
}
