// SPDX-License-Identifier: MIT
import Foundation
import NetworkExtension
import ProviderConfiguration
import os

// A system extension is a daemon-style executable, not an .appex entry point.
autoreleasepool {
    PacketTunnelProvider.log.notice("S1_EXTENSION_PROCESS_STARTED")
    NEProvider.startSystemExtensionMode()
}
Task { @MainActor in
    do {
        try ManagedExtensionRuntime.install()
        PacketTunnelProvider.log.notice("MANAGED_XPC_LISTENER_READY network_settings=NOT_APPLIED")
    } catch {
        // Leave smoke diagnostics available; never install an unauthenticated fallback.
        PacketTunnelProvider.log.notice("MANAGED_XPC_LISTENER_UNAVAILABLE network_settings=NOT_APPLIED")
    }
}
dispatchMain()
