// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import Network
import NetworkExtension
import ExternalFlowCore

/// NSLock confined to synchronous helpers (Swift 6 forbids it in async bodies).
private final class LockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}

enum ExternalFlowRelayEngineError: Error {
    case connectionFailed
    case connectionCancelled
}

/// NEAppProxyTCPFlow is not Sendable; ownership of the flow transfers exactly
/// once from handleNewFlow into its relay task.
private struct FlowBox: @unchecked Sendable {
    let flow: NEAppProxyTCPFlow
}

/// Same single-transfer pattern for NEAppProxyUDPFlow.
private struct UDPFlowBox: @unchecked Sendable {
    let flow: NEAppProxyUDPFlow
}

/// Executes DIRECT decisions for intercepted flows: TCP flows are opened,
/// dialed to the original destination bound to the current physical interface
/// and copied by a bounded bidirectional `ExternalFlowRelay`; UDP flows become
/// an endpoint-keyed bounded `ExternalFlowUDPRelay` (ADR-EX-FLOW-03). Decision
/// happens synchronously in `handle`; everything after `return true` is
/// fail-closed (the flow is closed on any error, limit or timeout, never
/// silently handed back). While paused (ADR-EX-INT-08), DIRECT-matched flows
/// are closed immediately instead of relayed, so a VPN outage cannot turn them
/// into silent direct connections. UDP flows expose no remote endpoint at
/// handleNewFlow time, so their descriptor carries no destination IP and only
/// APPLICATION/DOMAIN-class rules can match (ADR-EX-FLOW-03 decision 2).
/// No flow content is logged or persisted anywhere in this file.
final class ExternalFlowRelayEngine: @unchecked Sendable {
    private struct State {
        var policy: ExternalFlowPolicy?
        var paused = false
        var interface: NWInterface?
        var relays: [UUID: ExternalFlowRelay] = [:]
        var udpRelays: [UUID: ExternalFlowUDPRelay] = [:]
    }
    private let state = LockedBox(State())
    private let registry: ExternalFlowRelayRegistry
    private let limits: ExternalFlowRelayLimits
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "io.github.xiaodou997.VPNSplitter.FlowRelay.Path")
    private var monitorRunning = false

    init(limits: ExternalFlowRelayLimits = .default) {
        self.limits = limits
        self.registry = ExternalFlowRelayRegistry(limits: limits)
    }

    /// Installs the compiled policy (nil = pure probe) and starts tracking the
    /// physical interface. Called from startProxy.
    func start(policy: ExternalFlowPolicy?) {
        state.withLock { $0.policy = policy }
        guard !monitorRunning else { return }
        monitorRunning = true
        monitor.pathUpdateHandler = { [state] path in
            let physical = path.availableInterfaces.filter {
                $0.type == .wifi || $0.type == .wiredEthernet
            }
            state.withLock { $0.interface = physical.count == 1 ? physical[0] : nil }
        }
        monitor.start(queue: monitorQueue)
    }

    /// Cancels every live relay (TCP and UDP) and stops interface tracking.
    /// Called from stopProxy.
    func stop() {
        let (relays, udpRelays) = state.withLock { s -> ([ExternalFlowRelay], [ExternalFlowUDPRelay]) in
            s.policy = nil; s.interface = nil
            let relays = Array(s.relays.values); s.relays.removeAll()
            let udpRelays = Array(s.udpRelays.values); s.udpRelays.removeAll()
            return (relays, udpRelays)
        }
        if monitorRunning { monitor.cancel(); monitorRunning = false }
        for relay in relays { Task { await relay.cancel() } }
        for relay in udpRelays { Task { await relay.cancel() } }
    }

    /// Runtime pause switch (ADR-EX-INT-08). Not persisted: startProxy always
    /// resumes with the compiled policy, so a probe restart clears the pause.
    var isPaused: Bool { state.withLock { $0.paused } }
    func setPaused(_ paused: Bool) { state.withLock { $0.paused = paused } }

    /// Synchronous decision only. Returns true when this flow matched a DIRECT
    /// rule and the engine takes ownership (async, fail-closed); false keeps
    /// the flow on the system/VPN path. While paused, matched flows are taken
    /// over and closed immediately instead of being relayed or handed back.
    func handle(_ flow: NEAppProxyTCPFlow, counters: ProbeCounters) -> Bool {
        let (policy, paused, interface) = state.withLock { ($0.policy, $0.paused, $0.interface) }
        let signingIdentifier = flow.metaData.sourceAppSigningIdentifier
        let descriptor = ExternalFlowDescriptor(
            sourceAppSigningIdentifier: signingIdentifier.isEmpty ? nil : signingIdentifier,
            remoteHostname: flow.remoteHostname,
            remoteEndpointHost: Self.hostString(flow.remoteFlowEndpoint))
        switch ExternalFlowRelayGate.decide(policy: policy, paused: paused, descriptor: descriptor,
                                            hasInterface: interface != nil) {
        case .passThrough:
            return false
        case .closedPaused:
            counters.recordRelayRefusedPaused()
            Self.close(flow)
            return true
        case .refusedInterface:
            counters.recordRelayRefusedInterface()
            return false
        case .relay:
            break
        }
        guard let interface else { return false }
        let id = UUID()
        let box = FlowBox(flow: flow)
        Task { [self] in await run(box.flow, interface: interface, id: id, counters: counters) }
        return true
    }

    /// UDP counterpart of the TCP decision (ADR-EX-FLOW-03). The flow has no
    /// remote endpoint yet, so `remoteEndpointHost` is nil and IP-CIDR rules
    /// cannot match; only APPLICATION/DOMAIN-class rules take UDP over.
    /// Gate, pause semantics and the shared concurrency registry are the same
    /// as for TCP.
    func handle(_ flow: NEAppProxyUDPFlow, counters: ProbeCounters) -> Bool {
        let (policy, paused, interface) = state.withLock { ($0.policy, $0.paused, $0.interface) }
        let signingIdentifier = flow.metaData.sourceAppSigningIdentifier
        let descriptor = ExternalFlowDescriptor(
            sourceAppSigningIdentifier: signingIdentifier.isEmpty ? nil : signingIdentifier,
            remoteHostname: flow.remoteHostname,
            remoteEndpointHost: nil)
        switch ExternalFlowRelayGate.decide(policy: policy, paused: paused, descriptor: descriptor,
                                            hasInterface: interface != nil) {
        case .passThrough:
            return false
        case .closedPaused:
            counters.recordRelayRefusedPaused()
            Self.close(flow)
            return true
        case .refusedInterface:
            counters.recordRelayRefusedInterface()
            return false
        case .relay:
            break
        }
        guard let interface else { return false }
        let id = UUID()
        let box = UDPFlowBox(flow: flow)
        Task { [self] in await runUDP(box.flow, interface: interface, id: id, counters: counters) }
        return true
    }

    private static func hostString(_ endpoint: NWEndpoint?) -> String? {
        guard let endpoint, case .hostPort(let host, _) = endpoint else { return nil }
        return "\(host)"
    }

    private func run(_ flow: NEAppProxyTCPFlow, interface: NWInterface, id: UUID,
                     counters: ProbeCounters) async {
        do { try await registry.admit() }
        catch {
            counters.recordRelayRefusedLimit()
            Self.close(flow)
            return
        }
        counters.recordRelayStarted()
        var outcome = ExternalFlowRelayOutcome.failed
        defer {
            counters.recordRelayEnded(outcome)
            state.withLock { _ = $0.relays.removeValue(forKey: id) }
            Task { await registry.release() }
            Self.close(flow)
        }
        do {
            try await Self.open(flow)
            let endpoint = flow.remoteFlowEndpoint
            let parameters = NWParameters.tcp
            parameters.requiredInterface = interface
            let connection = NWConnection(to: endpoint, using: parameters)
            let relay = ExternalFlowRelay(local: TCPFlowPipe(flow: flow),
                                          remote: ConnectionPipe(connection: connection),
                                          limits: limits)
            state.withLock { $0.relays[id] = relay }
            try await Self.established(connection)
            outcome = await relay.run()
        } catch {
            outcome = .failed
        }
    }

    private func runUDP(_ flow: NEAppProxyUDPFlow, interface: NWInterface, id: UUID,
                        counters: ProbeCounters) async {
        do { try await registry.admit() }
        catch {
            counters.recordRelayUDPRefusedLimit()
            Self.close(flow)
            return
        }
        counters.recordRelayUDPStarted()
        var outcome = ExternalFlowRelayOutcome.failed
        defer {
            counters.recordRelayUDPEnded(outcome)
            state.withLock { _ = $0.udpRelays.removeValue(forKey: id) }
            Task { await registry.release() }
            Self.close(flow)
        }
        do {
            try await Self.open(flow)
            let source = UDPFlowSource(flow: flow)
            let relay = ExternalFlowUDPRelay(
                source: source,
                factory: UDPLinkFactory(interface: interface, source: source),
                limits: ExternalFlowUDPRelayLimits(idleTimeout: limits.idleTimeout))
            state.withLock { $0.udpRelays[id] = relay }
            outcome = await relay.run()
        } catch {
            outcome = .failed
        }
    }

    private static func close(_ flow: NEAppProxyUDPFlow) {
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }

    private static func open(_ flow: NEAppProxyUDPFlow) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            flow.open(withLocalFlowEndpoint: nil) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private static func close(_ flow: NEAppProxyTCPFlow) {
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }

    private static func open(_ flow: NEAppProxyTCPFlow) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            flow.open(withLocalFlowEndpoint: nil) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    fileprivate static func established(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed, .waiting:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: ExternalFlowRelayEngineError.connectionFailed)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: ExternalFlowRelayEngineError.connectionCancelled)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }
}

/// NEAppProxyTCPFlow side of the relay. `closeWrite` maps to
/// `closeWriteWithError(nil)` (best-effort half-close); `close` shuts both
/// directions so pending reads complete.
private final class TCPFlowPipe: ExternalFlowPipe, @unchecked Sendable {
    private let flow: NEAppProxyTCPFlow
    init(flow: NEAppProxyTCPFlow) { self.flow = flow }

    func readChunk(maxBytes: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            flow.readData { data, error in
                if let error { continuation.resume(throwing: error); return }
                guard let data, !data.isEmpty else { continuation.resume(returning: nil); return }
                continuation.resume(returning: data)
            }
        }
    }
    func writeChunk(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            flow.write(data) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    func closeWrite() async { flow.closeWriteWithError(nil) }
    func close() async {
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }
}

/// NWConnection side of the relay, bound by the engine to the physical
/// interface. `closeWrite` sends a final completion (TCP FIN); `close` cancels
/// the connection, which also completes any pending receive.
private final class ConnectionPipe: ExternalFlowPipe, @unchecked Sendable {
    private let connection: NWConnection
    init(connection: NWConnection) { self.connection = connection }

    func readChunk(maxBytes: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxBytes) { content, _, _, error in
                if let error { continuation.resume(throwing: error); return }
                guard let content, !content.isEmpty else { continuation.resume(returning: nil); return }
                continuation.resume(returning: content)
            }
        }
    }
    func writeChunk(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
    func closeWrite() async {
        connection.send(content: nil, contentContext: .defaultMessage, isComplete: true,
                        completion: .contentProcessed { _ in })
    }
    func close() async { connection.cancel() }
}

/// NEAppProxyUDPFlow side of a UDP relay. Endpoint keys are remembered per
/// flow so responses can be written back with the original NWEndpoint; the
/// table is bounded by the relay's per-flow endpoint limit and dropped with
/// the flow. Nothing is logged or persisted.
private final class UDPFlowSource: ExternalFlowUDPDatagramSource, @unchecked Sendable {
    private let flow: NEAppProxyUDPFlow
    private let endpoints = LockedBox<[ExternalFlowUDPEndpoint: NWEndpoint]>([:])
    private let closed = LockedBox(false)

    init(flow: NEAppProxyUDPFlow) { self.flow = flow }

    func nwEndpoint(for key: ExternalFlowUDPEndpoint) -> NWEndpoint? {
        endpoints.withLock { $0[key] }
    }

    func readDatagrams() async throws -> [ExternalFlowUDPDatagram]? {
        let (datagrams, error) = await flow.readDatagrams()
        if let error {
            if closed.withLock({ $0 }) { return nil }
            throw error
        }
        guard let datagrams, !datagrams.isEmpty else {
            return closed.withLock { $0 } ? nil : []
        }
        var result: [ExternalFlowUDPDatagram] = []
        result.reserveCapacity(datagrams.count)
        for (data, endpoint) in datagrams {
            guard let key = Self.key(for: endpoint) else { continue }
            endpoints.withLock { $0[key] = endpoint }
            result.append(ExternalFlowUDPDatagram(endpoint: key, data: data))
        }
        return result
    }

    func writeDatagrams(_ datagrams: [ExternalFlowUDPDatagram]) async throws {
        var pairs: [(Data, NWEndpoint)] = []
        pairs.reserveCapacity(datagrams.count)
        for datagram in datagrams {
            guard let endpoint = nwEndpoint(for: datagram.endpoint) else { continue }
            pairs.append((datagram.data, endpoint))
        }
        guard !pairs.isEmpty else { return }
        try await flow.writeDatagrams(pairs)
    }

    func close() async {
        closed.withLock { $0 = true }
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }

    private static func key(for endpoint: NWEndpoint) -> ExternalFlowUDPEndpoint? {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        return ExternalFlowUDPEndpoint(host: "\(host)", port: port.rawValue)
    }
}

/// Builds one UDP NWConnection per remote endpoint, bound to the physical
/// interface, and waits for it to reach ready before the relay uses it.
private struct UDPLinkFactory: ExternalFlowUDPLinkFactory {
    let interface: NWInterface
    let source: UDPFlowSource

    func makeLink(endpoint: ExternalFlowUDPEndpoint) async throws -> any ExternalFlowUDPLink {
        guard let remote = source.nwEndpoint(for: endpoint) else {
            throw ExternalFlowRelayEngineError.connectionFailed
        }
        let parameters = NWParameters.udp
        parameters.requiredInterface = interface
        let connection = NWConnection(to: remote, using: parameters)
        let link = UDPLink(connection: connection)
        try await ExternalFlowRelayEngine.established(connection)
        return link
    }
}

/// Per-endpoint upstream UDP connection. `receive` returns whole datagrams and
/// nil once the connection is cancelled; `close` cancels the connection, which
/// also completes any pending receive.
private final class UDPLink: ExternalFlowUDPLink, @unchecked Sendable {
    private let connection: NWConnection
    init(connection: NWConnection) { self.connection = connection }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { content, _, _, error in
                if let error { continuation.resume(throwing: error); return }
                guard let content, !content.isEmpty else { continuation.resume(returning: nil); return }
                continuation.resume(returning: content)
            }
        }
    }
    func close() async { connection.cancel() }
}
#endif
