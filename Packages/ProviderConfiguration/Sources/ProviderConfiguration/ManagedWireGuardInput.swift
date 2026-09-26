// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import PolicyCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Static, bounded diagnostics only. Never retain input, paths, keys or an underlying Error.
public enum ManagedWireGuardInputError: String, Error, Equatable, Sendable {
    case configuration = "E_MANAGED_WG_CONFIGURATION"
    case script = "E_MANAGED_WG_SCRIPT"
    case unsupportedDirective = "E_MANAGED_WG_DIRECTIVE"
    case key = "E_MANAGED_WG_KEY"
    case singlePeer = "E_MANAGED_WG_SINGLE_PEER"
    case ipv6 = "E_MANAGED_WG_IPV6"
    case interfaceAddress = "E_MANAGED_WG_INTERFACE"
    case endpoint = "E_MANAGED_WG_ENDPOINT"
    case dnsNotSupported = "E_MANAGED_WG_DNS_NOT_READY"
    case allowedIPs = "E_MANAGED_WG_ALLOWED_IPS"
    case policy = "E_MANAGED_WG_POLICY"
    case policyLimit = "E_MANAGED_WG_POLICY_LIMIT"
    case infrastructureConflict = "E_MANAGED_WG_INFRASTRUCTURE"
    case outsideAllowedIPs = "E_MANAGED_WG_RANGE"
    case resourceLimit = "E_MANAGED_WG_LIMIT"
    case file = "E_MANAGED_WG_FILE"

    public var message: String {
        switch self {
        case .configuration: return "WireGuard 配置格式或字段不合法；原文件未修改。"
        case .script: return "配置包含脚本钩子，已拒绝；不会执行或自动删除脚本。"
        case .unsupportedDirective: return "配置包含尚未支持的指令，已拒绝；不会静默忽略。"
        case .key: return "WireGuard 密钥格式不合法；只检查格式，不证明握手或认证成功。"
        case .singlePeer: return "首条正式 IPv4 路径只接受一个 Peer；不会丢弃其他 Peer。"
        case .ipv6: return "配置包含 IPv6，本轮不执行部分配置；保留原文件，系统 IPv6 未修改。"
        case .interfaceAddress: return "接口需要有效且不重复的 IPv4 单播地址，不能与端点相同。"
        case .endpoint: return "首轮需要明确的 IPv4 单播端点；主机名解析和 IPv6 端点尚未接通。"
        case .dnsNotSupported: return "此首轮运行路径尚无 DNS 方案；含 DNS 地址或搜索域的配置被阻断，不会自动删除或忽略。"
        case .allowedIPs: return "Peer 的 AllowedIPs 不能为空；协议范围不会被用户规则扩大。"
        case .policy: return "规则归档不是受支持的 IPv4 Include 格式；未应用任何规则。"
        case .policyLimit: return "请输入 1–256 条 IPv4 CIDR，规则文本及归档各不超过 64 KiB。"
        case .infrastructureConflict: return "VPN 规则与端点、接口自身或保留地址冲突；不会改写明确规则来绕过冲突。"
        case .outsideAllowedIPs: return "指定 VPN 网段超出 Peer 的 AllowedIPs；请核对规则和原配置，不会自动扩大协议权限。"
        case .resourceLimit: return "材料或编译结果超过上限，已整体拒绝；没有部分应用。"
        case .file: return "请选择不超过 64 KiB 的普通 .conf 文件；不接受符号链接、目录或特殊文件。"
        }
    }
}

/// Checked syntax/scope/configuration constraints, NOT runtime authorization or an NE plan.
/// No Codable conformance or public initializer. The source bytes and policy remain one
/// immutable snapshot. A runtime must still revalidate identity, real underlay and epoch.
public struct CheckedManagedWireGuardInput: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let metadata: WGMetadata
    public let policy: IPv4Policy
    public let vpnRouteCount: Int
    private let configuration: Data
    private let policyArchive: Data

    fileprivate init(configuration: Data, policyArchive: Data, metadata: WGMetadata,
                     policy: IPv4Policy, vpnRouteCount: Int) {
        self.configuration = configuration; self.policyArchive = policyArchive
        self.metadata = metadata; self.policy = policy; self.vpnRouteCount = vpnRouteCount
    }
    /// Original validated bytes for later native conversion, never a credential-vault
    /// export. The caller already supplied them. Copies are not guaranteed zeroized.
    public func withValidatedSource<T>(_ body: (Data, Data) throws -> T) rethrows -> T {
        try body(configuration, policyArchive)
    }
    public var description: String { "CheckedManagedWireGuardInput(<redacted>; configuration-only)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

public enum ManagedWireGuardInput {
    public static let maximumBytes = 65_536
    public static let maximumRules = 256
    // Existing 08C archives remain readable, but must pass all checks on every delivery.
    public static let policySchema = "managed-ipv4-include-draft-v1"
    public static let boundary = "配置与规则检查通过不等于运行授权；尚未观察物理网络、应用系统设置、握手或验证出口。IPv6 未管理，无系统级 Kill Switch。"

    /// Same admission path before formal save, before XPC stage, and after Provider consume.
    /// Reuses the full existing parser (including keys/scripts/unknown fields), not regex
    /// extraction, saved metadata or an App-provided 'validated' flag.
    public static func prepare(configuration: Data, policyArchive: Data) throws -> CheckedManagedWireGuardInput {
        guard !configuration.isEmpty, configuration.count <= maximumBytes,
              !policyArchive.isEmpty, policyArchive.count <= maximumBytes else {
            throw ManagedWireGuardInputError.resourceLimit
        }
        let source = configuration.withUnsafeBytes { Data($0) }
        let archive = policyArchive.withUnsafeBytes { Data($0) }
        let metadata = try inspectConfiguration(source)
        let policy = try decodePolicy(archive)
        // This context is deliberately private and NEVER returned as a runtime epoch.
        let context = PlanContext(sessionID: "material-validation-only", backendID: "wireguard",
                                  generation: 0, networkEpoch: 0)
        do {
            let first = try WireGuardPlanning.compile(policy, metadata: metadata, context: context)
            // Supplement configuration-derived checks with addresses this IPv4 milestone
            // never routes. No guessed gateway/interface/physical LAN is manufactured.
            let reserved = try reservedRanges.enumerated().map { index, text in
                InfrastructureRequirement(id: "managed-reserved-\(index)", role: .systemReserved,
                                          cidr: try IPv4CIDR(text))
            }
            let constraints = IPv4ConstraintInput(context: context,
                infrastructure: first.input.infrastructure + reserved,
                wireGuardPeers: first.input.wireGuardPeers)
            let checked = try IPv4ConstrainedPolicyCompiler.compile(policy, capabilities: .wireGuard,
                context: context, constraints: constraints,
                limits: .init(maxRules: maximumRules))
            let count = checked.overrides.filter { $0.action == .vpn }.count
            guard count > 0 else { throw ManagedWireGuardInputError.policy }
            // Do not expose either planning-only plan as something installable by NE.
            return .init(configuration: source, policyArchive: archive, metadata: metadata,
                         policy: policy, vpnRouteCount: count)
        } catch let error as PolicyCompilationError {
            if error.diagnostics.contains(where: { $0.code == .infrastructureConflict }) {
                throw ManagedWireGuardInputError.infrastructureConflict
            }
            if error.diagnostics.contains(where: { $0.code == .peerUnreachableRange }) {
                throw ManagedWireGuardInputError.outsideAllowedIPs
            }
            if error.diagnostics.contains(where: { $0.code == .limitExceeded }) {
                throw ManagedWireGuardInputError.resourceLimit
            }
            throw ManagedWireGuardInputError.policy
        } catch let error as ManagedWireGuardInputError { throw error }
        catch { throw ManagedWireGuardInputError.configuration }
    }

    /// Useful at explicit file selection; policy constraints are still checked by prepare.
    public static func inspectConfiguration(_ source: Data) throws -> WGMetadata {
        guard !source.isEmpty, source.count <= maximumBytes else { throw ManagedWireGuardInputError.resourceLimit }
        let metadata: WGMetadata
        do { metadata = try WireGuardImport.prepareCredentials(source).metadata }
        catch let error as WGImportError {
            switch error.code {
            case .script: throw ManagedWireGuardInputError.script
            case .unsupported: throw ManagedWireGuardInputError.unsupportedDirective
            case .key: throw ManagedWireGuardInputError.key
            case .limit: throw ManagedWireGuardInputError.resourceLimit
            default: throw ManagedWireGuardInputError.configuration
            }
        } catch { throw ManagedWireGuardInputError.configuration }
        guard metadata.peers.count == 1 else { throw ManagedWireGuardInputError.singlePeer }
        if metadata.addresses.contains(where: \.isIPv6) || metadata.dnsServers.contains(where: { $0.contains(":") }) ||
            metadata.peers.contains(where: { $0.endpoint?.isIPv6 == true || $0.allowedIPs.contains(where: \.isIPv6) }) {
            throw ManagedWireGuardInputError.ipv6
        }
        guard !metadata.addresses.isEmpty,
              Set(metadata.addresses.map(\.address)).count == metadata.addresses.count,
              metadata.addresses.allSatisfy({ isUnicast($0.address) && ($0.ipv4CIDR?.prefixLength ?? 0) > 0 }) else {
            throw ManagedWireGuardInputError.interfaceAddress
        }
        guard let endpoint = metadata.peers[0].endpoint, !endpoint.isHostname,
              isUnicast(endpoint.host) else { throw ManagedWireGuardInputError.endpoint }
        guard !metadata.addresses.contains(where: { $0.address == endpoint.host }) else {
            throw ManagedWireGuardInputError.interfaceAddress
        }
        guard metadata.dnsServers.isEmpty, metadata.searchDomains.isEmpty else {
            throw ManagedWireGuardInputError.dnsNotSupported
        }
        guard !metadata.peers[0].allowedIPs.isEmpty else { throw ManagedWireGuardInputError.allowedIPs }
        return metadata
    }

    /// Encode the same v1 binary plist used by 08C. Canonicalization is limited to rules,
    /// never to the interface's host address, protocol AllowedIPs, endpoint or key bytes.
    public static func encodeIncludePolicy(_ text: String) throws -> Data {
        guard text.utf8.count <= maximumBytes else { throw ManagedWireGuardInputError.policyLimit }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard (1...maximumRules).contains(lines.count) else { throw ManagedWireGuardInputError.policyLimit }
        let cidrs: [String]
        do { cidrs = try lines.map { try IPv4CIDR($0).description } }
        catch { throw ManagedWireGuardInputError.policy }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: [
                "schema": policySchema, "default": "DIRECT", "vpnCIDRs": cidrs
            ], format: .binary, options: 0)
            guard data.count <= maximumBytes else { throw ManagedWireGuardInputError.policyLimit }
            return data
        } catch let error as ManagedWireGuardInputError { throw error }
        catch { throw ManagedWireGuardInputError.policy }
    }

    private static func decodePolicy(_ data: Data) throws -> IPv4Policy {
        do {
            var format = PropertyListSerialization.PropertyListFormat.binary
            guard let fields = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any],
                  format == .binary, Set(fields.keys) == ["schema", "default", "vpnCIDRs"],
                  fields["schema"] as? String == policySchema, fields["default"] as? String == "DIRECT",
                  let values = fields["vpnCIDRs"] as? [String], (1...maximumRules).contains(values.count) else {
                throw ManagedWireGuardInputError.policy
            }
            let rules = try values.enumerated().map { index, text -> PolicyRule in
                let cidr = try IPv4CIDR(text)
                guard text == cidr.description else { throw ManagedWireGuardInputError.policy }
                return PolicyRule(id: "managed-vpn-\(index + 1)", match: .ipv4(cidr), action: .vpn)
            }
            return IPv4Policy(defaultAction: .direct, rules: rules)
        } catch { throw ManagedWireGuardInputError.policy }
    }

    private static let reservedRanges = ["0.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/3"]
    private static func isUnicast(_ text: String) -> Bool {
        guard let address = try? IPv4Address(text) else { return false }
        return !reservedRanges.contains { (try? IPv4CIDR($0))?.contains(address) == true }
    }

    /// User-selected file only. Validate the opened descriptor rather than checking a
    /// URL then reopening it. Bound growth after fstat; no original-path persistence.
    public static func readConfigurationFile(_ url: URL) throws -> Data {
        guard url.isFileURL, url.pathExtension.lowercased() == "conf", !url.path.utf8.contains(0) else {
            throw ManagedWireGuardInputError.file
        }
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else { throw ManagedWireGuardInputError.file }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size > 0, info.st_size <= maximumBytes else { throw ManagedWireGuardInputError.file }
        let data: Data
        do { data = try file.read(upToCount: maximumBytes + 1) ?? Data() }
        catch { throw ManagedWireGuardInputError.file }
        _ = try inspectConfiguration(data)
        return data
    }
}
