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
