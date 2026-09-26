// SPDX-License-Identifier: MIT
import ManagedSettings
import ManagedSettingsApple
import NetworkExtension
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

// The build script never runs this executable. No descriptor is discovered here.
print("WGLinkProbe: build-only artifact; no VPN has been started.")
