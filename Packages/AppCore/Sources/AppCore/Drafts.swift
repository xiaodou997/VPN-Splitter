// SPDX-License-Identifier: MIT
import Foundation
import PolicyCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum DraftBackend: String, Codable, CaseIterable, Sendable {
    case wireGuard = "WireGuard", openVPN = "OpenVPN", external = "External"
    var capabilities: BackendCapabilities {
        switch self {
        case .wireGuard: .wireGuard
        case .openVPN: .openVPN
        case .external: .external
        }
    }
}

public enum DraftAction: String, Codable, CaseIterable, Sendable {
    case direct = "DIRECT", vpn = "VPN", reject = "REJECT"
    var policyAction: PolicyAction {
        switch self { case .direct: .direct; case .vpn: .vpn; case .reject: .reject }
    }
}

public enum DraftMatch: String, Codable, CaseIterable, Sendable {
    case ipv4 = "IP / CIDR", domain = "DOMAIN", suffix = "DOMAIN-SUFFIX", ipv6 = "IPv6"
}

/// A policy draft, not a VPN configuration or a credential container.
public struct DraftRule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var match: DraftMatch
    public var value: String
    public var action: DraftAction
    public var enabled: Bool

    public init(id: UUID = UUID(), match: DraftMatch = .ipv4, value: String = "",
                action: DraftAction = .vpn, enabled: Bool = true) {
        self.id = id; self.match = match; self.value = value
        self.action = action; self.enabled = enabled
    }
}

public struct ProfileDraft: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var backend: DraftBackend
    public var defaultAction: DraftAction
    public var rules: [DraftRule]

    public init(id: UUID = UUID(), name: String = "新配置草稿", backend: DraftBackend = .wireGuard,
                defaultAction: DraftAction = .direct, rules: [DraftRule] = []) {
        self.id = id; self.name = name; self.backend = backend
        self.defaultAction = defaultAction; self.rules = rules
    }

    public mutating func moveRule(id: UUID, offset: Int) {
        guard offset == -1 || offset == 1,
              let index = rules.firstIndex(where: { $0.id == id }),
              rules.indices.contains(index + offset) else { return }
        rules.swapAt(index, index + offset)
    }
}

public enum DraftError: String, Error, Sendable {
    case unsupportedVersion = "E_DRAFT_VERSION"
    case invalidDraft = "E_DRAFT_INVALID"
    case tooLarge = "E_DRAFT_LIMIT"
    case readFailed = "E_DRAFT_READ"
    case writeFailed = "E_DRAFT_WRITE"
    case invalidIPv4 = "E_IPV4_INPUT"
    case noProfile = "E_NO_PROFILE"
}

public struct Workspace: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var profiles: [ProfileDraft]
    public static let byteLimit = 2 * 1024 * 1024

    public init(profiles: [ProfileDraft] = [], schemaVersion: Int = 1) {
        self.profiles = profiles; self.schemaVersion = schemaVersion
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw DraftError.unsupportedVersion }
        guard profiles.count <= 100 else { throw DraftError.tooLarge }
        guard Set(profiles.map(\.id)).count == profiles.count else { throw DraftError.invalidDraft }
        for profile in profiles {
            guard Self.singleLine(profile.name, limit: 160),
                  !profile.name.trimmingCharacters(in: .whitespaces).isEmpty,
                  Set(profile.rules.map(\.id)).count == profile.rules.count else { throw DraftError.invalidDraft }
            guard profile.rules.count <= CompilationLimits.ruleCeiling else { throw DraftError.tooLarge }
            for rule in profile.rules {
                guard Self.singleLine(rule.value, limit: 255) else { throw DraftError.invalidDraft }
            }
        }
    }

    private static func singleLine(_ value: String, limit: Int) -> Bool {
        value.utf8.count <= limit && !value.unicodeScalars.contains { CharacterSet.controlCharacters.union(.newlines).contains($0) }
    }
}

/// Only explicitly modelled metadata is serialized. No raw .conf/.ovpn importer.
/// Corrupt/future-version data is an error, never an automatic empty reset.
public struct DraftStore: Sendable {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("workspace.json") }
    public init(directory: URL) { self.directory = directory }

    private func rejectLinks() throws {
        for url in [directory, file] {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw DraftError.invalidDraft
            }
        }
    }

    public func load() throws -> Workspace {
        do {
            try rejectLinks()
            guard FileManager.default.fileExists(atPath: file.path) else { return Workspace() }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Workspace.byteLimit + 1) ?? Data()
            guard data.count <= Workspace.byteLimit else { throw DraftError.tooLarge }
            let workspace = try JSONDecoder().decode(Workspace.self, from: data)
            try workspace.validate()
            return workspace
        } catch let error as DraftError { throw error }
        catch { throw DraftError.readFailed }
    }

    public func save(_ workspace: Workspace) throws {
        try workspace.validate()
        do {
            try rejectLinks()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(workspace)
            guard data.count <= Workspace.byteLimit else { throw DraftError.tooLarge }
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            // Prepare a private sibling, then publish with one atomic rename.
            // All fallible preparation is before rename, so a failed save keeps
            // the previous workspace. The directory is private during creation.
            let temporary = directory.appendingPathComponent(".workspace-\(UUID().uuidString).tmp")
            defer { try? manager.removeItem(at: temporary) }
            try data.write(to: temporary, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            let handle = try FileHandle(forWritingTo: temporary)
            do { try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
            guard rename(temporary.path, file.path) == 0 else { throw DraftError.writeFailed }
        } catch let error as DraftError { throw error }
        catch { throw DraftError.writeFailed }
    }
}
