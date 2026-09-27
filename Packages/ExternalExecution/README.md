# ExternalExecution / EX-INT-02

Finite foreground engineering executor for IPv4 DIRECT exceptions alongside an
existing route-based VPN. Uses the actual ExternalCore observer/planner and a
Darwin PF_ROUTE adapter; never the route command's exit status as a receipt.

Max 8 compiled /24–/32 routes, 2048 addresses and a nonrenewing 60-second lease.
Explicit operator root + TTY/APPLY, no automatic elevation, IPC or installed helper.
Unknown writes retain a private intent marker; old markers never recreate ownership.
Borrowed routes are never removed. Live receipts revoke on observed replacement;
BSD lacks atomic compare-delete, so concurrent privileged ABA/undetected event loss
remain limitations. This is NOT an all-environment ownership/recovery guarantee.

`dev.sh external-execution-test` is offline; `external-executor-build` only builds.
The old preview GUI stays read-only. See docs/external-execution.md and its ADR.
No production GUI helper, native traffic acceptance, full DNS audit or OpenVPN is
claimed. Code tests and native Mac compile/kernel behavior are separate evidence.
