// SPDX-License-Identifier: MIT
import Foundation

/// A UDP flow's remote peer, used as the NAT table key. The provider derives
/// it from each datagram's NWEndpoint; it is never logged or persisted.
public struct ExternalFlowUDPEndpoint: Hashable, Sendable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public struct ExternalFlowUDPDatagram: Sendable, Equatable {
    public let endpoint: ExternalFlowUDPEndpoint
    public let data: Data
    public init(endpoint: ExternalFlowUDPEndpoint, data: Data) {
        self.endpoint = endpoint
        self.data = data
    }
}

/// App-flow side of a UDP relay. UDP has no EOF: `readDatagrams` returns nil
/// only once the flow has been closed locally (shutdown). Implementations must
/// be cancellation-safe: after `close()` every pending and future read returns
/// nil or throws. No payload may be logged or persisted by implementations.
public protocol ExternalFlowUDPDatagramSource: Sendable {
    /// Returns nil once the flow is closed; an empty batch is a spurious wakeup.
    func readDatagrams() async throws -> [ExternalFlowUDPDatagram]?
    /// Writes response datagrams back to the app, preserving source endpoints.
    func writeDatagrams(_ datagrams: [ExternalFlowUDPDatagram]) async throws
    func close() async
}

/// One upstream UDP association for a single remote endpoint (provider backs
/// this with an NWConnection bound to the physical interface).
public protocol ExternalFlowUDPLink: Sendable {
    func send(_ data: Data) async throws
    /// Returns nil once the link is closed locally; UDP has no EOF.
    func receive() async throws -> Data?
    func close() async
}

public protocol ExternalFlowUDPLinkFactory: Sendable {
    /// Creates and establishes a link for a never-before-seen endpoint.
    func makeLink(endpoint: ExternalFlowUDPEndpoint) async throws -> any ExternalFlowUDPLink
}

public struct ExternalFlowUDPRelayLimits: Sendable, Equatable {
    public var maxEndpointsPerFlow: Int
    public var maxDatagramBytes: Int
    public var idleTimeout: TimeInterval
    public static let `default` = Self(maxEndpointsPerFlow: 8, maxDatagramBytes: 65_535, idleTimeout: 75)
    public init(maxEndpointsPerFlow: Int = 8, maxDatagramBytes: Int = 65_535,
                idleTimeout: TimeInterval = 75) {
        self.maxEndpointsPerFlow = maxEndpointsPerFlow
        self.maxDatagramBytes = maxDatagramBytes
        self.idleTimeout = idleTimeout
    }
}

/// Endpoint-keyed bounded UDP relay (ADR-EX-FLOW-03). Inbound datagrams are
/// grouped by remote endpoint; each endpoint gets one upstream link created
/// lazily by the factory, and responses are written back to the source with
/// the originating endpoint preserved. There is no EOF: the idle timeout is
/// the only normal end and yields `.completed`. Any read/write/make error,
/// endpoint overflow or oversized datagram closes everything and yields
/// `.failed` (fail-closed); `cancel()` yields `.cancelled`.
public actor ExternalFlowUDPRelay {
    private enum Failure: Error { case endpointLimit }

    private enum StageResult: Sendable {
        case inboundEnded, idleExpired, failed
    }

    private struct LinkEntry {
        let link: any ExternalFlowUDPLink
        let responses: Task<Void, Never>
    }

    private let source: any ExternalFlowUDPDatagramSource
    private let factory: any ExternalFlowUDPLinkFactory
    private let limits: ExternalFlowUDPRelayLimits
    private var links: [ExternalFlowUDPEndpoint: LinkEntry] = [:]
    private var lastActivity: ContinuousClock.Instant
    private var cancelRequested = false
    private var failed = false

    public init(source: any ExternalFlowUDPDatagramSource,
                factory: any ExternalFlowUDPLinkFactory,
                limits: ExternalFlowUDPRelayLimits = .default) {
        self.source = source
        self.factory = factory
        self.limits = limits
        self.lastActivity = .now
    }

    public func run() async -> ExternalFlowRelayOutcome {
        let stage = await withTaskGroup(of: StageResult.self, returning: StageResult.self) { group in
            group.addTask { await self.inboundLoop() }
            group.addTask { await self.watchdog() }
            var first: StageResult?
            for await result in group {
                guard first == nil else { continue }
                first = result
                if result == .failed { self.failed = true }
                await self.closeAll()
                group.cancelAll()
            }
            return first ?? .failed
        }
        await closeAll()
        if cancelRequested { return .cancelled }
        if failed || stage == .failed { return .failed }
        return .completed
    }

    /// Unblocks in-flight reads by closing the source and every link; `run()`
    /// then returns `.cancelled`. Safe to call more than once.
    public func cancel() {
        guard !cancelRequested else { return }
        cancelRequested = true
        Task { await self.closeAll() }
    }

    private func noteActivity() { lastActivity = .now }

    /// true is never returned: the stage result says how the loop ended.
    private func inboundLoop() async -> StageResult {
        do {
            while true {
                try Task.checkCancellation()
                if cancelRequested || failed { return .inboundEnded }
                guard let datagrams = try await source.readDatagrams() else { return .inboundEnded }
                for datagram in datagrams {
                    guard datagram.data.count <= limits.maxDatagramBytes else { return .failed }
                    let link = try await link(for: datagram.endpoint)
                    noteActivity()
                    try await link.send(datagram.data)
                }
                noteActivity()
            }
        } catch {
            return cancelRequested || failed ? .inboundEnded : .failed
        }
    }

    private func link(for endpoint: ExternalFlowUDPEndpoint) async throws -> any ExternalFlowUDPLink {
        if let entry = links[endpoint] { return entry.link }
        guard links.count < limits.maxEndpointsPerFlow else { throw Failure.endpointLimit }
        let link = try await factory.makeLink(endpoint: endpoint)
        let responses = Task { await self.responseLoop(endpoint: endpoint, link: link) }
        links[endpoint] = LinkEntry(link: link, responses: responses)
        return link
    }

    private func responseLoop(endpoint: ExternalFlowUDPEndpoint,
                              link: any ExternalFlowUDPLink) async {
        do {
            while true {
                if Task.isCancelled || cancelRequested || failed { return }
                guard let data = try await link.receive() else { return }
                guard data.count <= limits.maxDatagramBytes else { noteFailure(); return }
                noteActivity()
                try await source.writeDatagrams([ExternalFlowUDPDatagram(endpoint: endpoint, data: data)])
                noteActivity()
            }
        } catch {
            if !cancelRequested && !failed && !Task.isCancelled { noteFailure() }
        }
    }

    private func noteFailure() {
        failed = true
        Task { await self.closeAll() }
    }

    /// Idle expiry is the normal end of a UDP relay; everything else here is
    /// teardown noise and reported neutrally so the first stage result wins.
    private func watchdog() async -> StageResult {
        let interval = max(0.05, min(5, limits.idleTimeout / 2))
        while !Task.isCancelled && !cancelRequested && !failed {
            try? await Task.sleep(for: .seconds(interval))
            if Task.isCancelled || cancelRequested || failed { return .inboundEnded }
            if ContinuousClock.now - lastActivity >= .seconds(limits.idleTimeout) {
                return .idleExpired
            }
        }
        return .inboundEnded
    }

    private func closeAll() async {
        let entries = Array(links.values)
        links.removeAll()
        for entry in entries { entry.responses.cancel() }
        await source.close()
        for entry in entries { await entry.link.close() }
    }
}
