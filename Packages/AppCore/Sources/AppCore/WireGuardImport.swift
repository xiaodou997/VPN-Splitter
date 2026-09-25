// SPDX-License-Identifier: MIT
import Foundation
import PolicyCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Import errors contain only static codes, known field names and line numbers.
/// Do not add raw lines, paths, keys or arbitrary underlying Error descriptions.
public struct WGImportError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Code: String, Sendable {
        case text = "E_WG_TEXT", syntax = "E_WG_SYNTAX", duplicate = "E_WG_DUPLICATE"
        case unsupported = "E_WG_UNSUPPORTED", script = "E_WG_SCRIPT_REJECTED"
        case key = "E_WG_KEY_FORMAT", address = "E_WG_ADDRESS", endpoint = "E_WG_ENDPOINT"
        case number = "E_WG_NUMBER", required = "E_WG_REQUIRED", limit = "E_WG_LIMIT"
        case read = "E_WG_READ", fileType = "E_WG_FILE_TYPE", metadata = "E_WG_METADATA"
        case planning = "E_WG_PLANNING_BLOCKED", backend = "E_WG_BACKEND"
    }
    public let code: Code
    public let line: Int?
    public let field: WGField?
    public init(_ code: Code, line: Int? = nil, field: WGField? = nil) {
        self.code = code; self.line = line; self.field = field
    }
    public var description: String { code.rawValue }
    public var message: String {
        let location = line.map { "第 \($0) 行：" } ?? ""
        let name = field.map { "\($0.rawValue)：" } ?? ""
        let reason: String
        switch code {
        case .text: reason = "配置必须是 UTF-8 文本，且不能包含控制字符。"
        case .syntax: reason = "配置结构不正确。只接受一个 Interface 和随后的一组 Peer。"
        case .duplicate: reason = "出现重复字段、重复 Interface 或相同的 Peer 公钥；未采用最后一项覆盖。"
        case .unsupported: reason = "包含当前导入器未支持的指令；未忽略、执行或保存该指令。"
        case .script: reason = "不接受脚本钩子。不会执行脚本，也不会将删除脚本视为等价配置。"
        case .key: reason = "密钥须为规范 Base64 编码的 32 字节非零值。这里只检查格式，不验证认证。"
        case .address: reason = "地址或网段格式不正确；IPv4 使用规范十进制，IPv6 不接受作用域标识。"
        case .endpoint: reason = "端点须为 IPv4:端口、[IPv6]:端口或 ASCII 主机名:端口，端口范围 1–65535。"
        case .number: reason = "数值超出支持范围，或不是十进制整数。"
        case .required: reason = "缺少必要字段或 Peer。PrivateKey 和每个 Peer 的 PublicKey 必须存在。"
        case .limit: reason = "超过导入上限：256 KiB、4096 行、单行 4096 字节、64 个 Peer、2048 个 AllowedIPs。"
        case .read: reason = "无法读取所选常规文件。符号链接、目录及特殊文件不会被导入；原文件不变。"
        case .fileType: reason = "当前只导入 WireGuard .conf；OpenVPN .ovpn 尚未开放。"
        case .metadata: reason = "保存的 WireGuard 结构不合法。请保留原文件，不要清空数据。"
        case .planning: reason = "配置存在尚未支持或未确认的项目。请查看 WireGuard 结构中的兼容性提示。"
        case .backend: reason = "此策略已关联 WireGuard 结构；请先移除该结构，再切换能力预设。"
        }
        return location + name + reason
    }
}

public enum WGField: String, Sendable {
    case privateKey = "PrivateKey", address = "Address", dns = "DNS", listenPort = "ListenPort", mtu = "MTU"
    case publicKey = "PublicKey", presharedKey = "PresharedKey", allowedIPs = "AllowedIPs"
    case endpoint = "Endpoint", persistentKeepalive = "PersistentKeepalive"
    fileprivate static func parse(_ key: String) -> Self? {
        [Self.privateKey, .address, .dns, .listenPort, .mtu, .publicKey, .presharedKey,
         .allowedIPs, .endpoint, .persistentKeepalive].first { $0.rawValue.lowercased() == key }
    }
}

/// Network structure only. There is deliberately no credential / raw-config field.
/// Original host bits and prefix spelling are retained; policy normalization is separate.
public struct WGAddressRange: Codable, Equatable, Sendable {
    public let text: String
    public var address: String { String(text.split(separator: "/")[0]) }
    public var isIPv6: Bool { text.contains(":") }
    public var ipv4CIDR: IPv4CIDR? {
        guard !isIPv6 else { return nil }
        return try? IPv4CIDR(text.contains("/") ? text : text + "/32")
    }
    init(_ text: String) throws {
        guard text.utf8.count <= 64 else { throw WGImportError(.address) }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), WGValidation.ip(String(parts[0])) != nil else {
            throw WGImportError(.address)
        }
        let width = parts[0].contains(":") ? 128 : 32
        if parts.count == 2 { _ = try WGValidation.integer(String(parts[1]), range: 0...width, code: .address) }
        self.text = text
    }
}

public struct WGEndpoint: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public var isHostname: Bool { WGValidation.ip(host) == nil }
    public var isIPv6: Bool { host.contains(":") }
    public var display: String { isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)" }
    init(_ text: String) throws {
        guard text.utf8.count <= 264 else { throw WGImportError(.endpoint) }
        let host: String
        let portText: String
        if text.first == "[", let close = text.firstIndex(of: "]") {
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            guard rest.first == ":", WGValidation.ip(host) == 6 else { throw WGImportError(.endpoint) }
            portText = String(rest.dropFirst())
        } else {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw WGImportError(.endpoint) }
            host = String(parts[0]); portText = String(parts[1])
            guard WGValidation.ip(host) == 4 || WGValidation.hostname(host) else { throw WGImportError(.endpoint) }
        }
        self.host = host
        self.port = try WGValidation.integer(portText, range: 1...65535, code: .endpoint)
    }
}

public struct WGPeerMetadata: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let allowedIPs: [WGAddressRange]
    public let endpoint: WGEndpoint?
    public let persistentKeepalive: Int?
    public let hadPresharedKey: Bool
}

public struct WGCompatibilityIssue: Equatable, Sendable {
    public let code: String
    public let message: String
    public let blocksPlanning: Bool
}

public struct WGMetadata: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let addresses: [WGAddressRange]
    public let dnsServers: [String]
    public let searchDomains: [String]
    public let listenPort: Int?
    public let mtu: Int?
    public let peers: [WGPeerMetadata]

    public static let credentialBoundary = "此处仅展示网络结构；密钥不在草稿 JSON 或本报告中。是否关联 Keychain 请查看凭据状态；原 .conf 请继续保留。"

    /// Revalidate decoded metadata instead of trusting a saved compatibility flag.
    public func validate() throws {
        guard formatVersion == 1, addresses.count <= 64, dnsServers.count <= 32,
              searchDomains.count <= 32, (1...64).contains(peers.count),
              peers.reduce(0, { $0 + $1.allowedIPs.count }) <= 2048 else { throw WGImportError(.metadata) }
        if let listenPort, !(0...65535).contains(listenPort) { throw WGImportError(.metadata) }
        if let mtu, !(576...65535).contains(mtu) { throw WGImportError(.metadata) }
        for address in addresses { _ = try WGAddressRange(address.text) }
        for server in dnsServers where WGValidation.ip(server) == nil { throw WGImportError(.metadata) }
        for domain in searchDomains where !WGValidation.hostname(domain) { throw WGImportError(.metadata) }
        for (index, peer) in peers.enumerated() {
            guard peer.id == "peer-\(index + 1)", peer.allowedIPs.count <= 2048 else { throw WGImportError(.metadata) }
            for range in peer.allowedIPs { _ = try WGAddressRange(range.text) }
            if let endpoint = peer.endpoint {
                guard try WGEndpoint(endpoint.display) == endpoint else { throw WGImportError(.metadata) }
            }
            if let value = peer.persistentKeepalive, !(0...65535).contains(value) { throw WGImportError(.metadata) }
        }
    }

    public var compatibilityIssues: [WGCompatibilityIssue] {
        var issues: [WGCompatibilityIssue] = []
        if addresses.isEmpty {
            issues.append(.init(code: "W_WG_ADDRESS_REQUIRED", message: "缺少接口 Address；可保存结构，但当前客户端约束预览不能继续。", blocksPlanning: true))
        }
        if addresses.contains(where: \.isIPv6) || dnsServers.contains(where: { $0.contains(":") }) ||
            peers.contains(where: { $0.allowedIPs.contains(where: \.isIPv6) || $0.endpoint?.isIPv6 == true }) {
            issues.append(.init(code: "W_WG_IPV6_UNSUPPORTED", message: "包含 IPv6：结构已保留，但本轮不生成部分成功的 IPv4 约束计划，也不修改系统 IPv6。", blocksPlanning: true))
        }
        for (index, peer) in peers.enumerated() {
            if peer.endpoint == nil {
                issues.append(.init(code: "W_WG_ENDPOINT_REQUIRED", message: "Peer \(index + 1) 未提供端点；被动 Peer 配置不在本轮客户端预览范围。", blocksPlanning: true))
            } else if peer.endpoint?.isHostname == true {
                issues.append(.init(code: "W_WG_ENDPOINT_DNS", message: "Peer \(index + 1) 使用主机名端点，尚未解析；不能用空地址假装已检查端点例外。", blocksPlanning: true))
            }
            if peer.allowedIPs.isEmpty {
                issues.append(.init(code: "W_WG_ALLOWED_IPS_EMPTY", message: "Peer \(index + 1) 的 AllowedIPs 为空，当前无可规划的目标范围。", blocksPlanning: true))
            }
        }
        if !searchDomains.isEmpty {
            issues.append(.init(code: "W_WG_SEARCH_DOMAINS", message: "DNS 搜索域只保留为结构信息，不配置解析器，也不转换为 DOMAIN 分流规则。", blocksPlanning: false))
        }
        return issues
    }

    public var summary: String {
        var lines = [Self.credentialBoundary, "检查假设：文件中的 DNS 地址按 VPN DNS 检查，不配置实际解析器。", "接口地址：" + addresses.map(\.text).joined(separator: ", "),
                     "DNS 地址：" + dnsServers.joined(separator: ", ")]
        if !searchDomains.isEmpty { lines.append("DNS 搜索域：" + searchDomains.joined(separator: ", ")) }
        if let mtu { lines.append("MTU：\(mtu)（未应用）") }
        if let listenPort { lines.append("ListenPort：\(listenPort)（未监听）") }
        for (index, peer) in peers.enumerated() {
            lines.append("Peer \(index + 1)：\(peer.endpoint?.display ?? "未提供端点")")
            lines.append("AllowedIPs（协议原值，不是用户规则）：" + peer.allowedIPs.map(\.text).joined(separator: ", "))
            if let interval = peer.persistentKeepalive { lines.append("Keepalive：\(interval) 秒（未运行）") }
            lines.append(peer.hadPresharedKey ? "配置含预共享密钥：值不在本报告中" : "配置未提供预共享密钥")
        }
        return lines.joined(separator: "\n")
    }
}

// Shared with the bounded parameter editor; not a public parsing API.
enum WGValidation {
    static func ip(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.count <= 45, !text.contains("%"),
              text.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) ||
                  (97...102).contains($0) || $0 == 46 || $0 == 58 }) else { return nil }
        if !text.contains(":") { return (try? IPv4Address(text)) == nil ? nil : 4 }
        var value = in6_addr()
        return text.withCString { inet_pton(AF_INET6, $0, &value) } == 1 ? 6 : nil
    }
    static func hostname(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 253 else { return false }
        let value = text.hasSuffix(".") ? String(text.dropLast()) : text
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        // Numeric-looking invalid IPv4 must not silently become a hostname.
        guard value.utf8.contains(where: { (65...90).contains($0) || (97...122).contains($0) }) else { return false }
        return labels.allSatisfy { label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }
    static func integer(_ text: String, range: ClosedRange<Int>, code: WGImportError.Code = .number) throws -> Int {
        guard (1...5).contains(text.utf8.count), text.utf8.allSatisfy({ (48...57).contains($0) }),
              text.count == 1 || text.first != "0", let value = Int(text), range.contains(value) else {
            throw WGImportError(code)
        }
        return value
    }
    static func key(_ value: String) throws -> Data {
        guard value.utf8.count == 44, let decoded = Data(base64Encoded: value), decoded.count == 32,
              decoded.base64EncodedString() == value, decoded.contains(where: { $0 != 0 }) else {
            throw WGImportError(.key)
        }
        return decoded
    }
}

public enum WireGuardImport {
    public static let byteLimit = 256 * 1024
    private struct Section {
        let line: Int
        var values: [WGField: [(value: String, line: Int)]] = [:]
    }

    /// A one-way projection: key bytes never escape this function in its result.
    /// Swift String/Data may make copies; releasing them is NOT guaranteed zeroization.
    public static func parse(_ data: Data) throws -> WGMetadata {
        try prepareCredentials(data).metadata
    }

    /// Explicit ephemeral capture; only the confirmation flow may send these keys to Keychain.
    public static func prepareCredentials(_ data: Data) throws -> WGCredentialMaterial {
        guard data.count <= byteLimit else { throw WGImportError(.limit) }
        guard var source = String(data: data, encoding: .utf8) else { throw WGImportError(.text) }
        if source.first == "\u{feff}" { source.removeFirst() }
        source = source.replacingOccurrences(of: "\r\n", with: "\n")
        guard !source.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && $0 != "\t" && $0 != "\n"
        }) else { throw WGImportError(.text) }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count <= 4096 else { throw WGImportError(.limit) }
        var interface: Section?
        var peers: [Section] = []
        for (offset, raw) in lines.enumerated() {
            let line = offset + 1
            guard raw.utf8.count <= 4096 else { throw WGImportError(.limit, line: line) }
            let value = String(raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
                .trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            if value.lowercased() == "[interface]" {
                guard interface == nil, peers.isEmpty else { throw WGImportError(.duplicate, line: line) }
                interface = Section(line: line); continue
            }
            if value.lowercased() == "[peer]" {
                guard interface != nil else { throw WGImportError(.syntax, line: line) }
                guard peers.count < 64 else { throw WGImportError(.limit, line: line) }
                peers.append(Section(line: line)); continue
            }
            guard interface != nil, let separator = value.firstIndex(of: "="), !value.hasPrefix("[") else {
                throw WGImportError(.syntax, line: line)
            }
            let key = value[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            if ["preup", "postup", "predown", "postdown"].contains(key) { throw WGImportError(.script, line: line) }
            guard let field = WGField.parse(key) else { throw WGImportError(.unsupported, line: line) }
            let payload = value[value.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            let inInterface = peers.isEmpty
            let interfaceFields: [WGField] = [.privateKey, .address, .dns, .listenPort, .mtu]
            guard interfaceFields.contains(field) == inInterface else { throw WGImportError(.syntax, line: line, field: field) }
            var section = inInterface ? interface! : peers[peers.count - 1]
            if section.values[field] != nil, ![WGField.address, .dns, .allowedIPs].contains(field) {
                throw WGImportError(.duplicate, line: line, field: field)
            }
            section.values[field, default: []].append((payload, line))
            if inInterface { interface = section } else { peers[peers.count - 1] = section }
        }
        guard let interface, !peers.isEmpty else { throw WGImportError(.required) }
        guard let privateKey = interface.values[.privateKey]?.first else {
            throw WGImportError(.required, line: interface.line, field: .privateKey)
        }
        let secret = try fieldValue(privateKey, field: .privateKey) { try WGValidation.key($0) }
        let addresses = try list(interface, field: .address).map { try fieldValue($0, field: .address) { try WGAddressRange($0) } }
        var dns: [String] = []; var domains: [String] = []
        for entry in try list(interface, field: .dns) {
            if WGValidation.ip(entry.value) != nil { dns.append(entry.value) }
            else if WGValidation.hostname(entry.value) { domains.append(entry.value) }
            else { throw WGImportError(.address, line: entry.line, field: .dns) }
        }
        var publicKeys: Set<Data> = []
        var metadataPeers: [WGPeerMetadata] = []
        var credentialPeers: [(id: String, publicKey: Data, presharedKey: Data?)] = []
        for (index, peer) in peers.enumerated() {
            guard let key = peer.values[.publicKey]?.first else {
                throw WGImportError(.required, line: peer.line, field: .publicKey)
            }
            let decoded = try fieldValue(key, field: .publicKey) { try WGValidation.key($0) }
            guard publicKeys.insert(decoded).inserted else { throw WGImportError(.duplicate, line: key.line, field: .publicKey) }
            let preshared = try peer.values[.presharedKey]?.first.map { try fieldValue($0, field: .presharedKey) { try WGValidation.key($0) } }
            credentialPeers.append(("peer-\(index + 1)", decoded, preshared))
            let ranges = try list(peer, field: .allowedIPs, allowEmpty: true).map { try fieldValue($0, field: .allowedIPs) { try WGAddressRange($0) } }
            let endpoint = try peer.values[.endpoint]?.first.map { try fieldValue($0, field: .endpoint) { try WGEndpoint($0) } }
            metadataPeers.append(.init(id: "peer-\(index + 1)", allowedIPs: ranges, endpoint: endpoint,
                persistentKeepalive: try number(peer, .persistentKeepalive, range: 0...65535, allowOff: true),
                hadPresharedKey: peer.values[.presharedKey] != nil))
        }
        let result = WGMetadata(formatVersion: 1, addresses: addresses, dnsServers: dns, searchDomains: domains,
            listenPort: try number(interface, .listenPort, range: 0...65535),
            mtu: try number(interface, .mtu, range: 576...65535), peers: metadataPeers)
        do { try result.validate() }
        catch { throw WGImportError(.limit) }
        return try WGCredentialMaterial(metadata: result, privateKey: secret, peers: credentialPeers)
    }

    private static func fieldValue<T>(_ entry: (value: String, line: Int), field: WGField,
                                      _ transform: (String) throws -> T) throws -> T {
        do { return try transform(entry.value) }
        catch let error as WGImportError { throw WGImportError(error.code, line: entry.line, field: field) }
        catch { throw WGImportError(.syntax, line: entry.line, field: field) }
    }
    private static func list(_ section: Section, field: WGField, allowEmpty: Bool = false) throws -> [(value: String, line: Int)] {
        var result: [(value: String, line: Int)] = []
        for entry in section.values[field] ?? [] {
            if entry.value.isEmpty, allowEmpty { continue }
            let values = entry.value.split(separator: ",", omittingEmptySubsequences: false)
            for value in values {
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { throw WGImportError(.address, line: entry.line, field: field) }
                result.append((trimmed, entry.line))
            }
        }
        return result
    }
    private static func number(_ section: Section, _ field: WGField, range: ClosedRange<Int>, allowOff: Bool = false) throws -> Int? {
        try section.values[field]?.first.map { entry in
            try fieldValue(entry, field: field) { value in
                if allowOff, value.lowercased() == "off" { return 0 }
                return try WGValidation.integer(value, range: range)
            }
        }
    }
}

/// Reads one explicitly chosen local regular file. No bookmarks, copying or path persistence.
public enum WGImportFileReader {
    public static func read(_ url: URL) throws -> WGMetadata {
        try WireGuardImport.parse(readBytes(url))
    }
    public static func readCredentials(_ url: URL) throws -> WGCredentialMaterial {
        try WireGuardImport.prepareCredentials(readBytes(url))
    }
    private static func readBytes(_ url: URL) throws -> Data {
        guard url.isFileURL, url.pathExtension.lowercased() == "conf" else { throw WGImportError(.fileType) }
        guard !url.path.utf8.contains(0) else { throw WGImportError(.read) }
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else { throw WGImportError(.read) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw WGImportError(.read) }
        guard info.st_size >= 0, info.st_size <= WireGuardImport.byteLimit else { throw WGImportError(.limit) }
        let data: Data
        do { data = try handle.read(upToCount: WireGuardImport.byteLimit + 1) ?? Data() }
        catch { throw WGImportError(.read) }
        return data
    }
}
