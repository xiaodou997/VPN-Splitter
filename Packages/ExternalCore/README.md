# ExternalCore / EX-INT-01

Read-only third-party VPN route diagnostics and DIRECT-rule inspection. Reuses the
existing PolicyCore IPv4 types and first-match compiler with External/Bypass mode.
No permission to write routes, no Helper, no VPN engine and no credential access.
`ExternalPreview.canApply` is always false. Matching an existing route never grants
ownership or deletion rights. No automatic topology, secret or rule persistence.

The executable target is the separate macOS External development preview. Actual
service/interface reads and a fixed bounded numeric netstat invocation are wired to
explicit SwiftUI buttons. The portable tests use synthetic observations and do not
execute native observation or prove vendor compatibility. Unknown/malformed input,
ambiguous topology, protected ranges, existing/scoped route conflicts fail closed.

`dev.sh external-test` runs Debug/Release XCTest plus Python entry/source checks.
`dev.sh external-run` builds a local ad-hoc app and opens it; `external-build` does not
open it. Neither requires Go or developer signing. Existing LocalDev and WG are unchanged.
See ../../docs/external-development.md and the EX-INT-01 ADR/evidence for boundaries.
