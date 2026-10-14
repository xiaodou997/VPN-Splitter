// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import OSLog
import ExternalControl
import ExternalCore
import ExternalExecution
import CExternalRoute

/// The service actor owns this object and the existing synchronous transaction.
/// No saved gateway, caller-provided route plan or recovered receipt is accepted.
final class ExternalHelperLease: ExternalControlledLease {
    private static let logger = Logger(subsystem: "io.github.xiaodou997.VPNSplitter.ExternalHelper", category: "lease")
    let proposals: [ExternalControlProposal]
    private let plan: ExternalLeasePlan
    private let cancellation: ExternalControlCancellation
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
        plan = try ExternalLeasePlan.prepare(rules: rules, observation: observation,
                    uptime: ProcessInfo.processInfo.systemUptime, clock: er_continuous_seconds(), controlledLifetime: controlled)
        proposals = plan.preview.proposals.map {
            ExternalControlProposal(destination: $0.destination.description, gateway: $0.gateway.description,
                                    interface: $0.interface, disposition: $0.disposition.rawValue)
        }
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
                now: { er_continuous_seconds() }, cancelled: { flag.isCancelled })
            self.transaction = transaction
            transaction.start(consent: true) // Only reached after authenticated, one-shot apply.
            refresh()
        } catch {
            result = .init(.recoveryRequired, code: (error as? ExternalLeaseFailure)?.rawValue ?? "observationFailed")
            releaseResources()
        }
    }
    func poll() { transaction?.poll(); refresh() }
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
    private func releaseResources() { transaction = nil; driver = nil; journal = nil }
}
#endif
