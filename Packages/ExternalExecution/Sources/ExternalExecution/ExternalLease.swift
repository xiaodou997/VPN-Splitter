// SPDX-License-Identifier: MIT
import Foundation
import ExternalCore
import PolicyCore

public enum ExternalLeaseFailure: String, Error, Sendable {
    case invalidState, consentRequired, limit, expired, cancelled, networkChanged
    case observationFailed, routeRejected, routeUncertain, readbackFailed, journalFailed, recoveryRequired
}
public enum ExternalLeaseState: String, Sendable { case idle, applying, active, stopping, closed, recoveryRequired }
public enum ExternalPostObservation: String, Sendable { case notObserved, unchanged, changed }

public struct ExternalLeaseRoute: Hashable, Codable, Sendable {
    public let destination: IPv4CIDR
    public let gateway: IPv4Address
    public let interface: String
    init(_ proposal: ExternalRouteProposal) {
        destination = proposal.destination; gateway = proposal.gateway; interface = proposal.interface
    }
    func matches(_ route: ExternalRoute) -> Bool {
        route.destination == destination && route.gateway == gateway.description && route.interface == interface &&
        !route.scoped && route.usable && route.flags.contains("G") && route.flags.contains("S") &&
        route.flags.contains("2") && !route.flags.contains("W") && !route.flags.contains("L") &&
        !route.flags.contains("D") && !route.flags.contains("M")
    }
}

/// A bounded review of observed state; not an IPC capability or administrator identity.
/// The foreground host obtains OS privilege + console confirmation independently.
public struct ExternalLeasePlan: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let preview: ExternalPreview
    public let additions: [ExternalLeaseRoute]
    public let baseline: ExternalObservation
    public let reviewedAt: TimeInterval
    public let lifetime: TimeInterval
    public static func prepare(rules: String, observation: ExternalObservation, uptime: TimeInterval,
                               clock: TimeInterval, lifetime: TimeInterval = 60) throws -> Self {
        guard clock.isFinite, clock >= 0, lifetime > 0, lifetime <= 60 else { throw ExternalLeaseFailure.limit }
        let preview = try ExternalPlanner.preview(rules, observation: observation, now: uptime)
        // Explicit trial limits, not silent clipping or prefix widening. The preview's
        // broader 64-rule scope is unchanged; foreground execution has a smaller budget.
        guard (1...8).contains(preview.proposals.count),
              preview.proposals.allSatisfy({ (24...32).contains($0.destination.prefixLength) }),
              preview.proposals.reduce(UInt64(0), { $0 + $1.destination.addressCount }) <= 2048 else {
            throw ExternalLeaseFailure.limit
        }
        return Self(preview: preview, additions: preview.proposals.filter { $0.disposition == .wouldAdd }.map(ExternalLeaseRoute.init),
                    baseline: observation, reviewedAt: clock, lifetime: lifetime)
    }
    public var description: String { "ExternalLeasePlan(<redacted>; not-authorized)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// Tokens belong to one native socket context, are never persisted or accepted over IPC.
/// A native token is issued only for the exact successful ADD reply (pid/seq/type/key).
public enum ExternalAddResult { case acknowledged(UInt64), rejected, uncertain }
public enum ExternalRemoveResult { case acknowledged, refused, uncertain }

/// Single-owner, synchronous calls. Implementations MUST NOT retry writes or equate
/// an identical existing route with ownership. No generic command/path interface.
public protocol ExternalRouteOperating: AnyObject {
    func observe() throws -> ExternalObservation
    func drainEvents() -> Bool
    func add(_ route: ExternalLeaseRoute) -> ExternalAddResult
    func owns(_ token: UInt64) -> Bool
    func remove(_ token: UInt64) -> ExternalRemoveResult
}
public protocol ExternalLeaseJournaling: AnyObject {
    func begin(session: UUID, routes: [ExternalLeaseRoute]) throws
    func record(_ event: String, index: Int) throws
    func finish() throws
}

/// One foreground lease, on one worker. No GUI/actor crosses its mutable state.
/// Kernel response + full-table readback precede active. Cleanup never targets a
/// borrowed/pre-existing route. All terminal paths are terminal; no hidden retries.
public final class ExternalLeaseTransaction {
    public private(set) var state: ExternalLeaseState = .idle
    public private(set) var failure: ExternalLeaseFailure?
    public private(set) var postObservation: ExternalPostObservation = .notObserved
    /// Category/count-only reason for an epoch rejection; never exposes route keys or DNS values.
    public private(set) var snapshotChangeSummary: String?
    public var ownedCount: Int { owned.count }
    private struct Owned { let index: Int; let token: UInt64; let route: ExternalLeaseRoute; var row: ExternalRoute? }
    private let plan: ExternalLeasePlan
    private let driver: any ExternalRouteOperating
    private let journal: any ExternalLeaseJournaling
    private let now: () -> TimeInterval
    private let uptime: () -> TimeInterval
    private let cancelled: () -> Bool
    private var owned: [Owned] = []
    private var deadline: TimeInterval?
    private var uncertainWrite = false
    private var journalStarted = false
    private var journalHealthy = true
    private var lastClock: TimeInterval

    public init(plan: ExternalLeasePlan, driver: any ExternalRouteOperating, journal: any ExternalLeaseJournaling,
                now: @escaping () -> TimeInterval, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                cancelled: @escaping () -> Bool = { false }) {
        self.plan = plan; self.driver = driver; self.journal = journal
        self.now = now; self.uptime = uptime; self.cancelled = cancelled; lastClock = plan.reviewedAt
    }
    public func start(consent: Bool) {
        guard state == .idle else { return }
        guard consent else { failure = .consentRequired; state = .closed; return }
        state = .applying
        do {
            try checkLive(review: true)
            guard driver.drainEvents() else { throw ExternalLeaseFailure.observationFailed }
            try checkSnapshot(try driver.observe())
            if plan.additions.isEmpty { state = .closed; return }
            do { try journal.begin(session: UUID(), routes: plan.additions); journalStarted = true }
            catch { journalHealthy = false; throw ExternalLeaseFailure.journalFailed }
            try checkLive()
            deadline = lastClock + plan.lifetime
            for (index, route) in plan.additions.enumerated() {
                try checkLive()
                guard driver.drainEvents() else { throw ExternalLeaseFailure.observationFailed }
                try checkSnapshot(try driver.observe())
                try note("willAdd", index)
                try checkLive()
                uncertainWrite = true // Until a matching, definitive kernel result exists.
                switch driver.add(route) {
                case .rejected: uncertainWrite = false; throw ExternalLeaseFailure.routeRejected
                case .uncertain: throw ExternalLeaseFailure.routeUncertain
                case .acknowledged(let token):
                    guard token != 0, !owned.contains(where: { $0.token == token }) else {
                        throw ExternalLeaseFailure.routeUncertain
                    }
                    owned.append(Owned(index: index, token: token, route: route))
                    uncertainWrite = false
                    try note("addAcknowledged", index)
                    guard driver.drainEvents(), driver.owns(token) else { throw ExternalLeaseFailure.readbackFailed }
                    let observation = try driver.observe()
                    let rows = observation.routes.filter { $0.destination == route.destination }
                    guard rows.count == 1, let row = rows.first, route.matches(row) else { throw ExternalLeaseFailure.readbackFailed }
                    owned[owned.count - 1].row = row
                    try checkSnapshot(observation)
                    try note("addReadback", index)
                }
            }
            try checkLive()
            state = .active
        } catch {
            failure = error as? ExternalLeaseFailure ?? .observationFailed
            stop()
        }
    }
    /// Host calls repeatedly even without traffic. No automatic lease renewal or
    /// reapplication after VPN reconnect, DHCP, sleep or conflicting route activity.
    public func poll() {
        guard state == .active else { return }
        do {
            try checkLive()
            guard driver.drainEvents(), owned.allSatisfy({ driver.owns($0.token) }) else {
                throw ExternalLeaseFailure.networkChanged
            }
            try checkSnapshot(try driver.observe())
        } catch {
            failure = error as? ExternalLeaseFailure ?? .observationFailed
            stop()
        }
    }
    public func stop() {
        guard state == .active || state == .applying || state == .idle else { return }
        state = .stopping
        var remaining: [Owned] = []
        for item in owned.reversed() {
            do {
                let observed = try driver.observe()
                try observed.checkFresh(now: uptime())
                let rows = observed.routes.filter { $0.destination == item.route.destination }
                // All-scope absence is sufficient to refrain from deletion, regardless
                // of which actor removed it. It does not recreate deletion authority.
                if rows.isEmpty { try note("alreadyAbsent", item.index); continue }
                guard rows.count == 1, let row = rows.first, item.route.matches(row),
                      item.row == nil || row == item.row, driver.drainEvents(), driver.owns(item.token) else {
                    remaining.append(item); continue
                }
                try note("willRemove", item.index)
                guard case .acknowledged = driver.remove(item.token) else { remaining.append(item); continue }
                let after = try driver.observe()
                try after.checkFresh(now: uptime())
                guard !after.routes.contains(where: { $0.destination == item.route.destination }) else {
                    remaining.append(item); continue
                }
                try note("removeReadback", item.index)
            } catch { remaining.append(item) }
        }
        owned = remaining.reversed()
        if let final = try? driver.observe() {
            // Snapshot comparison only, not DNS query behavior, packet egress or a
            // proof that another privileged process cannot modify routes afterwards.
            if (try? final.checkFresh(now: uptime())) != nil {
                postObservation = Self.same(plan.baseline, final) ? .unchanged : .changed
            }
        }
        guard owned.isEmpty, !uncertainWrite, journalHealthy else {
            state = .recoveryRequired; if failure == nil { failure = .recoveryRequired }; return
        }
        if journalStarted {
            do { try journal.finish() }
            catch { state = .recoveryRequired; failure = .journalFailed; return }
        }
        state = .closed
    }
    private func checkLive(review: Bool = false) throws {
        let time = now()
        guard time.isFinite, time >= lastClock else { throw ExternalLeaseFailure.expired }
        lastClock = time
        guard !cancelled() else { throw ExternalLeaseFailure.cancelled }
        if review, time - plan.reviewedAt >= 30 { throw ExternalLeaseFailure.expired }
        if let deadline, time >= deadline { throw ExternalLeaseFailure.expired }
    }
    private func note(_ event: String, _ index: Int) throws {
        do { try journal.record(event, index: index) }
        catch { journalHealthy = false; throw ExternalLeaseFailure.journalFailed }
    }
    private func checkSnapshot(_ observed: ExternalObservation) throws {
        try observed.checkFresh(now: uptime())
        var rows = observed.routes
        for item in owned {
            guard let row = item.row, rows.remove(row) != nil else { throw ExternalLeaseFailure.readbackFailed }
        }
        let interfacesChanged = Set(observed.interfaces) != Set(plan.baseline.interfaces)
        let physicalPathsChanged = Set(observed.physicalPaths) != Set(plan.baseline.physicalPaths)
        let dnsChanged = Set(observed.observedDNSServers) != Set(plan.baseline.observedDNSServers)
        let routesAdded = rows.subtracting(plan.baseline.routes).count
        let routesRemoved = plan.baseline.routes.subtracting(rows).count
        guard !interfacesChanged, !physicalPathsChanged, !dnsChanged,
              routesAdded == 0, routesRemoved == 0 else {
            snapshotChangeSummary = "interfaces_changed=\(interfacesChanged) physical_paths_changed=\(physicalPathsChanged) " +
                "dns_changed=\(dnsChanged) routes_added=\(routesAdded) routes_removed=\(routesRemoved)"
            throw ExternalLeaseFailure.networkChanged
        }
    }
    private static func same(_ a: ExternalObservation, _ b: ExternalObservation) -> Bool {
        Set(a.interfaces) == Set(b.interfaces) && Set(a.physicalPaths) == Set(b.physicalPaths) &&
        Set(a.observedDNSServers) == Set(b.observedDNSServers) && a.routes == b.routes
    }
}
