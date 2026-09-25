# WireGuardSupport

Owned, Foundation/Dispatch-only support code for the isolated WireGuardKit candidate. It is not another simulation backend and does not create a Provider, socket, tunnel, route or credential store.

`SplitterSettingsCompletion` serializes a single request's callback and timeout. It is internal, not a general-purpose concurrent future: exactly one waiter is allowed, and the waiter must not block the callback delivery queue. A timeout does not cancel an OS settings request. The guarded Adapter must refuse reuse until its future Provider controller has completed and observed session teardown.

The native build copies the exact `SettingsCompletion.swift` source into its isolated WireGuardKit checkout, checking its locked Git blob first. Tests compile that same source here with Swift 6 warnings-as-errors, without a Go compiler or Apple SDK. This proves the helper's logic, not NetworkExtension integration or network recovery.

Run `/bin/bash dev.sh engine-test` from the repository root. Native compilation remains a separate, explicit `/bin/bash dev.sh engine --fetch` operation. See [ADR-015](../../docs/adr/ADR-015-settings-completion-and-dev-entry.md) and [evidence](../../docs/evidence/wireguard-engine-03.md).
