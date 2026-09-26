#!/bin/bash
# SPDX-License-Identifier: MIT
# No real Keychain, XPC, VPN preferences, engine sockets, or network settings.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
swift test --package-path "$ROOT/Packages/ProviderSession" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/ProviderSession" -c release -Xswiftc -warnings-as-errors
python3 -m unittest discover -s "$ROOT/tests/provider_runtime" -v
