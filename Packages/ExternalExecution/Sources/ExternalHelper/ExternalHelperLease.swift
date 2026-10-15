// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import OSLog
import ExternalControl
import ExternalCore
import ExternalExecution
import PolicyCore
import CExternalRoute

/// Off-actor handoff for one bounded DNS re-resolution. The service actor never
/// blocks on getaddrinfo; a completed result is applied by a later poll().
private final class ExternalResolutionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ExternalDomainExpansion??
    func store(_ expansion: ExternalDomainExpansion?) { lock.lock(); value = .some(expansion); lock.unlock() }
    /// nil = nothing completed yet; .some(nil) = failed re-resolution (keep current set).
    func take() -> ExternalDomainExpansion?? {
        lock.lock(); defer { lock.unlock() }
        let current = value; value = nil; return current
    }
}

/// The service actor owns this object and the existing synchronous transaction.
/// No saved gateway, caller-provided route plan or recovered receipt is accepted.
/// DOMAIN/DOMAIN-SUFFIX rules are resolved here (root Helper, system resolver)
/// and expanded to /32 lines before the pure-logic plan sees them. The policy
/// compiler may coalesce adjacent expanded /32s into one wider CIDR (identical
/// routing, fewer routes); origin attribution and refresh diffing account for it.
final class ExternalHelperLease: ExternalControlledLease {
    private static let logger = Logger(subsystem: "io.github.xiaodou997.VPNSplitter.ExternalHelper", category: "lease")
    let proposals: [ExternalControlProposal]
    private let plan: ExternalLeasePlan
    private let cancellation: ExternalControlCancellation
    private let domainRules: [ExternalDomainRule]
    private let resolutionBox = ExternalResolutionBox()
    private var domainRefresh: ExternalDomainRefresh?
    /// Actual plan destinations derived from domain expansion (post-coalescing).
    private var domainOwned: Set<IPv4CIDR> = []
    private var transaction: ExternalLeaseTransaction?
    private var driver: NativeExternalRouteDriver?
    private var journal: ExternalLeaseFileJournal?
    private(set) var result = ExternalControlResult(.prepared)
    init(rules: String, cancellation: ExternalControlCancellation) throws {
        self.cancellation = cancellation
        let observation = try ExternalSystemSnapshotReader().capture()
        #if EXTERNAL_HELPER_SUSTAINED
        let controlled = true
        #else
        let controlled = false
        #endif
        let parsed = try ExternalDomainRuleSet.parse(rules)
        var text = rules
        var expansion: ExternalDomainExpansion?
        var diagnostic = ""
        if !parsed.domains.isEmpty {
            let value: ExternalDomainExpansion
            do {
                value = try ExternalDomainResolver.expand(domains: parsed.domains, staticLines: parsed.staticLines,
                    budget: 8 - parsed.staticLines.count, resolve: ExternalSystemResolver.resolveIPv4)
            } catch let error as ExternalError where error == .domainResolutionFailed {
                throw ExternalControlError.domainResolutionFailed
            }
            expansion = value
            text = (parsed.staticLines + value.lines).joined(separator: "\n")
            // Category/count only; resolved names never enter the result channel or logs.
            diagnostic = "domain_rules=\(parsed.domains.count) domain_routes=\(value.lines.count) truncated=\(value.truncated ? "yes" : "no")"
        }
        domainRules = parsed.domains
        plan = try ExternalLeasePlan.prepare(rules: text, observation: observation,
                    uptime: ProcessInfo.processInfo.systemUptime, clock: er_continuous_seconds(), controlledLifetime: controlled)
        proposals = plan.preview.proposals.map { proposal in
            ExternalControlProposal(destination: proposal.destination.description,
                                    gateway: proposal.gateway.description,
                                    interface: proposal.interface, disposition: proposal.disposition.rawValue,
                                    sourceDomain: Self.origin(of: proposal.destination, in: expansion))
        }
        if let expansion {
            // Only destinations fully covered by expansion results are domain-owned.
            // A coalesced route that also covers a static rule's IP is treated as
            // static: refresh never removes or recreates it.
            let derived = Set(plan.additions.map(\.destination).filter { destination in
                let addresses = Self.addresses(of: destination)
                return !addresses.isEmpty && addresses.isSubset(of: expansion.destinations)
            })
            domainOwned = derived
            #if EXTERNAL_HELPER_SUSTAINED
            // Only sustained sessions refresh; the 60-second trial never rewrites routes.
            if !derived.isEmpty {
                domainRefresh = ExternalDomainRefresh(applied: expansion.destinations,
                                                      startedAt: er_continuous_seconds())
            }
            #endif
        }
        if !diagnostic.isEmpty { result = .init(.prepared, diagnostic: diagnostic) }
    }
    /// Origin annotation for one proposal: the domains whose expanded /32s the
    /// (possibly coalesced) destination covers. Counts only when several merged.
    private static func origin(of destination: IPv4CIDR, in expansion: ExternalDomainExpansion?) -> String? {
        guard let expansion else { return nil }
        let origins = expansion.destinations.filter { destination.contains($0.networkAddress) }
            .compactMap { expansion.sources[$0.description] }
        let unique = Array(Set(origins)).sorted()
        guard let first = unique.first else { return nil }
        return unique.count == 1 ? first : "\(first) 等 \(unique.count) 个域名"
    }
    func start() {
        guard transaction == nil, result.state == .prepared, !cancellation.isCancelled else { return }
        do {
            // Same fixed root-owned lock/intent journal as the foreground executor.
            // An unresolved old marker blocks this path too; it is never auto-cleared.
            let journal = try ExternalLeaseFileJournal.foregroundHost()
            let driver = try NativeExternalRouteDriver(tunnel: plan.preview.topology.tunnelInterface)
            self.journal = journal; self.driver = driver
            let flag = cancellation
            let transaction = ExternalLeaseTransaction(plan: plan, driver: driver, journal: journal,
                now: { er_continuous_seconds() }, cancelled: { flag.isCancelled },
                refreshableDestinations: domainOwned)
            self.transaction = transaction
            transaction.start(consent: true) // Only reached after authenticated, one-shot apply.
            refresh()
        } catch {
            result = .init(.recoveryRequired, code: (error as? ExternalLeaseFailure)?.rawValue ?? "observationFailed")
            releaseResources()
        }
    }
    func poll() {
        transaction?.poll(); refresh()
        guard transaction != nil, result.state == .active, var controller = domainRefresh else { return }
        let now = er_continuous_seconds()
        if let completed = resolutionBox.take() {
            if let expansion = completed {
                let diff = controller.finish(at: now, resolved: expansion.destinations)
                domainRefresh = controller
                if let diff, !diff.isEmpty { applyRefresh(diff, resolved: expansion.destinations) }
            } else {
                // Failed re-resolution: keep the current route set, retry next interval.
                _ = controller.finish(at: now, resolved: nil)
                domainRefresh = controller
            }
            return
        }
        if controller.begin(at: now) {
            domainRefresh = controller
            let rules = domainRules, box = resolutionBox
            Task.detached(priority: .utility) {
                box.store(try? ExternalDomainResolver.expand(domains: rules, budget: ExternalDomainResolver.totalLimit,
                                                             resolve: ExternalSystemResolver.resolveIPv4))
            }
        }
    }
    /// Applies one re-resolution outcome. `diff` is in resolved-/32 space; removals
    /// map to the actual owned destinations (the compiler may have coalesced them).
    /// An owned route disappears only when none of its addresses resolve any more.
    private func applyRefresh(_ diff: ExternalDomainDiff, resolved: Set<IPv4CIDR>) {
        guard let transaction else { return }
        let removing = domainOwned.filter { destination in
            !Self.addresses(of: destination).contains(where: { resolved.contains($0) })
        }
        // Keep the whole owned set within the fixed execution budget.
        let capacity = max(0, 8 - result.owned + removing.count)
        let additions = Array(diff.add.prefix(capacity))
        let physical = plan.preview.topology.physical
        let routes = additions.map {
            ExternalLeaseRoute(destination: $0, gateway: physical.gateway, interface: physical.interface)
        }
        transaction.refreshRoutes(add: routes, remove: removing)
        domainOwned.subtract(removing)
        domainOwned.formUnion(additions)
        refresh()
    }
    /// Expansion destinations are always /32; owned destinations stay within /24…/32.
    private static func addresses(of cidr: IPv4CIDR) -> Set<IPv4CIDR> {
        guard cidr.prefixLength >= 24 else { return [] }
        return Set((0..<cidr.addressCount).compactMap { offset in
            try? IPv4CIDR(address: IPv4Address(rawValue: cidr.networkAddress.rawValue + UInt32(offset)), prefixLength: 32)
        })
    }
    func stop() {
        cancellation.cancel()
        if let transaction { transaction.stop(); refresh() }
        else if result.state == .prepared { result = .init(.closed, code: "notApplied") }
    }
    private func refresh() {
        guard let transaction else { return }
        var diagnostic = driver?.diagnosticSummary ?? ""
        if let change = transaction.snapshotChangeSummary { diagnostic += "; snapshot_change=" + change }
        if let shapes = transaction.snapshotRouteChangeShapes { diagnostic += "; route_shapes=" + shapes }
        if let error = transaction.observationErrorCode { diagnostic += "; observation_error=" + error }
        if let cleanup = transaction.cleanupDiagnostic { diagnostic += "; cleanup=" + cleanup }
        result = .init(ExternalControlState(rawValue: transaction.state.rawValue) ?? .recoveryRequired,
                       code: transaction.failure?.rawValue ?? "none", owned: transaction.ownedCount,
                       comparison: transaction.postObservation.rawValue, diagnostic: diagnostic)
        if result.state == .closed || result.state == .recoveryRequired {
            // The GUI may already be disconnected at sleep. Keep only fixed categories
            // and counts in the OS log; no rules, destinations, interfaces or credentials.
            let state = result.state.rawValue
            let code = transaction.failure?.rawValue ?? "none"
            let owned = transaction.ownedCount
            let comparison = transaction.postObservation.rawValue
            let cleanup = transaction.cleanupDiagnostic ?? "none"
            Self.logger.notice("lease_terminal state=\(state, privacy: .public) code=\(code, privacy: .public) owned=\(owned) comparison=\(comparison, privacy: .public) cleanup=\(cleanup, privacy: .public)")
            releaseResources()
        }
    }
    private func releaseResources() { transaction = nil; driver = nil; journal = nil; domainRefresh = nil; domainOwned = [] }
}
#endif
