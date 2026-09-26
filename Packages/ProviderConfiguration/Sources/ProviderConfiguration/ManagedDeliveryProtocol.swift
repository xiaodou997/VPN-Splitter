// SPDX-License-Identifier: MIT
import Foundation

/// Identifiers correlate this ONE authenticated connection. They are not credentials,
/// code-signing evidence, a caller-selected authorization, or tunnel ownership proof.
struct ManagedDeliveryChallenge: Equatable, Sendable {
    let nonce: UUID
    let instance: UUID
    let ownerUID: UInt32
    var fields: [String: String] {
        ["nonce": nonce.uuidString, "instance": instance.uuidString, "owner": String(ownerUID)]
    }
    init(nonce: UUID = UUID(), instance: UUID, ownerUID: UInt32) {
        self.nonce = nonce; self.instance = instance; self.ownerUID = ownerUID
    }
    init(fields: [String: String]) throws {
        guard Set(fields.keys) == ["nonce", "instance", "owner"],
              let nonce = ManagedWire.uuid(fields["nonce"]), let instance = ManagedWire.uuid(fields["instance"]),
              let text = fields["owner"], text.utf8.count <= 10,
              let owner = UInt32(text), owner > 0, String(owner) == text else {
            throw ManagedTransferError.invalidMessage
        }
        self.init(nonce: nonce, instance: instance, ownerUID: owner)
    }
    func encoded() throws -> Data { try ManagedWire.encode(fields, maximum: 1024) }
    init(data: Data) throws {
        let fields = try ManagedWire.decode(data, maximum: 1024)
        guard let strings = fields as? [String: String] else { throw ManagedTransferError.invalidMessage }
        try self.init(fields: strings)
    }
}

enum ManagedWire {
    static func uuid(_ text: String?) -> UUID? {
        guard let text, text.utf8.count == 36, let uuid = UUID(uuidString: text), uuid.uuidString == text else { return nil }
        return uuid
    }
    static func encode(_ fields: [String: Any], maximum: Int) throws -> Data {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
            guard data.count <= maximum else { throw ManagedTransferError.invalidMessage }
            return data
        } catch { throw ManagedTransferError.invalidMessage }
    }
    static func decode(_ data: Data, maximum: Int) throws -> [String: Any] {
        do {
            guard !data.isEmpty, data.count <= maximum,
                  data.prefix(8) == Data("bplist00".utf8),
                  let fields = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                throw ManagedTransferError.invalidMessage
            }
            return fields
        } catch { throw ManagedTransferError.invalidMessage }
    }
}

/// Transient XPC-only payload; never write this to disk/NE options/provider messages.
/// No Codable conformance, no reflection of the secret data. Keychain keeps its own
/// distinct format. The extension must still run configuration/policy validation.
struct ManagedDeliveryEnvelope: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let maximumBytes = 145_000
    let challenge: ManagedDeliveryChallenge
    let request: ManagedStartRequest
    let reference: Data
    let material: ManagedCredentialMaterial
    init(challenge: ManagedDeliveryChallenge, grant: ManagedDeliveryAuthorization, material: ManagedCredentialMaterial) throws {
        guard challenge.ownerUID == grant.handle.ownerUID else { throw ManagedTransferError.invalidIdentity }
        self.challenge = challenge; request = grant.request
        reference = grant.handle.persistentReference; self.material = material
    }
    func encodedForAuthenticatedXPC() throws -> Data {
        try material.withContents { configuration, policy in
            try ManagedWire.encode([
                "schema": "managed-delivery-v1", "challenge": challenge.fields,
                "request": request.propertyList, "reference": reference,
                "configuration": configuration, "policy": policy
            ], maximum: Self.maximumBytes)
        }
    }
    init(authenticatedXPCData data: Data) throws {
        do {
            let fields = try ManagedWire.decode(data, maximum: Self.maximumBytes)
            guard Set(fields.keys) == ["schema", "challenge", "request", "reference", "configuration", "policy"],
                  fields["schema"] as? String == "managed-delivery-v1",
                  let challenge = fields["challenge"] as? [String: String],
                  let request = fields["request"] as? [String: String],
                  let reference = fields["reference"] as? Data, !reference.isEmpty,
                  reference.count <= ManagedLaunchContract.maximumReferenceBytes,
                  let configuration = fields["configuration"] as? Data, let policy = fields["policy"] as? Data else {
                throw ManagedTransferError.invalidMessage
            }
            self.challenge = try ManagedDeliveryChallenge(fields: challenge)
            self.request = try ManagedStartRequest(propertyList: request)
            self.reference = reference.withUnsafeBytes { Data($0) }
            material = try ManagedCredentialMaterial(configuration: configuration, policyArchive: policy)
        } catch { throw ManagedTransferError.invalidMessage }
    }
    var description: String { "ManagedDeliveryEnvelope(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// Returned only by the native runtime after a matching authenticated staged record
/// is consumed at the real Provider callback. Not proof of semantic config validity.
public struct ManagedReceivedConfiguration: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let request: ManagedStartRequest
    public let ownerUID: UInt32
    public let material: ManagedCredentialMaterial
    init(_ envelope: ManagedDeliveryEnvelope) {
        request = envelope.request; ownerUID = envelope.challenge.ownerUID; material = envelope.material
    }
    public var description: String { "ManagedReceivedConfiguration(<redacted>; not-runtime-validated)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// Pure state behind the native listener. This is internal: open() is NOT a public
/// caller-authentication API. Only the native XPC accept path supplies kernel UID.
@MainActor
final class ManagedDeliveryBroker {
    static let lifetime: TimeInterval = 15
    private struct Channel {
        let challenge: ManagedDeliveryChallenge
        let deadline: TimeInterval
        let isLive: @Sendable () -> Bool
        var envelope: ManagedDeliveryEnvelope?
        var spent = false
    }
    private let instance = UUID()
    private let now: @MainActor () -> TimeInterval
    private var channels: [UUID: Channel] = [:]
    private var attempts: Set<UUID> = []
    private var staged: UUID?
    init(now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }

    func open(connection: UUID, kernelUID: UInt32, isLive: @escaping @Sendable () -> Bool = { true }) throws -> ManagedDeliveryChallenge {
        purge()
        guard kernelUID > 0 else { throw ManagedTransferError.invalidIdentity }
        guard channels[connection] == nil else { throw ManagedTransferError.replay }
        guard channels.count < 8, attempts.count < 256 else { throw ManagedTransferError.capacity }
        let challenge = ManagedDeliveryChallenge(instance: instance, ownerUID: kernelUID)
        channels[connection] = Channel(challenge: challenge, deadline: now() + Self.lifetime, isLive: isLive)
        return challenge
    }
    func stage(_ data: Data, connection: UUID) throws {
        purge()
        guard var channel = channels[connection] else { throw ManagedTransferError.expired }
        guard !channel.spent else { throw ManagedTransferError.replay }
        // Malformed input consumes this connection's chance; never allow a retry.
        channel.spent = true; channels[connection] = channel
        let envelope: ManagedDeliveryEnvelope
        do { envelope = try ManagedDeliveryEnvelope(authenticatedXPCData: data) }
        catch { close(connection); throw ManagedTransferError.invalidMessage }
        guard envelope.challenge == channel.challenge else { close(connection); throw ManagedTransferError.invalidIdentity }
        guard staged == nil else { close(connection); throw ManagedTransferError.busy }
        guard !attempts.contains(envelope.request.attemptID), attempts.count < 256 else {
            close(connection); throw ManagedTransferError.replay
        }
        attempts.insert(envelope.request.attemptID)
        channel.envelope = envelope; channels[connection] = channel; staged = connection
    }
    func consume(_ launch: CheckedManagedLaunch, ownerUID: UInt32) throws -> ManagedReceivedConfiguration {
        purge()
        guard let id = staged, let channel = channels[id], let envelope = channel.envelope else {
            throw ManagedTransferError.deliveryMissing
        }
        // Consume even on mismatched Provider metadata; no stale payload survives.
        close(id)
        guard envelope.challenge.ownerUID == ownerUID, envelope.request == launch.request, envelope.reference == launch.credentialReference else {
            throw ManagedTransferError.selectionChanged
        }
        return ManagedReceivedConfiguration(envelope)
    }
    func close(_ connection: UUID) {
        channels.removeValue(forKey: connection)
        if staged == connection { staged = nil }
    }
    func discard() { channels.removeAll(); staged = nil } // Tombstones intentionally survive.
    func purge() {
        let expired = channels.filter { $0.value.deadline <= now() || !$0.value.isLive() }.map(\.key)
        for id in expired { close(id) }
    }
    var pendingCount: Int { channels.count }
}

/// Requirements come from signed bundle build configuration, never IPC arguments.
struct ManagedPeerRequirement: Sendable {
    let appID: String
    let providerID: String
    let teamID: String
    init(appID: String, providerID: String, teamID: String) throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-".utf8)
        guard [appID, providerID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 && $0.utf8.allSatisfy(allowed.contains) }),
              providerID == appID + ".PacketTunnel", teamID.utf8.count == 10,
              teamID.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else {
            throw ManagedTransferError.invalidIdentity
        }
        self.appID = appID; self.providerID = providerID; self.teamID = teamID
    }
    func requirement(provider: Bool) -> String {
        // Quote even a numeric-leading Team ID. Disallow debug/injection exceptions.
        "anchor apple generic and identifier \"\(provider ? providerID : appID)\" and certificate leaf[subject.OU] = \"\(teamID)\"" +
        " and not entitlement[\"com.apple.security.get-task-allow\"] = true" +
        " and not entitlement[\"com.apple.security.cs.disable-library-validation\"] = true" +
        " and not entitlement[\"com.apple.security.cs.allow-dyld-environment-variables\"] = true"
    }
}
