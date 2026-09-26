// SPDX-License-Identifier: MIT
import ManagedSettings
import ManagedSettingsApple
import NetworkExtension
import PolicyCore
import WireGuardKit

// Compile-time API probe, never called. Live callers must establish that the
// approved configuration, policy input and Provider descriptor belong together.
// The revision/input closures must read current controller state, not a constant.
@MainActor
func checkPolicyInjectionSignature(provider: NEPacketTunnelProvider,
                                   configuration: TunnelConfiguration,
                                   revision: SplitterRuntimeRevision,
                                   currentRevision: @escaping () -> SplitterRuntimeRevision?,
                                   descriptor: @escaping () throws -> SplitterTunnelDescriptorLease,
                                   draft: ManagedSettingsDraft,
                                   current: @escaping () -> SettingsInput) -> WireGuardAdapter {
    let binding = SplitterWireGuardBinding(configuration: configuration, revision: revision,
                                          currentRevision: currentRevision)
    return WireGuardAdapter(with: provider, runtimeBinding: binding,
        tunnelDescriptorProvider: descriptor, networkSettingsProvider: { _ in
            try PacketTunnelSettingsFactory.makeForInspection(draft, current: current())
        }, logHandler: { _, _ in
            // No raw engine, endpoint or credential logging in this probe.
        })
}

// This second API check exercises the real configuration-to-policy assembly.
// It is also uncalled: compilation cannot become a VPN start or a Keychain read.
@MainActor
func checkAssembledPolicySignature(provider: NEPacketTunnelProvider,
                                  configuration: TunnelConfiguration, policy: IPv4Policy,
                                  underlay: IPv4ConstraintInput, dns: WireGuardDNSSelection,
                                  revision: SplitterRuntimeRevision,
                                  currentRevision: @escaping () -> SplitterRuntimeRevision?,
                                  descriptor: @escaping () throws -> SplitterTunnelDescriptorLease) throws -> ManagedWireGuardAssembly {
    try ManagedWireGuardAssembly.prepareForIntegration(provider: provider, configuration: configuration,
        policy: policy, underlay: underlay, dnsSelection: dns, revision: revision,
        currentRevision: currentRevision, descriptor: descriptor)
}

// The build script never runs this executable. No descriptor is discovered here.
print("WGLinkProbe: build-only artifact; no VPN has been started.")
