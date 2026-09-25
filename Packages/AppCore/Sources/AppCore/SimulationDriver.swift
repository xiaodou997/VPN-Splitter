// SPDX-License-Identifier: MIT
import Foundation

public enum SimulationScenario: String, CaseIterable, Sendable {
    case success = "正常成功"
    case authenticationFailure = "认证失败（注入）"
    case timeout = "连接超时（不返回结果）"
    case disconnectAfterSuccess = "成功后中断（注入）"
}

/// Cancellation is advisory; driver identity checks also reject already-queued callbacks.
@MainActor
public protocol SimulationCancellation: AnyObject {
    func cancel()
}

@MainActor
public protocol SimulationScheduling {
    /// Monotonic process-local time. Actions run asynchronously, no earlier than delay.
    var now: Duration { get }
    func schedule(after delay: Duration, action: @escaping @MainActor @Sendable () -> Void) -> any SimulationCancellation
}

@MainActor
public struct TaskSimulationScheduler: SimulationScheduling {
    private let origin = ContinuousClock.now
    public var now: Duration { origin.duration(to: .now) }
    public init() {}
    public func schedule(after delay: Duration, action: @escaping @MainActor @Sendable () -> Void) -> any SimulationCancellation {
        TaskSimulationTicket(task: Task {
            do { try await Task.sleep(for: delay, clock: .continuous) }
            catch { return }
            guard !Task.isCancelled else { return }
            action()
        })
    }
}

@MainActor
private final class TaskSimulationTicket: SimulationCancellation {
    let task: Task<Void, Never>
    init(task: Task<Void, Never>) { self.task = task }
    func cancel() { task.cancel() }
    deinit { task.cancel() }
}

/// Timer-only simulator, NOT a protocol backend. It never receives configuration or keys.
/// Independent deadline + operation IDs avoid treating Task.cancel as a completion fence.
@MainActor
public final class SimulationDriver {
    public static let connectionTimeout: Duration = .seconds(3)
    private let scheduler: any SimulationScheduling
    private var work: (any SimulationCancellation)?
    private var deadline: (any SimulationCancellation)?
    private var operationID: UUID?
    private var connected = false
    /// Pending simulator timers, not a connected-state or reachability observation.
    public var isRunning: Bool { operationID != nil }

    public init(scheduler: any SimulationScheduling = TaskSimulationScheduler()) { self.scheduler = scheduler }

    public func start(_ attempt: SimulationAttempt, scenario: SimulationScenario,
                      receive: @escaping @MainActor @Sendable (SimulationAttempt, SimulationSignal) -> Void) {
        cancel()
        // The driver generation is independent even if a caller accidentally reuses an attempt.
        let operation = UUID(); operationID = operation
        let expiresAt = scheduler.now + Self.connectionTimeout
        deadline = scheduler.schedule(after: Self.connectionTimeout) { [weak self] in
            guard let self, self.operationID == operation, !self.connected else { return }
            self.cancel()
            receive(attempt, .timedOut)
        }
        guard scenario != .timeout else { return }
        work = scheduler.schedule(after: .seconds(1)) { [weak self] in
            guard let self, self.operationID == operation, !self.connected else { return }
            // A busy main actor can delay both timers; an overdue success must not
            // win merely because its callback happened to dequeue first.
            guard self.scheduler.now < expiresAt else {
                self.cancel(); receive(attempt, .timedOut); return
            }
            self.deadline?.cancel(); self.deadline = nil
            self.work = nil
            if scenario == .authenticationFailure {
                self.cancel(); receive(attempt, .authenticationFailed); return
            }
            self.connected = true
            if scenario == .success {
                self.cancel()
                receive(attempt, .connected)
                return
            }
            receive(attempt, .connected)
            // A receiving owner may have invalidated synchronously.
            guard self.operationID == operation else { return }
            self.work = self.scheduler.schedule(after: .seconds(1)) { [weak self] in
                guard let self, self.operationID == operation, self.connected else { return }
                self.cancel(); receive(attempt, .connectionLost)
            }
        }
    }

    public func stop(token: UUID, complete: @escaping @MainActor @Sendable (UUID) -> Void) {
        cancel()
        let operation = UUID(); operationID = operation
        work = scheduler.schedule(after: .milliseconds(250)) { [weak self] in
            guard let self, self.operationID == operation else { return }
            self.cancel(); complete(token)
        }
    }

    public func cancel() {
        operationID = nil; connected = false
        work?.cancel(); deadline?.cancel()
        work = nil; deadline = nil
    }
}
