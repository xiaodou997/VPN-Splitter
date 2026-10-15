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

/// Executes DIRECT decisions for TCP flows: opens the flow, dials the original
/// destination bound to the current physical interface, and runs a bounded
/// bidirectional `ExternalFlowRelay`. Decision happens synchronously in
/// `handle`; everything after `return true` is fail-closed (the flow is closed
/// on any error, limit or timeout, never silently handed back). While paused
/// (ADR-EX-INT-08), DIRECT-matched flows are closed immediately instead of
/// relayed, so a VPN outage cannot turn them into silent direct connections.
/// No flow content is logged or persisted anywhere in this file.
final class ExternalFlowRelayEngine: @unchecked Sendable {
    private struct State {
        var policy: ExternalFlowPolicy?
        var paused = false
        var interface: NWInterface?
        var relays: [UUID: ExternalFlowRelay] = [:]
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

    /// Cancels every live relay and stops interface tracking. Called from stopProxy.
    func stop() {
        let relays = state.withLock { s -> [ExternalFlowRelay] in
            s.policy = nil; s.interface = nil
            let relays = Array(s.relays.values); s.relays.removeAll(); return relays
        }
        if monitorRunning { monitor.cancel(); monitorRunning = false }
        for relay in relays { Task { await relay.cancel() } }
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

    private static func established(_ connection: NWConnection) async throws {
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
#endif
