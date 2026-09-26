// SPDX-License-Identifier: MIT
// TEST DOUBLE: in-memory flow, no TUN/NE/system settings.
import Foundation
public final class NEPacketTunnelFlow: @unchecked Sendable {
    public typealias Reader = @Sendable ([Data], [NSNumber]) -> Void
    private let lock = NSLock()
    private var reader: Reader?
    private var prior: Reader?
    private var written: [Data] = []
    private var rejectWrites = false
    public init() {}
    public func readPackets(completionHandler: @escaping Reader) {
        lock.lock(); precondition(reader == nil); reader = completionHandler; lock.unlock()
    }
    public func writePackets(_ packets: [Data], withProtocols protocols: [NSNumber]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !rejectWrites else { return false }
        precondition(protocols.allSatisfy { $0.int32Value == 2 })
        written += packets; return true
    }
    public var readIsPending: Bool { lock.lock(); defer { lock.unlock() }; return reader != nil }
    public var packets: [Data] { lock.lock(); defer { lock.unlock() }; return written }
    public func failWrites() { lock.lock(); rejectWrites = true; lock.unlock() }
    public func inject(_ packets: [Data], family: Int32 = 2, duplicate: Bool = false) {
        lock.lock(); let callback = reader; reader = nil; prior = callback; lock.unlock()
        precondition(callback != nil)
        let protocols = packets.map { _ in NSNumber(value: family) }
        callback?(packets, protocols)
        if duplicate { callback?(packets, protocols) }
    }
    public func replayOld(_ packet: Data) {
        lock.lock(); let callback = prior ?? reader; lock.unlock()
        callback?([packet], [NSNumber(value: 2)])
    }
}
public final class NEPacketTunnelProvider {
    public let packetFlow = NEPacketTunnelFlow()
    public init() {}
}
