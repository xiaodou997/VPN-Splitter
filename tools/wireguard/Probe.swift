// SPDX-License-Identifier: MIT
import ManagedSettings
import ManagedSettingsApple
import NetworkExtension
import WireGuardKit

// Compile-time API probe only. Never called by this executable. This is NOT a
// production binding: a live controller must derive fresh input from the actual
// session and verify protocol/configuration identity at every settings request.
@MainActor
func checkPolicyInjectionSignature(provider: NEPacketTunnelProvider,
                                   draft: ManagedSettingsDraft,
                                   current: SettingsInput) -> WireGuardAdapter {
    WireGuardAdapter(with: provider, networkSettingsProvider: { _ in
        try PacketTunnelSettingsFactory.makeForInspection(draft, current: current)
    }, logHandler: { _, _ in
        // No raw engine, endpoint or credential logging in this probe.
    })
}

// The build script never runs this executable. Even when launched manually,
// there is no Adapter instance, Provider activation, configuration or tunnel.
print("WGLinkProbe: build-only artifact; no VPN has been started.")
