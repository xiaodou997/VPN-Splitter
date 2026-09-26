# ProviderConfiguration / WG-INT-08A

Strict public launch metadata for the formal App and PacketTunnelProvider. Foundation
only; no keys, raw WireGuard configuration, filesystem, Keychain, DNS or network I/O.

The property-list schema correlates profile ID, credential ID, policy revision,
generation, first-milestone scope and app attempt. The persistent reference travels
only in `NETunnelProviderProtocol.passwordReference`. Its bytes are not a credential
and possession is not authorization. `CheckedManagedLaunch` is deliberately named
metadata-only and redacts reflection/debug output.

This module rejects unknown keys/types/versions, non-canonical IDs/generations,
missing/oversized references, wrong Provider and mixed profile revisions. It does
NOT prove signed sender identity, latest persisted generation, Keychain ownership,
anti-replay across processes, or trusted utun ownership. An authorized credential
source must validate the complete record before WG-INT-07 configuration delivery.
The v1 scope tag declares the intended single-peer IPv4 Include contract; it does
not validate the absent configuration's peer count, addresses or routes.

The formal Provider uses the real boundary, but still refuses execution after a
valid request because credential resolution and the native runtime are not wired.
No new Connect UI is exposed and LocalDev stays network-free.

Run `/bin/bash dev.sh provider-test`. This is not an Apple SDK or live VPN test.
