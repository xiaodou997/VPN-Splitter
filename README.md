# VPN Splitter

VPN Splitter is a macOS-first split-tunneling client and compatibility layer.

The project aims to provide one rule system for three VPN sources:

1. **WireGuard profiles** imported from `.conf`
2. **OpenVPN profiles** imported from `.ovpn`
3. **Existing third-party full-tunnel VPN applications**, without requiring their protocol implementation

## Target

- First supported platform: **macOS 26+**
- Windows: planned after the macOS architecture and rule model are stable
- Architecture: Apple Network Extension for managed tunnels; compatibility backends for external VPN applications

## Product model

A VPN source is treated as an **egress**, while the rule engine decides which traffic uses that egress.

Examples:

```text
*.company.internal  -> VPN
10.0.0.0/8          -> VPN
github.com           -> DIRECT
openai.com           -> DIRECT
default              -> DIRECT
```

The inverse mode is also supported conceptually:

```text
default              -> VPN
github.com           -> DIRECT
openai.com           -> DIRECT
```

## v0.1 scope

### Managed WireGuard

- Import WireGuard `.conf`
- Establish tunnel through Network Extension
- IPv4 routing rules
- Split DNS
- DIRECT / VPN policies
- Connection diagnostics

### Managed OpenVPN

- Import OpenVPN `.ovpn`
- Establish tunnel using an OpenVPN client core
- Support common certificate / username-password profiles
- Override full-tunnel routes with local split policy
- Split DNS
- Connection diagnostics

### External VPN compatibility

- Detect physical interface and gateway
- Detect VPN tunnel interface and route changes
- Detect DNS changes
- Identify common route-based full-tunnel patterns
- Apply compatible DIRECT/VPN exceptions without modifying the VPN application itself
- Restore state safely on disconnect, reconnect, sleep/wake, and network changes

External VPN support is capability-based rather than vendor-based. Some VPNs that enforce routing through Network Extension, content filters, MDM, or kill-switch mechanisms may not be splittable.

## Non-goals for v0.1

- Windows support
- Per-process / per-application rules
- Multiple simultaneously active managed VPN tunnels
- Reimplementing WireGuard or OpenVPN protocols from scratch
- Bypassing operating-system or enterprise-enforced security policies
- Executing arbitrary scripts embedded in imported OpenVPN profiles

## Documentation

- [v0.1 Requirements](docs/requirements-v0.1.md)
- [Architecture](docs/architecture.md)
- [Research & Reference Projects](docs/research.md)

## Status

**Design / technical spike stage.**

The first milestone is to validate three independent paths:

1. WireGuard `.conf` -> managed split tunnel
2. OpenVPN `.ovpn` -> managed split tunnel
3. Existing route-based full-tunnel VPN -> split routing without a VM

No production guarantees are made yet.
