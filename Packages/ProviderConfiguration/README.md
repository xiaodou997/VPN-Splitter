# ProviderConfiguration / WG-INT-08C

Formal configuration selection, App-private Keychain records, and authenticated
App-to-system-extension delivery. The package now includes macOS-only Security,
NetworkExtension and XPC adapters as well as portable transaction/protocol logic.
It is no longer a Foundation-only metadata module.

The formal App UI explicitly reloads the selected NE profile, prepares an immutable
Keychain record, saves/reloads NE preferences, and separately authorizes delivery.
A real XPC hello authenticates the peer BEFORE Keychain loading. The signed App
then stages one bounded, short-lived envelope, rechecks selection, and submits
metadata-only NE options. The actual Provider consumes only the matching stage.
NSXPC code-signing requirements pin exact roles and Team; UID comes from the kernel.
A UUID or persistent reference alone never authenticates either endpoint.

The dedicated App Group is for the Mach service only. Keychain uses the containing
App's OWN signed application identifier, never that shared group. No extension
Keychain reader, LocalDev ACL change, secret file, or provider-message fallback.
One selected profile, a cooperative user writer lease, explicit cancellation,
unknown-save retention, bounded connection/attempt counts and monotonic expiry are
implemented. There is no OS-level CAS or durable orphan-record garbage collection.

This is NOT a working VPN. Received materials remain unvalidated runtime drafts and
are discarded at the Provider's explicit engine blocker (2001). Metadata rejection
is 2002; missing/expired/mismatched delivery is 2003. Old smoke remains 1001.
Code wiring is not native authentication or system-network acceptance evidence.

See ../../docs/adr/ADR-WG-INT-08C-authenticated-configuration-delivery.md and
../../docs/evidence/wg-int-08c-authenticated-configuration-delivery.md for executed
checks, changed permissions, remaining runtime work, and NOT RUN items.
Run `/bin/bash dev.sh provider-test` for offline regression in a complete checkout.
The new formal page belongs to the S1 Xcode project, not `dev.sh run` / LocalDev.
