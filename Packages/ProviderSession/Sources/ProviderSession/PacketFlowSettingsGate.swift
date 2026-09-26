// SPDX-License-Identifier: MIT
import Foundation

/// Serializes one NE settings apply and its removal. An apply timeout is NOT OS
/// cancellation: removal waits for that exact apply callback, even after timeout.
/// Call remove only AFTER the packet engine has stopped. The host retains this
/// gate on uncertainty; neither a nil-settings ACK nor this class proves OS recovery.
@MainActor
public final class PacketFlowSettingsGate {
    public enum Event: String, Sendable {
        case applySubmitted, applyAcknowledged, clearSubmitted, clearAcknowledged, cleanupUnconfirmed
    }
    public typealias Reply = @MainActor (Result<Void, ProviderSessionFailure>) -> Void
    public typealias Operation = @MainActor (@escaping @Sendable (Bool) -> Void) -> Void
    private let applyOperation: Operation
    private let clearOperation: Operation
    private let scheduler: any SessionDeadlineScheduler
    private let event: @MainActor (Event) -> Void
    private let timeout: Duration
    private var used = false
    private var revoked = false
    private var applyPending = false
    private var clearPending = false
    private var removeRequested = false
    private var clearSubmitted = false
    private var applyDue: Duration = .zero
    private var clearDue: Duration = .zero
    private var applyTimer: (any SessionDeadlineCancellation)?
    private var clearTimer: (any SessionDeadlineCancellation)?
    private var applyReply: Reply?
    private var clearReply: Reply?
    public private(set) var clearAcknowledged = false
    public private(set) var cleanupUnconfirmed = false

    public init(timeout: Duration = .seconds(5),
                scheduler: any SessionDeadlineScheduler = TaskSessionDeadlineScheduler(),
                apply: @escaping Operation, clear: @escaping Operation,
                event: @escaping @MainActor (Event) -> Void = { _ in }) throws {
        guard timeout > .zero, timeout <= .seconds(60) else { throw ProviderSessionFailure.configurationRejected }
        self.timeout = timeout; self.scheduler = scheduler
        applyOperation = apply; clearOperation = clear; self.event = event
    }

    public func apply(completion: @escaping Reply) {
        guard !used, !revoked else { completion(.failure(.invalidState)); return }
        used = true; applyPending = true; applyReply = completion
        applyDue = scheduler.now + timeout
        applyTimer = scheduler.schedule(after: timeout) { [weak self] in
            self?.finishApply(.failure(.startTimeout))
        }
        event(.applySubmitted)
        applyOperation { [self] success in
            Task { @MainActor in self.applied(success) }
        }
    }
    public func invalidate() {
        revoked = true
        finishApply(.failure(.cancelled))
    }
    public func remove(completion: @escaping Reply) {
        guard !removeRequested else { completion(.failure(.invalidState)); return }
        removeRequested = true; revoked = true; clearReply = completion
        clearDue = scheduler.now + timeout
        clearTimer = scheduler.schedule(after: timeout) { [weak self] in self?.uncertain() }
        finishApply(.failure(.cancelled))
        if !used { finishClear(.success(())); return }
        clearWhenSettled()
    }
    private func applied(_ success: Bool) {
        guard applyPending else { return }
        applyPending = false
        let timely = scheduler.now < applyDue
        if timely && success && !revoked && applyReply != nil {
            event(.applyAcknowledged)
            finishApply(.success(()))
        } else {
            finishApply(.failure(!timely ? .startTimeout : (revoked ? .cancelled : .backendStart)))
        }
        clearWhenSettled()
    }
    private func clearWhenSettled() {
        guard removeRequested, used, !applyPending, !clearSubmitted else { return }
        clearSubmitted = true; clearPending = true
        event(.clearSubmitted)
        clearOperation { [self] success in
            Task { @MainActor in
                guard self.clearPending else { return }
                self.clearPending = false
                if success {
                    self.clearAcknowledged = true
                    self.event(.clearAcknowledged)
                }
                // A late ACK never retroactively turns the timed-out operation into PASS.
                if !success || self.scheduler.now >= self.clearDue || self.cleanupUnconfirmed {
                    self.uncertain()
                } else { self.finishClear(.success(())) }
            }
        }
    }
    private func uncertain() {
        if !cleanupUnconfirmed { cleanupUnconfirmed = true; event(.cleanupUnconfirmed) }
        finishClear(.failure(.cleanupUnconfirmed))
    }
    private func finishApply(_ result: Result<Void, ProviderSessionFailure>) {
        let reply = applyReply; applyReply = nil
        applyTimer?.cancel(); applyTimer = nil
        reply?(result)
    }
    private func finishClear(_ result: Result<Void, ProviderSessionFailure>) {
        let reply = clearReply; clearReply = nil
        clearTimer?.cancel(); clearTimer = nil
        reply?(result)
    }
}
