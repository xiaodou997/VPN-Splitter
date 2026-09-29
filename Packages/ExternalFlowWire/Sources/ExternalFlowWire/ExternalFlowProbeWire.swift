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

    public init() {}

    public var appIdentityObservable: Bool { total > 0 && withSourceSigningIdentifier > 0 }
    public var hostnameObservable: Bool { total > 0 && withRemoteHostname > 0 }

    public func validated() throws -> Self {
        guard format == Self.schema else { throw ExternalFlowProbeWireError.unsupportedVersion }
        let values = [total, tcp, udp, withSourceSigningIdentifier, withRemoteHostname, withRemoteEndpoint]
        guard values.allSatisfy({ $0 >= 0 && $0 <= 10_000_000 }),
              tcp <= total, udp <= total,
              withSourceSigningIdentifier <= total,
              withRemoteHostname <= total,
              withRemoteEndpoint <= total else {
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
    public let providerReport: ExternalFlowProbeReport?

    public init(id: UUID = UUID(), capturedAt: Date = Date(), configurationCount: Int,
                configurationEnabled: Bool, connectionStatus: String,
                providerReport: ExternalFlowProbeReport?) {
        self.id = id; self.capturedAt = capturedAt; self.configurationCount = configurationCount
        self.configurationEnabled = configurationEnabled; self.connectionStatus = connectionStatus
        self.providerReport = providerReport
    }

    public func validated(now: Date = Date()) throws -> Self {
        guard format == Self.schema, (0...8).contains(configurationCount),
              (1...32).contains(connectionStatus.utf8.count),
              connectionStatus.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) ||
                  (97...122).contains(byte) || byte == 45 || byte == 95
              }),
              capturedAt <= now.addingTimeInterval(5),
              capturedAt >= now.addingTimeInterval(-7 * 24 * 60 * 60) else {
            throw ExternalFlowProbeWireError.invalidSnapshot
        }
        if let providerReport { _ = try providerReport.validated() }
        return self
    }
}

public enum ExternalFlowProbeWireError: String, Error, Sendable {
    case unsupportedVersion, invalidReport, invalidSnapshot
}
