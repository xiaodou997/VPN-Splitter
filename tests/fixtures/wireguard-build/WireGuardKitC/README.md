# WireGuardKitC header regression references

These four complete files are unmodified test references from the official
`WireGuard/wireguard-apple` revision `2fec12a6e1f6e3460b6ee483aa00ad29cddadab1`,
under `Sources/WireGuardKitC/`. They are not a vendored production engine.
The original copyright notices are retained. The upstream MIT license is in
`third-party/wireguard-apple/COPYING.reference` at the repository root.

`tests/wireguard/test_c_header.py` checks each Git blob before the tests. It
copies the files to temporary directories, adds the exact reviewed include to
one copy, and uses real Clang to check standalone/header-module compilation and
structure layout. Linux tests do not emulate or certify macOS SDK 27 modules.
No protocol code is compiled, linked or executed by these header tests.
