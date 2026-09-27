// SPDX-License-Identifier: MIT
import Foundation
import PolicyCore

public enum ExternalError: String, Error, Sendable {
    case readFailed, changedDuringRead, malformedRoutes, limitExceeded, expired
    case physicalUnknown, physicalAmbiguous, tunnelUnknown, tunnelAmbiguous, unsupportedTopology
    case invalidRules, protectedRange, existingRouteConflict, scopedRouteConflict
    public var message: String {
        switch self {
        case .readFailed: return "无法完整读取本机网络；未生成预览。"
        case .changedDuringRead: return "读取期间网络状态发生变化，请重新检测；旧预览已失效。"
        case .malformedRoutes: return "路由表格式无法完整识别；不会跳过未知记录继续。"
        case .limitExceeded: return "输入或网络记录超过本轮处理上限，已整体停止。"
        case .expired: return "网络快照已过期，请重新检测并预览。"
        case .physicalUnknown: return "未确认物理服务、当前 IPv4 网关及其链路路由；仅能诊断。"
        case .physicalAmbiguous: return "存在多条物理网络候选，不能自动选一条作为直连出口。"
        case .tunnelUnknown: return "未找到单一全局 IPv4 隧道路由模式；原客户端可能未连接或不是本轮支持的路由类型。"
        case .tunnelAmbiguous: return "发现多个 IPv4 隧道候选，不能确定原 VPN 路径。"
        case .unsupportedTopology: return "默认路由或半默认路由存在歧义；不能生成直连例外。"
        case .invalidRules: return "请输入 1–64 条 IPv4 地址或 CIDR；不支持域名、IPv6 或默认直连模式。"
        case .protectedRange: return "规则与本机地址、物理局域网、观察到的 DNS 或保留地址重叠；不会自动裁剪。"
        case .existingRouteConflict: return "规则涉及已有的同级或更具体路由；未取得覆盖或删除权，已停止预览。"
        case .scopedRouteConflict: return "规则涉及作用域路由，实际选路有歧义；未生成例外。"
        }
    }
}

public struct ExternalInterface: Hashable, Sendable {
    public let name: String
    public let isUp: Bool
    public let isTunnelCandidate: Bool
    public let addresses: [IPv4Address]
    public init(name: String, isUp: Bool, isTunnelCandidate: Bool, addresses: [IPv4Address]) {
        self.name = name; self.isUp = isUp; self.isTunnelCandidate = isTunnelCandidate; self.addresses = addresses
    }
}

/// Current service state + interface observation, never the current default route alone.
public struct ExternalPhysicalPath: Hashable, Sendable {
    public let service: String
    public let interface: String
    public let gateway: IPv4Address
    public let networks: [IPv4CIDR]
    public init(service: String, interface: String, gateway: IPv4Address, networks: [IPv4CIDR]) {
        self.service = service; self.interface = interface; self.gateway = gateway; self.networks = networks
    }
}

public struct ExternalRoute: Hashable, Sendable {
    public let destination: IPv4CIDR
    public let gateway: String
    public let interface: String
    public let flags: String
    public var scoped: Bool { flags.contains("I") }
    public var usable: Bool { flags.contains("U") && !flags.contains("R") && !flags.contains("B") }
    public init(destination: IPv4CIDR, gateway: String, interface: String, flags: String) {
        self.destination = destination; self.gateway = gateway; self.interface = interface; self.flags = flags
    }
}

/// Snapshot is display/planning evidence only, not a route-write capability or ownership receipt.
/// No Codable or automatic persistence; diagnostics must opt into displaying local fields.
public struct ExternalObservation: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let id: UUID
    public let capturedAtUptime: TimeInterval
    public let interfaces: [ExternalInterface]
    public let physicalPaths: [ExternalPhysicalPath]
    public let routes: Set<ExternalRoute>
    public let observedDNSServers: [IPv4Address]
    public init(id: UUID = UUID(), capturedAtUptime: TimeInterval, interfaces: [ExternalInterface],
                physicalPaths: [ExternalPhysicalPath], routes: Set<ExternalRoute>, observedDNSServers: [IPv4Address]) throws {
        guard capturedAtUptime.isFinite, capturedAtUptime >= 0,
              interfaces.count <= 128, physicalPaths.count <= 64, routes.count <= 8192,
              observedDNSServers.count <= 256,
              Set(interfaces.map(\.name)).count == interfaces.count,
              interfaces.allSatisfy({ Self.validName($0.name) && $0.addresses.count <= 64 }),
              physicalPaths.allSatisfy({ Self.validName($0.interface) && !$0.service.isEmpty &&
                  $0.service.utf8.count <= 128 && (1...64).contains($0.networks.count) }) else {
            throw ExternalError.limitExceeded
        }
        self.id = id; self.capturedAtUptime = capturedAtUptime; self.interfaces = interfaces
        self.physicalPaths = physicalPaths; self.routes = routes; self.observedDNSServers = observedDNSServers
    }
    public func checkFresh(now: TimeInterval) throws {
        guard now.isFinite, now >= capturedAtUptime, now - capturedAtUptime < 30 else { throw ExternalError.expired }
    }
    static func validName(_ text: String) -> Bool {
        (1...32).contains(text.utf8.count) && text.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45
        }
    }
    public var description: String { "ExternalObservation(<redacted>; read-only)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// Parser for the numeric IPv4 table emitted by the fixed native netstat invocation.
/// Unknown rows/columns are failures, not omissions. Scope and cloned-route flags survive.
public enum ExternalRouteTable {
    public static let maximumBytes = 2_097_152
    private static let knownFlags = Set("UGHRDMmdCXLS12Wc3BbIiYrg")
    public static func parse(_ data: Data) throws -> Set<ExternalRoute> {
        guard !data.isEmpty, data.count <= maximumBytes else { throw ExternalError.limitExceeded }
        guard let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" && $0 != "\r" }) else {
            throw ExternalError.malformedRoutes
        }
        var header: [String]?
        var internet = false
        var routes: Set<ExternalRoute> = []
        var rows = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            guard raw.utf8.count <= 1024 else { throw ExternalError.limitExceeded }
            let fields = raw.split(whereSeparator: \.isWhitespace).map(String.init)
            if fields.isEmpty || fields == ["Routing", "tables"] { continue }
            if fields == ["Internet:"] {
                guard !internet else { throw ExternalError.malformedRoutes }; internet = true; continue
            }
            if fields.first == "Destination" {
                guard internet, header == nil,
                      fields == ["Destination", "Gateway", "Flags", "Netif", "Expire"] ||
                      fields == ["Destination", "Gateway", "Flags", "Refs", "Use", "Netif", "Expire"] else {
                    throw ExternalError.malformedRoutes
                }
                header = fields; continue
            }
            guard let header, let interfaceIndex = header.firstIndex(of: "Netif"),
                  fields.count == header.count || fields.count == header.count - 1 else { throw ExternalError.malformedRoutes }
            rows += 1
            guard rows <= 8192 else { throw ExternalError.limitExceeded }
            guard ExternalObservation.validName(fields[interfaceIndex]), !fields[2].isEmpty,
                  fields[2].allSatisfy(knownFlags.contains),
                  validGateway(fields[1]) else { throw ExternalError.malformedRoutes }
            if interfaceIndex > 3 {
                guard fields[3..<interfaceIndex].allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { throw ExternalError.malformedRoutes }
            }
            if fields.count == header.count {
                guard fields.last!.allSatisfy(\.isNumber) else { throw ExternalError.malformedRoutes }
            }
            let destination = try numericDestination(fields[0], host: fields[2].contains("H"))
            routes.insert(.init(destination: destination, gateway: fields[1], interface: fields[interfaceIndex], flags: fields[2]))
        }
        guard header != nil, !routes.isEmpty else { throw ExternalError.malformedRoutes }
        return routes
    }
    private static func validGateway(_ text: String) -> Bool {
        if (try? IPv4Address(text)) != nil { return true }
        if text.hasPrefix("link#"), let index = UInt32(text.dropFirst(5)) {
            return index > 0 && text == "link#" + String(index)
        }
        // Numeric link-layer addresses, including unpadded octets, are not IP gateways.
        let octets = text.split(separator: ":", omittingEmptySubsequences: false)
        return octets.count == 6 && octets.allSatisfy { (1...2).contains($0.count) && UInt8($0, radix: 16) != nil }
    }
    private static func numericDestination(_ text: String, host: Bool) throws -> IPv4CIDR {
        do {
            if text == "default" { guard !host else { throw ExternalError.malformedRoutes }; return try IPv4CIDR("0.0.0.0/0") }
            let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count) else { throw ExternalError.malformedRoutes }
            let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            guard (1...4).contains(octets.count), !host || octets.count == 4 else { throw ExternalError.malformedRoutes }
            let address = try IPv4Address((octets.map(String.init) + Array(repeating: "0", count: 4 - octets.count)).joined(separator: "."))
            // Apple netname omits the suffix only for the address's classful mask.
            // Never infer /16 from an abbreviated class-C address such as 198.51.
            let first = address.rawValue >> 24
            let implicitPrefix = first < 128 ? 8 : (first < 192 ? 16 : 24)
            if parts.count == 1 && !host {
                guard octets.count == implicitPrefix / 8 else { throw ExternalError.malformedRoutes }
            }
            let prefixText = parts.count == 2 ? String(parts[1]) : String(host ? 32 : implicitPrefix)
            let cidr = try IPv4CIDR(address.description + "/" + prefixText)
            guard cidr.networkAddress == address, !host || cidr.prefixLength == 32 else { throw ExternalError.malformedRoutes }
            return cidr
        } catch { throw ExternalError.malformedRoutes }
    }
}
