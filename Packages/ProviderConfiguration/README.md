# ProviderConfiguration / WG-INT-08D

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

08D reuses the existing AppCore WireGuard importer and PolicyCore at three real
call sites: before save, after authenticated loading/before stage, and after
Provider consumption. The first admission scope requires one Peer, IPv4 numeric
endpoint, no DNS fields, canonical Include rules inside AllowedIPs, and no explicit
endpoint/local/reserved-address conflicts. Invalid inputs fail, never get trimmed.
The sealed snapshot preserves original configuration bytes, including keys and
AllowedIPs; rule canonicalization does not rewrite protocol data. The private
planning context is not a runtime epoch; no installable plan is exposed.

This is NOT a working VPN. Native WireGuardKit configuration conversion, trusted
packet resources and the formal engine/network lifecycle are still missing.
Valid semantic input stops at engine blocker 2001. Semantic rejection is 2004,
metadata rejection 2002, missing delivery 2003, and old smoke remains 1001.
The local AppCore/PolicyCore dependencies and package deployment minimum now match
the existing macOS 26 product. No new remote dependency, entitlement or ACL change.
Code wiring is not native authentication or system-network acceptance evidence.

See ../../docs/adr/ADR-WG-INT-08C-authenticated-configuration-delivery.md and
../../docs/evidence/wg-int-08c-authenticated-configuration-delivery.md for executed
checks, changed permissions, remaining runtime work, and NOT RUN items.
Run `/bin/bash dev.sh provider-test` for offline regression in a complete checkout.
The new formal page belongs to the S1 Xcode project, not `dev.sh run` / LocalDev.

See ../../docs/adr/ADR-WG-INT-08D-material-admission.md and
../../docs/evidence/wg-int-08d-material-admission.md for this batch.
