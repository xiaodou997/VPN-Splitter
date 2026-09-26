# ProviderSession

One in-process Provider attempt, not a simulator and not a NetworkExtension implementation.
`ProviderSessionController` owns loading, backend start, cancellation, draining and teardown
state. The real driver in `integrations/wireguard/ManagedWireGuardSession.swift` calls the
existing WireGuard Adapter; neither file is installed into the S1 Provider target yet.

The loader receives only a typed opaque identity. Prepared resources must do no network
work before `start`. A cancelled/expired load discards its late resource; a cancelled start
must settle before `stop` is submitted. A stop timeout reports `cleanupUnconfirmed`, never
successful OS rollback. A late stop can establish backend quiescence, but does not rewrite
an already completed timeout result. Every callback checks monotonic time, so delayed timer
execution cannot authorize expired results. User callbacks run on MainActor; loaders and
native drivers must not block it. Timeouts cannot forcibly terminate a blocked native call.

`running`/`backendReady` are backend completion, not handshake or egress evidence. After a
clean backend stop, the phase remains `awaitingSystemTeardown`. Only a matching observation
supplied separately by the host moves it to `closed`; the method is not an OS observer or
permission to rebuild. Every controller is single-use, including after `closed`. The host
must own exactly one active controller and retain it throughout pending native operations.
There is no global manager, automatic reconnection or hot configuration replacement.

No secret serialization, Keychain access, process execution or network APIs are present.
A UUID identity is not an authentication proof. The production credential source, authenticated
App/Provider channel, descriptor ownership, system observation and signed activation remain
separate work. Swift memory copies are not a zeroization guarantee.

```sh
swift test --package-path Packages/ProviderSession -Xswiftc -warnings-as-errors
swift test --package-path Packages/ProviderSession -c release -Xswiftc -warnings-as-errors
```

The existing `/bin/bash dev.sh engine-test` now includes both configurations. Tests use
explicit in-memory backends/manual deadlines plus a real task timer, never a real VPN.
