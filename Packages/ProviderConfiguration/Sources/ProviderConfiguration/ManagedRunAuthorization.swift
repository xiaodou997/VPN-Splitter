// SPDX-License-Identifier: MIT
import Foundation

/// Explicit intent in the authenticated envelope. Legacy v1 messages are check-only.
public enum ManagedDeliveryPurpose: String, Sendable { case check, run }

/// Process-local runtime permission derived from a consumed authenticated connection.
/// Not a serializable token, identity proof, or secret. Closing the XPC channel revokes
/// isCurrent immediately, even before the actor processes its invalidation notification.
public final class ManagedRunAuthorization: @unchecked Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let lock = NSLock()
    private var valid = true
    private let connectionIsLive: @Sendable () -> Bool
    init(connectionIsLive: @escaping @Sendable () -> Bool) { self.connectionIsLive = connectionIsLive }
    public func isCurrent() -> Bool {
        lock.lock(); let permitted = valid; lock.unlock()
        return permitted && connectionIsLive()
    }
    public func invalidate() { lock.lock(); valid = false; lock.unlock() }
    public var description: String { "ManagedRunAuthorization(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}
