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
    public init(destination: IPv4CIDR, gateway: IPv4Address, interface: String) {
        self.destination = destination; self.gateway = gateway; self.interface = interface
    }
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
    public let controlledLifetime: Bool
    public static func prepare(rules: String, observation: ExternalObservation, uptime: TimeInterval,
                               clock: TimeInterval, lifetime: TimeInterval = 60, controlledLifetime: Bool = false) throws -> Self {
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
                    baseline: observation, reviewedAt: clock, lifetime: lifetime, controlledLifetime: controlledLifetime)
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
    /// Write-ahead replacement of the route list while a sustained session refreshes
    /// domain-derived routes; the marker always names the currently owned set.
    func amend(routes: [ExternalLeaseRoute]) throws
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
    /// At most two added/removed route shapes; no addresses, gateway values or interface IDs.
    public private(set) var snapshotRouteChangeShapes: String?
    /// Safe error category from a failed system observation; never includes raw system output.
    public private(set) var observationErrorCode: String?
    /// First cleanup failure: fixed stage/category only, never error descriptions or route values.
    public private(set) var cleanupDiagnostic: String?
    public var ownedCount: Int { owned.count }
    private struct Owned { var index: Int; let token: UInt64; let route: ExternalLeaseRoute; var row: ExternalRoute?; let refreshable: Bool }
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
    private let refreshableDestinations: Set<IPv4CIDR>

    public init(plan: ExternalLeasePlan, driver: any ExternalRouteOperating, journal: any ExternalLeaseJournaling,
                now: @escaping () -> TimeInterval, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                cancelled: @escaping () -> Bool = { false }, refreshableDestinations: Set<IPv4CIDR> = []) {
        self.plan = plan; self.driver = driver; self.journal = journal
        self.now = now; self.uptime = uptime; self.cancelled = cancelled; lastClock = plan.reviewedAt
        self.refreshableDestinations = refreshableDestinations
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
            deadline = plan.controlledLifetime ? nil : lastClock + plan.lifetime
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
                    owned.append(Owned(index: index, token: token, route: route, row: nil,
                                       refreshable: refreshableDestinations.contains(route.destination)))
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
            recordObservationError(error)
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
            recordObservationError(error)
            failure = error as? ExternalLeaseFailure ?? .observationFailed
            stop()
        }
    }
    /// Sustained sessions only: bounded in-place refresh of domain-derived routes.
    /// Removals/additions keep the same ownership, readback and write-ahead journal
    /// discipline as start/stop; any failure terminates the session like poll().
    /// Static rule destinations are never accepted here.
    public func refreshRoutes(add routes: [ExternalLeaseRoute], remove destinations: Set<IPv4CIDR>) {
        guard state == .active, plan.controlledLifetime, !routes.isEmpty || !destinations.isEmpty else { return }
        do {
            try checkLive()
            guard driver.drainEvents(), owned.allSatisfy({ driver.owns($0.token) }) else {
                throw ExternalLeaseFailure.networkChanged
            }
            try checkSnapshot(try driver.observe())
            var removedAny = false
            for destination in destinations.sorted() {
                try checkLive()
                guard let position = owned.firstIndex(where: { $0.route.destination == destination }) else { continue }
                let item = owned[position]
                guard item.refreshable else { throw ExternalLeaseFailure.invalidState }
                let observed = try driver.observe()
                try observed.checkFresh(now: uptime())
                let rows = observed.routes.filter { $0.destination == item.route.destination }
                if rows.isEmpty {
                    try note("alreadyAbsent", item.index)
                    owned.remove(at: position)
                    removedAny = true
                    continue
                }
                guard rows.count == 1, let row = rows.first, item.route.matches(row),
                      item.row == nil || row == item.row, driver.drainEvents(), driver.owns(item.token) else {
                    throw ExternalLeaseFailure.networkChanged
                }
                try note("willRemove", item.index)
                guard case .acknowledged = driver.remove(item.token) else { throw ExternalLeaseFailure.routeRejected }
                let after = try driver.observe()
                try after.checkFresh(now: uptime())
                guard !after.routes.contains(where: { $0.destination == item.route.destination }) else {
                    throw ExternalLeaseFailure.readbackFailed
                }
                try note("removeReadback", item.index)
                owned.remove(at: position)
                removedAny = true
            }
            // Write-ahead: the marker names the post-refresh owned set before any ADD.
            let additions = routes.filter { route in
                !owned.contains(where: { $0.route.destination == route.destination })
            }
            if (removedAny || !additions.isEmpty), journalStarted, !owned.isEmpty || !additions.isEmpty {
                let intended = owned.map(\.route) + additions
                guard (1...8).contains(intended.count) else { throw ExternalLeaseFailure.limit }
                try amend(intended)
                for position in owned.indices { owned[position].index = position }
            }
            for route in additions {
                guard owned.count < 8 else { break }
                try checkLive()
                guard driver.drainEvents() else { throw ExternalLeaseFailure.observationFailed }
                try checkSnapshot(try driver.observe())
                let index = owned.count // Position in the just-amended marker route list.
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
                    owned.append(Owned(index: index, token: token, route: route, row: nil, refreshable: true))
                    uncertainWrite = false
                    try note("addAcknowledged", index)
                    guard driver.drainEvents(), driver.owns(token) else { throw ExternalLeaseFailure.readbackFailed }
                    let observation = try driver.observe()
                    let rows = observation.routes.filter { $0.destination == route.destination }
                    guard rows.count == 1, let row = rows.first, route.matches(row) else {
                        throw ExternalLeaseFailure.readbackFailed
                    }
                    owned[owned.count - 1].row = row
                    try checkSnapshot(observation)
                    try note("addReadback", index)
                }
            }
            try checkLive()
        } catch {
            recordObservationError(error)
            failure = error as? ExternalLeaseFailure ?? .observationFailed
            stop()
        }
    }
    private func amend(_ routes: [ExternalLeaseRoute]) throws {
        do { try journal.amend(routes: routes) }
        catch { journalHealthy = false; throw ExternalLeaseFailure.journalFailed }
    }
    public func stop() {
        guard state == .active || state == .applying || state == .idle else { return }
        state = .stopping
        var remaining: [Owned] = []
        for item in owned.reversed() {
            var stage = "beforeDeleteObservation"
            do {
                let observed = try driver.observe()
                try observed.checkFresh(now: uptime())
                let rows = observed.routes.filter { $0.destination == item.route.destination }
                // All-scope absence is sufficient to refrain from deletion, regardless
                // of which actor removed it. It does not recreate deletion authority.
                if rows.isEmpty {
                    stage = "alreadyAbsentJournal"
                    try note("alreadyAbsent", item.index); continue
                }
                guard rows.count == 1, let row = rows.first, item.route.matches(row),
                      item.row == nil || row == item.row, driver.drainEvents(), driver.owns(item.token) else {
                    recordCleanupFailure("ownershipCheck", "unconfirmed")
                    remaining.append(item); continue
                }
                stage = "willRemoveJournal"
                try note("willRemove", item.index)
                guard case .acknowledged = driver.remove(item.token) else {
                    recordCleanupFailure("delete", "unconfirmed")
                    remaining.append(item); continue
                }
                stage = "afterDeleteObservation"
                let after = try driver.observe()
                try after.checkFresh(now: uptime())
                guard !after.routes.contains(where: { $0.destination == item.route.destination }) else {
                    recordCleanupFailure("afterDeleteReadback", "stillPresent")
                    remaining.append(item); continue
                }
                stage = "removeReadbackJournal"
                try note("removeReadback", item.index)
            } catch {
                let category = (error as? ExternalError)?.rawValue ??
                    (error as? ExternalLeaseFailure)?.rawValue ??
                    (error is ExternalRouteParseDiagnostic ? "routeParse" : "unknown")
                recordCleanupFailure(stage, category)
                remaining.append(item)
            }
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
            catch { recordCleanupFailure("finishJournal", "journalFailed"); state = .recoveryRequired; failure = .journalFailed; return }
        }
        state = .closed
    }
    private func recordCleanupFailure(_ stage: String, _ category: String) {
        if cleanupDiagnostic == nil { cleanupDiagnostic = "stage=\(stage) reason=\(category)" }
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
    private func recordObservationError(_ error: any Error) {
        if let observed = error as? ExternalError { observationErrorCode = observed.rawValue }
        else if error is ExternalRouteParseDiagnostic { observationErrorCode = "routeParse" }
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
        let epochRows = ExternalRouteEpoch.rows(rows)
        let epochBaseline = ExternalRouteEpoch.rows(plan.baseline.routes)
        guard !interfacesChanged, !physicalPathsChanged, !dnsChanged,
              epochRows == epochBaseline else {
            snapshotChangeSummary = "interfaces_changed=\(interfacesChanged) physical_paths_changed=\(physicalPathsChanged) " +
                "dns_changed=\(dnsChanged) routes_added=\(routesAdded) routes_removed=\(routesRemoved)"
            func shapes(_ values: Set<ExternalRoute>, limit: Int = 2) -> String {
                let rendered = values.map { row in
                    let kind = row.interface.hasPrefix("utun") ? "utun" : (row.interface.hasPrefix("en") ? "en" : "other")
                    let flags = row.flags.filter { "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".contains($0) }.prefix(24)
                    let gateway = (try? IPv4Address(row.gateway)) != nil ? "ipv4" : (row.gateway.hasPrefix("link#") ? "link" : "other")
                    return "p\(row.destination.prefixLength)/f=\(flags)/if=\(kind)/gw=\(gateway)/expired=\(row.isExpired)"
                }.sorted()
                let head = rendered.prefix(limit).joined(separator: ",")
                return rendered.count > limit ? head + ",+\(rendered.count - limit)" : head
            }
            func ignoringInterfaceReference(_ values: Set<ExternalRoute>) -> Set<ExternalRoute> {
                Set(values.map { row in
                    ExternalRoute(destination: row.destination, gateway: row.gateway, interface: row.interface,
                                  flags: row.flags.filter { $0 != "i" }, isExpired: row.isExpired)
                })
            }
            let ifrefOnly = ignoringInterfaceReference(rows) == ignoringInterfaceReference(plan.baseline.routes)
            snapshotRouteChangeShapes = "ifref_only=\(ifrefOnly);added=[\(shapes(rows.subtracting(plan.baseline.routes)))];removed=[\(shapes(plan.baseline.routes.subtracting(rows)))];epoch_added=[\(shapes(epochRows.subtracting(epochBaseline), limit: 4))];epoch_removed=[\(shapes(epochBaseline.subtracting(epochRows), limit: 4))]"
            throw ExternalLeaseFailure.networkChanged
        }
    }
    private static func same(_ a: ExternalObservation, _ b: ExternalObservation) -> Bool {
        Set(a.interfaces) == Set(b.interfaces) && Set(a.physicalPaths) == Set(b.physicalPaths) &&
        Set(a.observedDNSServers) == Set(b.observedDNSServers) && ExternalRouteEpoch.rows(a.routes) == ExternalRouteEpoch.rows(b.routes)
    }
}
