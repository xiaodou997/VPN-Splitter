# VPN Splitter v0.1 Requirements

Status: Draft  
Platform: macOS 26+  
Last updated: 2026-09-23

## 1. Goal

VPN Splitter provides a unified split-tunneling policy layer for:

- WireGuard profiles imported from `.conf`
- OpenVPN profiles imported from `.ovpn`
- Existing third-party full-tunnel VPN applications

The product separates **how a VPN tunnel is created** from **how traffic is selected for that tunnel**.

## 2. Core concepts

### 2.1 Egress

An egress is a network path that traffic can use.

Initial egress types:

- `DIRECT`: primary physical network
- `VPN`: active managed or external VPN tunnel
- `REJECT`: deny traffic

Future egress types may include:

- named WireGuard/OpenVPN profiles
- HTTP/SOCKS proxies
- mihomo proxy groups
- multiple simultaneous VPN tunnels

### 2.2 Policy modes

#### Include mode

Default traffic is DIRECT. Explicit rules enter the VPN.

Typical corporate use case:

```text
*.company.internal -> VPN
10.0.0.0/8         -> VPN
default             -> DIRECT
```

#### Bypass mode

Default traffic enters the VPN. Explicit rules bypass it.

Typical third-party full-tunnel use case:

```text
github.com -> DIRECT
openai.com -> DIRECT
default    -> VPN
```

## 3. v0.1 functional requirements

### 3.1 WireGuard managed mode

- Import standard WireGuard `.conf`
- Parse Interface and Peer sections
- Store secrets securely in macOS Keychain
- Establish a tunnel using Apple Network Extension
- Preserve peer reachability semantics while allowing local split-routing policy
- Support IPv4 CIDR routing
- Support domain-based rules through DNS resolution / split DNS policy
- Expose connect, disconnect, reconnect, and status
- Provide diagnostics

### 3.2 OpenVPN managed mode

- Import common `.ovpn` client profiles
- Support TCP and UDP transports
- Support embedded and referenced CA/certificate/key material
- Support username/password authentication
- Support common TLS authentication/encryption directives
- Read server-pushed routes and DNS settings
- Allow local policy to reject/override a pushed full-tunnel route
- Support IPv4 routing and split DNS
- Do not execute arbitrary `up`, `down`, `plugin`, or shell directives in v0.1

The exact OpenVPN profile compatibility matrix will be frozen after the OpenVPN technical spike.

### 3.3 External VPN compatibility mode

VPN Splitter does not authenticate or establish the third-party VPN.

It must:

- detect the primary physical interface
- detect the physical gateway
- detect newly created tunnel interfaces
- diff routing tables before/after VPN activation
- detect DNS changes
- identify common full-tunnel patterns, including:
  - default route replacement
  - `0.0.0.0/1` + `128.0.0.0/1`
  - host routes that keep the VPN server reachable through the physical gateway
- classify the VPN's compatibility level
- apply split rules only when the selected backend is known to be safe
- restore owned changes on disconnect
- reconcile after VPN reconnect, DHCP renew, network switch, sleep, and wake

External mode must not:

- inject code into another VPN process
- patch or modify the third-party application
- copy credentials from the third-party application
- claim support where an enforced system/MDM policy prevents split tunneling

### 3.4 Rules

Required v0.1 rule types:

- DOMAIN
- DOMAIN-SUFFIX
- IP-CIDR
- IP-CIDR6: parser may exist, full IPv6 support may remain experimental
- MATCH/default

Required actions:

- DIRECT
- VPN
- REJECT

Rule ordering must be deterministic and diagnosable.

### 3.5 DNS

Managed tunnels must support split DNS.

Requirements:

- VPN-only resolver domains
- system/default resolver for non-VPN domains
- DNS state restoration on disconnect
- diagnostic output showing which resolver was selected

External mode may initially preserve the third-party VPN DNS configuration if safe split DNS cannot be guaranteed. This behavior must be visible to the user.

### 3.6 Diagnostics

Diagnostics are part of v0.1, not a later support feature.

Minimum report:

- physical interface / address / gateway
- tunnel interface / address
- current default route
- detected full-tunnel mechanism
- DNS resolvers
- rule match result for a hostname/IP
- selected egress
- connection state
- compatibility warnings
- sanitized logs

Secrets must never be included in diagnostics.

## 4. Reliability requirements

The product must handle:

- VPN reconnect
- tunnel interface number changes
- Wi-Fi reconnect
- Wi-Fi <-> Ethernet switch
- DHCP renew
- sleep / wake
- DNS changes
- app restart while VPN is already active

No configuration may assume a fixed `utunN` interface name.

## 5. Security requirements

- Private keys, passwords, preshared keys, and sensitive credentials: macOS Keychain
- Imported configuration files are parsed as untrusted input
- No arbitrary shell execution from VPN profiles
- Logs must redact secrets
- Privileged components expose the smallest possible API surface
- External mode changes must be reversible and tracked by ownership

## 6. macOS 26+ baseline

v0.1 intentionally supports macOS 26 and newer only.

This allows the project to:

- use current Network Extension behavior as the compatibility baseline
- avoid legacy kernel-extension implementations
- use current Swift / SwiftUI / System Extension APIs
- test explicitly against macOS 26 networking behavior rather than carrying historical compatibility branches

The CI/build baseline and exact Xcode/Swift versions will be frozen separately after the first runnable Network Extension spike.

## 7. Deferred features

- Windows
- per-process rules
- per-app rules
- multi-VPN concurrent routing
- HTTP/SOCKS egress
- mihomo provider import/export
- kill switch
- complete IPv6 parity
- App Store distribution decision
- automatic update channel

## 8. v0.1 acceptance criteria

v0.1 is technically viable when all three spikes pass:

1. A WireGuard profile connects and only selected traffic enters the tunnel.
2. An OpenVPN profile connects and a server-requested full tunnel can be converted to local split policy.
3. A compatible route-based third-party full-tunnel VPN can be split without a VM, and state survives reconnect/sleep/wake tests.

These are technical viability gates, not final product-release criteria.
