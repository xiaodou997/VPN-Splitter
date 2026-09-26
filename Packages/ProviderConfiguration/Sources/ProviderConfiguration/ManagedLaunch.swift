// SPDX-License-Identifier: MIT
import Foundation

/// Public metadata only. These identifiers correlate requests; they do NOT prove
/// caller identity, Keychain access, record ownership, freshness, or tunnel ownership.
public struct ManagedProfileDescriptor: Equatable, Sendable {
    public static let scope = "wireguard-single-peer-ipv4-include-v1"
    public let profileID: UUID
    public let credentialID: UUID
    public let policyRevision: UUID
    public let generation: UInt64

    public init(profileID: UUID, credentialID: UUID, policyRevision: UUID,
                generation: UInt64) throws {
        guard generation > 0 else { throw ManagedLaunchError.invalidMetadata }
        self.profileID = profileID
        self.credentialID = credentialID
        self.policyRevision = policyRevision
        self.generation = generation
    }

    /// All fields are strings deliberately: avoid Bool/NSNumber and floating-point
    /// generation coercion when Foundation bridges property lists across processes.
    public var propertyList: [String: String] {
        ["version": "1", "scope": Self.scope, "profile": profileID.uuidString,
         "credential": credentialID.uuidString, "policyRevision": policyRevision.uuidString,
         "generation": String(generation)]
    }

    public init(propertyList: [String: String]) throws {
        guard propertyList.count == Self.keys.count, Set(propertyList.keys) == Self.keys,
              propertyList["version"] == "1", propertyList["scope"] == Self.scope,
              let profile = Self.uuid(propertyList["profile"]),
              let credential = Self.uuid(propertyList["credential"]),
              let policy = Self.uuid(propertyList["policyRevision"]),
              let text = propertyList["generation"], text.utf8.count <= 20,
              let generation = UInt64(text), generation > 0, String(generation) == text else {
            throw ManagedLaunchError.invalidMetadata
        }
        try self.init(profileID: profile, credentialID: credential,
                      policyRevision: policy, generation: generation)
    }

    fileprivate static let keys: Set<String> = [
        "version", "scope", "profile", "credential", "policyRevision", "generation"
    ]
    fileprivate static func uuid(_ value: String?) -> UUID? {
        guard let value, value.utf8.count == 36, let parsed = UUID(uuidString: value),
              parsed.uuidString == value else { return nil }
        return parsed
    }
}

/// A deliberate app start for the exact saved profile revision. No automatic,
/// on-demand, nil-options, or raw-configuration fallback is provided by this v1.
public struct ManagedStartRequest: Equatable, Sendable {
    public let attemptID: UUID
    public let profile: ManagedProfileDescriptor

    public init(attemptID: UUID = UUID(), profile: ManagedProfileDescriptor) {
        self.attemptID = attemptID
        self.profile = profile
    }
    public var propertyList: [String: String] {
        var result = profile.propertyList
        result["attempt"] = attemptID.uuidString
        return result
    }
    public init(propertyList: [String: String]) throws {
        guard propertyList.count == ManagedProfileDescriptor.keys.count + 1,
              Set(propertyList.keys) == ManagedProfileDescriptor.keys.union(["attempt"]),
              let attempt = ManagedProfileDescriptor.uuid(propertyList["attempt"]) else {
            throw ManagedLaunchError.invalidMetadata
        }
        var saved = propertyList
        saved.removeValue(forKey: "attempt")
        self.init(attemptID: attempt, profile: try ManagedProfileDescriptor(propertyList: saved))
    }
}

public enum ManagedLaunchError: String, Error, Equatable, Sendable {
    case invalidMetadata
    case invalidContainer
    case wrongProvider
    case missingCredentialReference
    case staleProfile
    case credentialReferenceChanged
}

/// A checked *metadata* snapshot, not a credential delivery or permission grant.
/// The runtime must still resolve and verify the referenced record and its complete
/// metadata through an authorized source before constructing a WireGuard session.
public struct CheckedManagedLaunch: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let request: ManagedStartRequest
    public let credentialReference: Data
    fileprivate init(request: ManagedStartRequest, reference: Data) {
        self.request = request
        self.credentialReference = Data(reference)
    }
    public var description: String { "CheckedManagedLaunch(<redacted>; metadata-only)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: EmptyCollection<(label: String?, value: Any)>())
    }
}

/// The same bounded Foundation boundary is used by the App and actual Provider.
/// Success means the request matches the *supplied* saved profile, not that either
/// is the latest authorized revision. A future credential/runtime authority must
/// perform that check again. Attempt UUIDs are correlation IDs, not replay tokens.
public enum ManagedLaunchContract {
    public static let profileKey = "VPNSplitterManagedProfile"
    public static let startKey = "VPNSplitterManagedStart"
    public static let maximumReferenceBytes = 4096

    public static func providerConfiguration(for profile: ManagedProfileDescriptor) -> [String: Any] {
        [profileKey: profile.propertyList]
    }
    public static func startOptions(for request: ManagedStartRequest) -> [String: NSObject] {
        [startKey: request.propertyList as NSDictionary]
    }

    public static func check(providerBundleIdentifier: String?, expectedProviderBundleIdentifier: String,
                             providerConfiguration: [String: Any]?, passwordReference: Data?,
                             options: [String: NSObject]?) throws -> CheckedManagedLaunch {
        guard !expectedProviderBundleIdentifier.isEmpty,
              providerBundleIdentifier == expectedProviderBundleIdentifier else {
            throw ManagedLaunchError.wrongProvider
        }
        guard let configuration = providerConfiguration, configuration.count == 1,
              let savedFields = fields(configuration[profileKey], count: 6),
              let options, options.count == 1,
              let requestedFields = fields(options[startKey], count: 7) else {
            throw ManagedLaunchError.invalidContainer
        }
        let saved = try ManagedProfileDescriptor(propertyList: savedFields)
        let request = try ManagedStartRequest(propertyList: requestedFields)
        guard saved == request.profile else { throw ManagedLaunchError.staleProfile }
        guard let reference = passwordReference, !reference.isEmpty,
              reference.count <= maximumReferenceBytes else {
            throw ManagedLaunchError.missingCredentialReference
        }
        return CheckedManagedLaunch(request: request, reference: reference)
    }

    private static func fields(_ value: Any?, count: Int) -> [String: String]? {
        guard let dictionary = value as? NSDictionary, dictionary.count == count else { return nil }
        return dictionary as? [String: String]
    }

    /// App-side comparison against the record reference selected in its transaction.
    /// Does not resolve the reference, access Keychain, or broaden LocalDev's ACL.
    public static func checkExpectedReference(_ expected: Data, launch: CheckedManagedLaunch) throws {
        guard !expected.isEmpty, expected == launch.credentialReference else {
            throw ManagedLaunchError.credentialReferenceChanged
        }
    }
}
