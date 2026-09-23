# Research & Reference Projects

Status: Active research

This document lists projects to study for architecture and behavior. They are references, not dependencies by default.

## 1. WireGuard Apple

Repository: `WireGuard/wireguard-apple` (official repository is hosted at git.zx2c4.com)

Study for:

- WireGuardKit integration
- Network Extension tunnel lifecycle
- WireGuard configuration model
- Go bridge build integration
- Apple signing/capability layout

Potential use: direct dependency/reference implementation.

License must be verified before distribution decisions.

## 2. OpenVPN 3

Repository: `OpenVPN/openvpn3`

Study for:

- modern OpenVPN client core
- `.ovpn` parsing
- client connection lifecycle
- server-pushed routes and DNS
- macOS utun support
- embedding API boundaries

OpenVPN 3 is used by OpenVPN Connect clients and supports macOS.

Important: licensing must be reviewed before selecting it as a shipping dependency. Upstream documents MPL-2.0 / AGPL-3.0 licensing choices.

## 3. Passepartout / Partout

Repositories:

- `partout-io/passepartout`
- `partout-io/partout`

Study for:

- production Apple VPN app structure
- OpenVPN + WireGuard coexistence
- custom routing
- Network Extension integration
- profile import
- DNS and on-demand behavior
- modern Swift/Xcode organization

Passepartout currently targets modern Apple platforms and is useful as a product-architecture reference.

Partout licensing must be reviewed before dependency use.

## 4. VPN-Bypass

Repository: `GeiserX/VPN-Bypass`

Study for:

- detecting third-party VPN types
- discovering physical gateways
- route-based bypass
- privileged helper design
- route verification
- reconnect/reapply behavior

This is the closest reference to VPN Splitter's External VPN mode.

Do not copy architecture blindly: VPN Splitter also owns managed WireGuard/OpenVPN tunnels and targets macOS 26+ specifically.

## 5. PIA mac-split-tunnel / PIA desktop

Repositories:

- `pia-foss/mac-split-tunnel`
- `pia-foss/desktop`

Study for:

- Transparent Proxy based split tunneling
- system extension packaging
- app/extension lifecycle
- flow-level bypass
- diagnostics
- DNS restoration
- sleep/wake behavior

Important macOS 26 lesson:

PIA has shipped macOS 26-specific fixes and has reports involving split-tunnel proxy behavior and DNS restoration. Therefore Transparent Proxy is a research backend, not an assumed v0.1 foundation.

## 6. Tailscale

Repository: `tailscale/tailscale`

Study selectively for:

- userspace WireGuard architecture
- macOS Network Extension edge cases
- route and local-address handling
- diagnostics and state reconciliation

Tailscale solves a broader problem than VPN Splitter, so use it for specific implementation patterns rather than overall product architecture.

## 7. Apple Network Extension documentation

Primary APIs to validate against macOS 26+:

- `NEPacketTunnelProvider`
- `NEPacketTunnelNetworkSettings`
- `NEIPv4Settings.includedRoutes`
- `NEIPv4Settings.excludedRoutes`
- `NEDNSSettings.matchDomains`
- Network Extension entitlements
- System Extension packaging

Key behavior to account for:

- included/excluded routes can define split tunnel destinations
- system routes can supersede ordinary included/excluded routes
- scoped connections can supersede system routing in ordinary cases
- `enforceRoutes` changes precedence and can supersede app scoping
- `includeAllNetworks` is a different full-tunnel enforcement mode

This precedence model is critical to External VPN compatibility detection.

## 8. Research spikes

### Spike A — WireGuard managed tunnel

Goal:

- import a real `.conf`
- establish a Network Extension tunnel
- send only a test CIDR through WireGuard
- verify DNS and reconnect behavior

Exit criteria:

- direct public traffic remains direct
- selected VPN traffic succeeds
- sleep/wake reconnect works on macOS 26

### Spike B — OpenVPN managed tunnel

Goal:

- import a real `.ovpn`
- establish a tunnel
- observe pushed routes/DNS
- suppress/replace full-tunnel routing with local split policy

Exit criteria:

- profile authenticates successfully
- selected corporate route works
- public traffic remains direct
- pushed DNS behavior is understood

### Spike C — External full-tunnel VPN

Goal:

- run an existing third-party full-tunnel VPN
- detect the physical and tunnel paths
- bypass one controlled public destination without a VM
- restore all owned changes

Initial test case:

- route-based OpenVPN-style `0/1 + 128/1` full tunnel

Exit criteria:

- bypass survives VPN reconnect
- bypass survives sleep/wake
- no stale routes after disconnect
- diagnostics correctly explain selected egress

## 9. Dependency policy

For every candidate dependency record:

- upstream URL
- exact license
- whether code will be linked, vendored, forked, or used only as reference
- macOS 26 test status
- maintenance activity
- security update process
- notarization/signing implications

No dependency becomes foundational before this record exists.
