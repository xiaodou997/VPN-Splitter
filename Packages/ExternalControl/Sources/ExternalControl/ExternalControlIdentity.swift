// SPDX-License-Identifier: MIT
import Foundation

public enum ExternalControlIdentity {
    // Separate from old ad-hoc ExternalPreview and all Managed/WireGuard identities.
    public static let app = "io.github.xiaodou997.VPNSplitter.ExternalControl"
    public static let helper = "io.github.xiaodou997.VPNSplitter.ExternalHelper"
    public static let service = helper + ".v1"
    public static let plist = service + ".plist"
    public static func requirement(team: String, helper: Bool) throws -> String {
        guard team.utf8.count == 10, team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else {
            throw ExternalControlError.authentication
        }
        var value = "anchor apple generic and identifier \"\(helper ? Self.helper : app)\" and certificate leaf[subject.OU] = \"\(team)\""
        for entitlement in ["com.apple.security.get-task-allow", "com.apple.security.cs.disable-library-validation",
                            "com.apple.security.cs.allow-dyld-environment-variables", "com.apple.security.cs.allow-unsigned-executable-memory"] {
            value += " and ! (entitlement[\"\(entitlement)\"] exists)"
        }
        return value
    }
}
#if os(macOS)
import Security
import Darwin

@objc public protocol ExternalHelperXPC {
    func request(_ data: Data, reply: @escaping @Sendable (Data) -> Void)
}
public extension ExternalControlIdentity {
    /// Team comes from our own validated code signature, never the caller or environment.
    static func currentTeam(helper: Bool) throws -> String {
        guard helper ? (getuid() == 0 && geteuid() == 0) : (getuid() > 0 && geteuid() == getuid()) else {
            throw ExternalControlError.authentication
        }
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let fields = info as? [String: Any], let team = fields[kSecCodeInfoTeamIdentifier as String] as? String,
              let flags = fields[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & 0x10000 != 0 /* public kSecCodeSignatureRuntime */ else { throw ExternalControlError.authentication }
        let own = try requirement(team: team, helper: helper)
        guard SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), try compiledRequirement(own)) == errSecSuccess else {
            throw ExternalControlError.authentication
        }
        // Validate both strings before the Foundation setters, which can raise ObjC exceptions.
        _ = try compiledRequirement(requirement(team: team, helper: !helper))
        return team
    }
    static func compiledRequirement(_ text: String) throws -> SecRequirement {
        var result: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(rawValue: 0), &result) == errSecSuccess,
              let result else { throw ExternalControlError.authentication }
        return result
    }
}
#endif
