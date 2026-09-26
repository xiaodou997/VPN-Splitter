# ProviderConfiguration / WG-INT-08A + 08B

`ManagedLaunch` is the strict, Foundation-only public metadata boundary shared by
the formal App and PacketTunnelProvider. Its unchanged property-list schema carries
profile/credential/policy identifiers, generation, scope and attempt, not secrets.
A persistent reference is metadata, not authorization, freshness or tunnel ownership.
The scope tag does not validate the actual WireGuard configuration or policy.

WG-INT-08B adds the containing App's private credential source:

- `ManagedCredentialVault` is an actor for immutable prepare/read-back/load/revoke
  and exact-receipt cleanup retry. Configuration and policy archives share one bound
  Keychain record. `load(for:selected:)` checks WG-INT-08A metadata against the selected
  App handle before reading. It does not establish that selection as the latest one.
- `ManagedAppKeychain` is a macOS-only Security implementation, created explicitly
  with `forContainingApp(expectedBundleIdentifier:)`. It uses data-protection Keychain,
  a dedicated service, non-synchronizable unlocked/device-only items and noninteractive
  authentication context. No shared access group, file-based fallback, broad deletion,
  silent overwrite or LocalDev permission change is provided.
- Secret values and references have redacted descriptions/reflection. Materials are
  bounded, not semantically validated or guaranteed zeroized. Cleanup tickets are
  in-memory only; durable crash/orphan reconciliation remains unimplemented.

This is APP-LOCAL, not a system-extension credential reader or an authenticated IPC
format. Apple distinguishes user-context data-protection Keychain from daemon access;
see [ADR-WG-INT-08B](../../docs/adr/ADR-WG-INT-08B-app-credential-vault.md).
The containing App's actual entitlements/signing and native Keychain behavior still
need Mac verification. A bundle ID/UID comparison is not cryptographic authentication.

The formal GUI does not yet invoke the vault. The Provider still rejects valid
metadata with 2001 because credential delivery and the native runtime are not wired.
LocalDev remains unchanged. Preparing/revoking a credential does not create/stop a
VPN, publish a current selection, or prove system route/DNS restoration.

Run `/bin/bash dev.sh provider-test`. Tests never invoke real Keychain operations,
save VPN preferences or change network settings. Native query-construction tests
compile only on macOS; they are not Security authorization or live VPN acceptance.
Execution counts and remaining gaps: [08B evidence](../../docs/evidence/wg-int-08b-app-credential-vault.md).
