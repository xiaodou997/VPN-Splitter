// SPDX-License-Identifier: MIT
import Foundation

/// All calls occur on the service actor. Preparing is read-only; start is the only
/// path allowed to construct a writable driver/journal and perform an ADD.
public protocol ExternalControlledLease: AnyObject {
    var proposals: [ExternalControlProposal] { get }
    var result: ExternalControlResult { get }
    func start()
    func poll()
    func stop()
}

/// One service-wide reservation/session. IPC authentication is supplied by the
/// native listener, not by profile IDs, tickets, UID fields or this state machine.
public actor ExternalControlService {
    public nonisolated let instance = UUID()
    private let allowApply: Bool
    private let now: @Sendable () -> TimeInterval
    private let authorize: @Sendable (UInt32) -> Bool
    private let factory: @Sendable (String, ExternalControlCancellation) throws -> any ExternalControlledLease
    private let recovery: @Sendable (ExternalControlAction) throws -> ExternalControlResult
    private struct Client {
        let peer: ExternalControlPeer
        var requests: Set<UUID> = []
        var heartbeat: TimeInterval
    }
    private struct Session {
        let owner: UUID
        let profile: UUID
        let revision: UUID
        let ticket: UUID
        let made: TimeInterval
        let cancellation: ExternalControlCancellation
        let lease: any ExternalControlledLease
        var started: TimeInterval?
    }
    private var clients: [UUID: Client] = [:]
    private var session: Session?
    private var terminal: [UUID: ExternalControlResult] = [:]
    private var blocked = false
    private var shuttingDown = false
    private var lastClock: TimeInterval = 0
    public init(allowApply: Bool, initialRecovery: Bool = false, now: @escaping @Sendable () -> TimeInterval,
                authorize: @escaping @Sendable (UInt32) -> Bool,
                factory: @escaping @Sendable (String, ExternalControlCancellation) throws -> any ExternalControlledLease,
                recovery: @escaping @Sendable (ExternalControlAction) throws -> ExternalControlResult = { _ in
                    .init(.refused, code: ExternalControlError.unavailable.rawValue)
                }) {
        self.allowApply = allowApply; self.blocked = initialRecovery; self.now = now
        self.authorize = authorize; self.factory = factory; self.recovery = recovery
    }
    public func handle(_ request: ExternalControlRequest, peer: ExternalControlPeer) -> ExternalControlReply {
        tick()
        func reply(_ result: ExternalControlResult) -> ExternalControlReply {
            .init(requestID: request.id, instance: instance, canApply: allowApply, result: result)
        }
        func refused(_ error: ExternalControlError) -> ExternalControlReply { reply(.init(.refused, code: error.rawValue)) }
        guard !shuttingDown else { return refused(.unavailable) }
        guard (try? ExternalControlRequest.decode(request.encoded())) != nil else { return refused(.invalidRequest) }
        let time = now()
        guard time.isFinite, time >= lastClock else { return refused(.expired) }
        lastClock = time
        if request.action == .hello {
            guard !peer.cancellation.isCancelled, peer.uid != 0, authorize(peer.uid), clients[peer.id] == nil,
                  clients.count < 8 else { return refused(.authentication) }
            clients[peer.id] = Client(peer: peer, requests: [request.id], heartbeat: time)
            return reply(.init(blocked ? .recoveryRequired : (session == nil ? .idle : .refused),
                               code: blocked ? "recoveryRequired" : (session == nil ? "none" : "busy")))
        }
        guard var client = clients[peer.id], client.peer.uid == peer.uid,
              client.peer.cancellation === peer.cancellation,
              request.instance == instance else { return refused(.authentication) }
        guard !client.requests.contains(request.id), client.requests.count < 512 else { return refused(.invalidRequest) }
        client.requests.insert(request.id); client.heartbeat = time; clients[peer.id] = client
        // A revoked peer may retrieve its terminal result or explicitly finish; it
        // cannot prepare/apply again. Only the owner can stop a reservation/session.
        if request.action == .stop {
            peer.cancellation.cancel()
            if session?.owner == peer.id { finish() }
            return reply(terminal[peer.id] ?? .init(blocked ? .recoveryRequired : .closed,
                                                  code: blocked ? "recoveryRequired" : "noSession"))
        }
        if request.action == .status {
            if let result = terminal[peer.id] { return reply(result) }
            if let session, session.owner == peer.id { return reply(session.lease.result) }
            return reply(.init(blocked ? .recoveryRequired : (session == nil ? .idle : .refused),
                               code: blocked ? "recoveryRequired" : (session == nil ? "none" : "busy")))
        }
        guard !peer.cancellation.isCancelled, authorize(peer.uid) else { return refused(.authentication) }
        if request.action == .recoveryAudit {
            guard blocked, session == nil else {
                return reply(.init(blocked ? .recoveryRequired : .idle,
                                   code: blocked ? "recoveryRequired" : "noRecovery"))
            }
            do { return reply(try recovery(.recoveryAudit)) }
            catch { return reply(.init(.recoveryRequired, code: "recoveryAuditFailed")) }
        }
        if request.action == .recoveryClear {
            guard blocked, session == nil else {
                return reply(.init(blocked ? .recoveryRequired : .idle,
                                   code: blocked ? "recoveryRequired" : "noRecovery"))
            }
            do {
                let result = try recovery(.recoveryClear)
                if result.state == .closed, result.code == "recoveryCleared",
                   result.recoveryPresent == 0 { blocked = false }
                return reply(result)
            } catch { return reply(.init(.recoveryRequired, code: "recoveryClearFailed")) }
        }
        guard !blocked else { return reply(.init(.recoveryRequired, code: "recoveryRequired")) }
        if request.action == .quiesce {
            guard session == nil else { return refused(.busy) }
            shuttingDown = true // Prevent a new prepare racing system unregistration.
            return reply(.init(.closed, code: "quiesced"))
        }
        guard terminal[peer.id] == nil else { return refused(.disconnected) }
        do {
            switch request.action {
            case .prepare:
                guard session == nil else { return refused(.busy) }
                let lease = try factory(request.rules!, peer.cancellation)
                guard !peer.cancellation.isCancelled, authorize(peer.uid), now() - time < 15,
                      !lease.proposals.isEmpty, lease.proposals.count <= 8 else { return refused(.expired) }
                let value = Session(owner: peer.id, profile: request.profile!, revision: request.revision!,
                                    ticket: UUID(), made: time, cancellation: peer.cancellation, lease: lease)
                session = value
                var response = reply(.init(.prepared)); response.ticket = value.ticket; response.proposals = lease.proposals
                return response
            case .apply:
                guard allowApply else { return refused(.trialDisabled) }
                guard var value = session, value.owner == peer.id, value.started == nil,
                      value.ticket == request.ticket, value.profile == request.profile, value.revision == request.revision,
                      time - value.made < 15 else { return refused(.staleSelection) }
                // Consume before the first effect. No second apply can revive this ticket.
                value.started = time; session = value
                value.lease.start()
                let result = value.lease.result
                if peer.cancellation.isCancelled || !authorize(peer.uid) { finish() }
                else if result.state != .active { finish() }
                return reply(terminal[peer.id] ?? value.lease.result)
            case .recoveryAudit, .recoveryClear: return refused(.invalidRequest)
            default: return refused(.invalidRequest)
            }
        } catch {
            // No raw exception/config/path is sent to the GUI.
            let code = (error as? ExternalControlError)?.rawValue ?? "observationFailed"
            return reply(.init(.refused, code: code))
        }
    }
    /// Called by a service-owned timer, not solely by GUI status polling.
    public func tick() {
        let time = now()
        let clockFailed = !time.isFinite || time < lastClock
        if !clockFailed { lastClock = time }
        if let value = session {
            let peer = clients[value.owner]
            let denied = peer == nil || value.cancellation.isCancelled || !authorize(peer!.peer.uid)
            let heartbeatExpired = peer.map { time - $0.heartbeat >= 10 } ?? true
            let expired = value.started.map { time - $0 >= 60 } ?? (time - value.made >= 15)
            if clockFailed || denied || heartbeatExpired || expired { finish() }
            else if value.started != nil {
                value.lease.poll()
                if value.lease.result.state != .active { finish() }
            }
        }
        // Drop unaffiliated idle clients without retaining an unbounded result history.
        for (id, client) in clients where session?.owner != id && (time - client.heartbeat >= 30) {
            clients.removeValue(forKey: id); terminal.removeValue(forKey: id)
        }
    }
    public func disconnect(_ peer: ExternalControlPeer) {
        peer.cancellation.cancel()
        if session?.owner == peer.id { finish() }
        clients.removeValue(forKey: peer.id); terminal.removeValue(forKey: peer.id)
    }
    public func shutdown() {
        shuttingDown = true
        for client in clients.values { client.peer.cancellation.cancel() }
        finish(); clients.removeAll(); terminal.removeAll()
    }
    private func finish() {
        guard let value = session else { return }
        value.cancellation.cancel()
        if value.started != nil {
            value.lease.stop()
            var result = value.lease.result
            // Never promote unknown native states or an owned receipt to clean closure.
            if result.state != .closed || result.owned != 0 { result.state = .recoveryRequired; blocked = true }
            terminal[value.owner] = result
        } else { terminal[value.owner] = .init(.closed, code: "notApplied") }
        session = nil
    }
}
