// SPDX-License-Identifier: MIT
import Foundation
import ExternalCore

public struct ExternalRecoveryReport: Equatable, Sendable {
    public let candidates: Int
    public let presentOrAmbiguous: Int
    public let markerCleared: Bool
    public init(candidates: Int, presentOrAmbiguous: Int, markerCleared: Bool) {
        self.candidates = candidates; self.presentOrAmbiguous = presentOrAmbiguous
        self.markerCleared = markerCleared
    }
}

/// Root-local recovery inspection. It never reconstructs native route ownership,
/// never issues RTM_DELETE, and clears only this tool's marker after a fresh
/// all-scope absence check performed by the existing journal.
public enum ExternalRecoveryHost {
    public static func audit(clearMarkerIfAbsent: Bool = false) throws -> ExternalRecoveryReport {
        let journal = try ExternalLeaseFileJournal.foregroundHost()
        let candidates = try journal.auditCandidates()
        let observation = try ExternalSystemSnapshotReader().capture()
        try observation.checkFresh(now: ProcessInfo.processInfo.systemUptime)
        let present = candidates.filter { item in
            observation.routes.contains { row in
                row.destination.prefixLength >= item.destination.prefixLength &&
                    item.destination.contains(row.destination.networkAddress)
            }
        }
        guard clearMarkerIfAbsent else {
            return .init(candidates: candidates.count, presentOrAmbiguous: present.count, markerCleared: false)
        }
        guard present.isEmpty else {
            return .init(candidates: candidates.count, presentOrAmbiguous: present.count, markerCleared: false)
        }
        try journal.clearAuditedAbsence(routes: candidates, observation: observation,
                                        uptime: ProcessInfo.processInfo.systemUptime)
        return .init(candidates: candidates.count, presentOrAmbiguous: 0, markerCleared: true)
    }
}
