// SPDX-License-Identifier: MIT
import Foundation

public struct ExternalFlowProbeReport: Codable, Equatable, Sendable {
    public static let schema = "external-flow-probe-v1"
    public var format = Self.schema
    public var total = 0
    public var tcp = 0
    public var udp = 0
    public var withSourceSigningIdentifier = 0
    public var withRemoteHostname = 0
    public var withRemoteEndpoint = 0
    /// Compiled DIRECT rule count at startProxy (0 = absent or rejected).
    public var rulesLoaded = 0
    /// startProxy calls whose rules blob failed decode/compile.
    public var rulesRejected = 0
    /// DIRECT-matched flows handed back because no unique physical interface.
    public var relayRefusedInterface = 0
    /// DIRECT-matched flows closed because the concurrency limit was reached.
    public var relayRefusedLimit = 0
    public var relayStarted = 0
    public var relayActive = 0
    public var relayCompleted = 0
    public var relayFailed = 0
    public var relayCancelled = 0
    /// Runtime pause switch (ADR-EX-INT-08): while true, DIRECT-matched flows
    /// are closed instead of relayed.
    public var relayPaused = false
    /// DIRECT-matched flows closed because the relay was paused.
    public var relayRefusedPaused = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case format, total, tcp, udp, withSourceSigningIdentifier, withRemoteHostname, withRemoteEndpoint
        case rulesLoaded, rulesRejected, relayRefusedInterface, relayRefusedLimit
        case relayStarted, relayActive, relayCompleted, relayFailed, relayCancelled
        case relayPaused, relayRefusedPaused
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        total = try container.decode(Int.self, forKey: .total)
        tcp = try container.decode(Int.self, forKey: .tcp)
        udp = try container.decode(Int.self, forKey: .udp)
        withSourceSigningIdentifier = try container.decode(Int.self, forKey: .withSourceSigningIdentifier)
        withRemoteHostname = try container.decode(Int.self, forKey: .withRemoteHostname)
        withRemoteEndpoint = try container.decode(Int.self, forKey: .withRemoteEndpoint)
        rulesLoaded = try container.decodeIfPresent(Int.self, forKey: .rulesLoaded) ?? 0
        rulesRejected = try container.decodeIfPresent(Int.self, forKey: .rulesRejected) ?? 0
        relayRefusedInterface = try container.decodeIfPresent(Int.self, forKey: .relayRefusedInterface) ?? 0
        relayRefusedLimit = try container.decodeIfPresent(Int.self, forKey: .relayRefusedLimit) ?? 0
        relayStarted = try container.decodeIfPresent(Int.self, forKey: .relayStarted) ?? 0
        relayActive = try container.decodeIfPresent(Int.self, forKey: .relayActive) ?? 0
        relayCompleted = try container.decodeIfPresent(Int.self, forKey: .relayCompleted) ?? 0
        relayFailed = try container.decodeIfPresent(Int.self, forKey: .relayFailed) ?? 0
        relayCancelled = try container.decodeIfPresent(Int.self, forKey: .relayCancelled) ?? 0
        relayPaused = try container.decodeIfPresent(Bool.self, forKey: .relayPaused) ?? false
        relayRefusedPaused = try container.decodeIfPresent(Int.self, forKey: .relayRefusedPaused) ?? 0
    }

    public var appIdentityObservable: Bool { total > 0 && withSourceSigningIdentifier > 0 }
    public var hostnameObservable: Bool { total > 0 && withRemoteHostname > 0 }

    public func validated() throws -> Self {
        guard format == Self.schema else { throw ExternalFlowProbeWireError.unsupportedVersion }
        let values = [total, tcp, udp, withSourceSigningIdentifier, withRemoteHostname, withRemoteEndpoint,
                      rulesRejected, relayRefusedInterface, relayRefusedLimit, relayRefusedPaused,
                      relayStarted, relayActive, relayCompleted, relayFailed, relayCancelled]
        guard values.allSatisfy({ $0 >= 0 && $0 <= 10_000_000 }),
              (0...ExternalFlowRulesWire.maxRules).contains(rulesLoaded),
              tcp <= total, udp <= total,
              withSourceSigningIdentifier <= total,
              withRemoteHostname <= total,
              withRemoteEndpoint <= total,
              relayRefusedInterface <= total,
              relayRefusedLimit <= total,
              relayRefusedPaused <= total,
              relayActive <= relayStarted,
              relayCompleted + relayFailed + relayCancelled <= relayStarted else {
            throw ExternalFlowProbeWireError.invalidReport
        }
        return self
    }
}

public struct ExternalFlowProbeSnapshot: Codable, Equatable, Sendable {
    public static let schema = "external-flow-probe-snapshot-v1"
    public var format = Self.schema
    public let id: UUID
    public let capturedAt: Date
    public let configurationCount: Int
    public let configurationEnabled: Bool
    public let connectionStatus: String
    public let providerMessageStatus: String?
    public let providerReport: ExternalFlowProbeReport?

    public init(id: UUID = UUID(), capturedAt: Date = Date(), configurationCount: Int,
                configurationEnabled: Bool, connectionStatus: String,
                providerMessageStatus: String? = nil,
                providerReport: ExternalFlowProbeReport?) {
        self.id = id; self.capturedAt = capturedAt; self.configurationCount = configurationCount
        self.configurationEnabled = configurationEnabled; self.connectionStatus = connectionStatus
        self.providerMessageStatus = providerMessageStatus; self.providerReport = providerReport
    }

    public func validated(now: Date = Date()) throws -> Self {
        guard format == Self.schema, (0...8).contains(configurationCount),
              (1...32).contains(connectionStatus.utf8.count),
              connectionStatus.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) ||
                  (97...122).contains(byte) || byte == 45 || byte == 95
              }),
              capturedAt <= now.addingTimeInterval(5),
              capturedAt >= now.addingTimeInterval(-7 * 24 * 60 * 60),
              providerMessageStatus == nil || Self.providerStatuses.contains(providerMessageStatus!) else {
            throw ExternalFlowProbeWireError.invalidSnapshot
        }
        if let providerReport {
            _ = try providerReport.validated()
            guard providerMessageStatus == "pass" else { throw ExternalFlowProbeWireError.invalidSnapshot }
        } else if providerMessageStatus == "pass" {
            throw ExternalFlowProbeWireError.invalidSnapshot
        }
        return self
    }

    private static let providerStatuses: Set<String> = [
        "pass", "not_connected", "unsupported_session", "no_response",
        "send_failed", "invalid_response"
    ]
}

public enum ExternalFlowProbeWireError: String, Error, Sendable {
    case unsupportedVersion, invalidReport, invalidSnapshot
}
