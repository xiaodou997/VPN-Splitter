// SPDX-License-Identifier: MIT
import Foundation

public enum ExternalControlError: String, Error, Sendable {
    case invalidRequest, invalidResponse, unavailable, authentication, busy, expired
    case staleSelection, trialDisabled, recoveryRequired, disconnected, timeout
}
public enum ExternalControlAction: String, Codable, Sendable { case hello, prepare, apply, status, stop, recoveryAudit, recoveryClear, quiesce }
public enum ExternalControlState: String, Codable, Sendable {
    case idle, prepared, applying, active, stopping, closed, recoveryRequired, refused
}
public struct ExternalControlRequest: Codable, Sendable {
    public var schema = 1
    public var id = UUID()
    public var instance: UUID?
    public var action: ExternalControlAction
    public var profile: UUID?
    public var revision: UUID?
    public var rules: String?
    public var ticket: UUID?
    public init(_ action: ExternalControlAction, instance: UUID? = nil,
                profile: UUID? = nil, revision: UUID? = nil, rules: String? = nil, ticket: UUID? = nil) {
        self.action = action; self.instance = instance; self.profile = profile
        self.revision = revision; self.rules = rules; self.ticket = ticket
    }
    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 16_384,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["schema", "id", "instance", "action", "profile", "revision", "rules", "ticket"]),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.schema == 1 else {
            throw ExternalControlError.invalidRequest
        }
        let noSelection = value.profile == nil && value.revision == nil && value.rules == nil
        switch value.action {
        case .hello:
            guard value.instance == nil, noSelection, value.ticket == nil else { throw ExternalControlError.invalidRequest }
        case .prepare:
            guard value.instance != nil, value.profile != nil, value.revision != nil, value.ticket == nil,
                  let rules = value.rules, !rules.isEmpty, rules.utf8.count <= 4096 else { throw ExternalControlError.invalidRequest }
            let lines = rules.split(separator: "\n", omittingEmptySubsequences: false)
            guard (1...64).contains(lines.count), lines.allSatisfy({ line in
                (7...18).contains(line.utf8.count) && line.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 || $0 == 47 }
            }) else { throw ExternalControlError.invalidRequest }
            // Canonical CIDR semantics and the actual topology are checked by the native planner.
        case .apply:
            guard value.instance != nil, value.profile != nil, value.revision != nil,
                  value.rules == nil, value.ticket != nil else { throw ExternalControlError.invalidRequest }
        case .status, .stop, .recoveryAudit, .recoveryClear, .quiesce:
            guard value.instance != nil, noSelection, value.ticket == nil else { throw ExternalControlError.invalidRequest }
        }
        return value
    }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
}
public struct ExternalControlProposal: Codable, Equatable, Sendable {
    public let destination: String
    public let gateway: String
    public let interface: String
    public let disposition: String
    public init(destination: String, gateway: String, interface: String, disposition: String) {
        self.destination = destination; self.gateway = gateway; self.interface = interface; self.disposition = disposition
    }
}
public struct ExternalControlResult: Codable, Sendable {
    public var state: ExternalControlState
    public var code: String
    public var owned: Int
    public var comparison: String
    public var diagnostic: String
    public var recoveryCandidates: Int
    public var recoveryPresent: Int
    public init(_ state: ExternalControlState, code: String = "none", owned: Int = 0,
                comparison: String = "notObserved", diagnostic: String = "",
                recoveryCandidates: Int = 0, recoveryPresent: Int = 0) {
        self.state = state; self.code = code; self.owned = owned
        self.comparison = comparison; self.diagnostic = diagnostic
        self.recoveryCandidates = recoveryCandidates; self.recoveryPresent = recoveryPresent
    }
}
public struct ExternalControlReply: Codable, Sendable {
    public var schema = 1
    public let requestID: UUID
    public let instance: UUID
    public let canApply: Bool
    public var ticket: UUID?
    public var proposals: [ExternalControlProposal] = []
    public var result: ExternalControlResult
    public init(requestID: UUID, instance: UUID, canApply: Bool, result: ExternalControlResult) {
        self.requestID = requestID; self.instance = instance; self.canApply = canApply; self.result = result
    }
    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decode(_ data: Data, request: ExternalControlRequest) throws -> Self {
        guard data.count <= 16_384, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.schema == 1, value.requestID == request.id,
              request.instance == nil || value.instance == request.instance,
              value.proposals.count <= 8, (0...8).contains(value.result.owned),
              (0...8).contains(value.result.recoveryCandidates), (0...8).contains(value.result.recoveryPresent),
              value.result.recoveryPresent <= value.result.recoveryCandidates,
              value.result.code.utf8.count <= 64, value.result.diagnostic.utf8.count <= 1024,
              value.proposals.allSatisfy({ $0.destination.utf8.count <= 18 && $0.gateway.utf8.count <= 15 &&
                  $0.interface.utf8.count <= 32 && $0.disposition.utf8.count <= 40 }) else {
            throw ExternalControlError.invalidResponse
        }
        return value
    }
}

/// Immutable one-shot revocation shared with a synchronous native transaction.
/// No reset exists; a new connection requires a different cancellation object.
public final class ExternalControlCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    public init() {}
    public func cancel() { lock.lock(); revoked = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return revoked }
}
/// Created by the authenticated native listener, never decoded from IPC.
public struct ExternalControlPeer: Sendable {
    public let id: UUID
    public let uid: UInt32
    public let cancellation: ExternalControlCancellation
    public init(id: UUID = UUID(), uid: UInt32, cancellation: ExternalControlCancellation = .init()) {
        self.id = id; self.uid = uid; self.cancellation = cancellation
    }
}
