# Pinned upstream test contracts (MIT)

These are unmodified source files from the existing locked revisions. The local
build verifies Git blob hashes before using them. Copyright/permission notices
remain here; project-owned fixture doubles do not replace native build sources.

- WireGuard/wireguard-apple, `2fec12a6e1f6e3460b6ee483aa00ad29cddadab1`:
  `Sources/Shared/Model/TunnelConfiguration+WgQuickConfig.swift`,
  `Sources/Shared/Model/String+ArrayConversion.swift`,
  `Sources/WireGuardKitGo/wireguard.h`, and `COPYING`.
- WireGuard/wireguard-go, `ecfc5a8d54462e18e13c72173e2623d16d8e25a0`:
  `tun/tun.go` and `LICENSE` (retained as `LICENSE-go`).

The parser and tun.Device contract are actual upstream source. Apple Network,
NetworkExtension, WireGuard value constructors/UAPI generation, 08D admission,
engine lifecycle and the plaintext echo engine are explicit TEST DOUBLES.
No handshake, encryption, operating-system TUN, Keychain, signing or networking
is exercised by this fixture environment. Production builds use the pinned full
WireGuard sources, not these doubles.
