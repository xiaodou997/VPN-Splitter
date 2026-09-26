// SPDX-License-Identifier: MIT
// TEST DOUBLE ONLY. No Apple API or system network access.
import Foundation
public enum NEVPNStatus { case invalid, disconnected, connecting, connected, reasserting, disconnecting }
public enum NEProviderStopReason { case userInitiated }
open class NEVPNProtocol { public init() {} }
open class NETunnelProviderProtocol: NEVPNProtocol {
    public var providerBundleIdentifier: String?
    public var providerConfiguration: [String: Any]?
    public var passwordReference: Data?
}
open class NEVPNConnection {
    public var status: NEVPNStatus = .disconnected
    public init() {}
}
open class NETunnelProviderSession: NEVPNConnection {
    public var submissions = 0
    public var submittedOptions: [String: NSObject]?
    public var failSubmission = false
    public func startTunnel(options: [String: NSObject]?) throws {
        submissions += 1
        if failSubmission { throw NSError(domain: "synthetic-sensitive-error", code: 99) }
        submittedOptions = options
    }
}
open class NETunnelProviderManager {
    public var isEnabled = true
    public var isOnDemandEnabled = false
    public var connection: NEVPNConnection = NETunnelProviderSession()
    public var protocolConfiguration: NEVPNProtocol?
    public init() {}
}
open class NEPacketTunnelProvider {
    public var protocolConfiguration: NEVPNProtocol = NETunnelProviderProtocol()
    public init() {}
    open func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {}
    open func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {}
}
