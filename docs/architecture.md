# Architecture

Status: Proposed  
Platform baseline: macOS 26+

## 1. Design principle

VPN Splitter treats a tunnel as an **egress**, not as the policy engine.

Three different VPN sources should converge into one rule model:

```text
                   Rule Engine
                       |
          +------------+------------+
          |                         |
       DIRECT                      VPN
          |                         |
   Physical network      +----------+----------+
                         |                     |
                  Managed Tunnel       External Tunnel
                    /       \                |
               WireGuard   OpenVPN      Third-party VPN
```

## 2. Major subsystems

### App

Native macOS application responsible for:

- profile management
- rules
- status
- diagnostics
- user consent flows
- settings

Preferred implementation: Swift / SwiftUI.

### Core policy model

Responsible for:

- profile-independent rule representation
- route policy compilation
- DNS policy compilation
- compatibility decisions
- state machine
- diagnostics model

Implementation language remains open until the technical spikes confirm FFI boundaries. Rust is a candidate for portable core logic; Apple-specific networking remains Swift.

### Managed tunnel layer

Uses Apple Network Extension.

```text
Main App
   |
NETunnelProviderManager
   |
NEPacketTunnelProvider
   +-- WireGuard backend
   +-- OpenVPN backend
```

Managed tunnels should use `NEPacketTunnelNetworkSettings` for:

- tunnel addresses
- included routes
- excluded routes
- DNS settings
- MTU

### WireGuard backend

Primary reference: official WireGuard Apple implementation / WireGuardKit.

Responsibilities:

- parse WireGuard configuration
- initialize WireGuard backend
- map local policy into Network Extension routing
- report tunnel statistics / state

### OpenVPN backend

Candidate engine: OpenVPN 3 Core.

Responsibilities:

- parse/import OpenVPN profiles
- establish protocol session
- expose pushed route/DNS data to policy layer
- prevent a pushed full-tunnel policy from bypassing local policy decisions
- map tunnel packets to Network Extension

Exact integration strategy is a Spike decision.

### External VPN adapter

External mode treats an already-running third-party VPN as a discovered egress.

Detection inputs:

- interfaces
- route table
- primary network path
- DNS state
- system/network extensions where observable
- active process metadata where useful

Compatibility classification:

```text
L1  route-only
L2  route + DNS
L3  filter / kill-switch / special enforcement suspected
L4  enforced system/MDM routing; split may be unavailable
```

### External routing backends

#### Route override backend

Best first backend for route-based full-tunnel clients.

Example:

```text
VPN installs:
0.0.0.0/1   -> utun
128.0.0.0/1 -> utun

VPN Splitter installs:
selected-public-ip/32 -> physical gateway
```

This backend must own, reconcile, and remove only routes it created.

#### Scoped/transparent proxy backend

Research backend for cases where flow-level or application-level routing is required.

This is not the v0.1 foundation until macOS 26 behavior is validated. Existing open-source VPN clients have encountered macOS 26-specific split-tunnel/DNS issues.

## 3. DNS architecture

### Managed tunnel

Use Network Extension DNS settings and split domains.

```text
*.company.internal -> VPN DNS
everything else    -> system/default DNS
```

### External tunnel

Detect before/after DNS state.

Initial strategies:

1. preserve third-party VPN DNS
2. restore physical DNS for selected direct domains where safe
3. later introduce a local DNS dispatcher if required

DNS policy must be independently diagnosable from packet routing.

## 4. State machine

```text
IDLE
  |
DETECTING / PREPARING
  |
CONNECTING
  |
APPLYING_POLICY
  |
CONNECTED
  |
NETWORK_CHANGED
  |
RECONCILING
  |
CONNECTED
```

Failure transitions must restore owned system state.

## 5. Privilege model

Managed tunnels rely on Network Extension/System Extension entitlements.

External route operations may require a narrow privileged helper.

Principles:

- no repeated ad-hoc sudo commands in production
- smallest command surface
- caller identity validation
- no generic shell execution
- operation journal for rollback

The exact helper technology will be frozen after the External VPN spike.

## 6. Configuration model

Conceptual profile:

```yaml
name: Company VPN
source:
  type: wireguard | openvpn | external

policy:
  default: DIRECT

rules:
  - DOMAIN-SUFFIX,company.internal,VPN
  - IP-CIDR,10.0.0.0/8,VPN
  - DOMAIN-SUFFIX,github.com,DIRECT
  - MATCH,DIRECT
```

The user-facing rule language may intentionally resemble mihomo, but internal storage must use a typed representation rather than raw strings.

## 7. Project structure candidate

```text
VPN-Splitter/
├── app-macos/
│   ├── App/
│   └── Extensions/
├── core/
│   ├── policy/
│   ├── diagnostics/
│   └── state/
├── tunnels/
│   ├── wireguard/
│   └── openvpn/
├── external/
│   ├── detection/
│   ├── routes/
│   └── dns/
├── docs/
└── tests/
```

Do not freeze this tree until the three technical spikes establish real build boundaries.

## 8. Key architectural decisions still open

- Swift-only core vs Rust portable policy core
- OpenVPN 3 Core vs another actively maintained OpenVPN integration
- App Store vs Developer ID distribution
- route helper implementation and signing model
- exact external VPN compatibility backend priority
- IPv6 scope for v0.1
- rule-provider / mihomo interoperability format
