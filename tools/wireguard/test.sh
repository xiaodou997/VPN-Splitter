#!/bin/bash
# SPDX-License-Identifier: MIT
# Own concurrency helper and build-tool tests only; never starts a VPN engine.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
swift test --package-path "$ROOT/Packages/WireGuardSupport" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/WireGuardSupport" -c release -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/ProviderSession" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/ProviderSession" -c release -Xswiftc -warnings-as-errors
python3 -m unittest discover -s "$ROOT/tests/wireguard" -v
python3 -m unittest discover -s "$ROOT/tests/dev" -v
printf 'schema=wireguard-build-tool-tests-v3\nsettings_completion=PASS\nprovider_session=PASS\ncontracts=PASS\nnative_compile_link=NOT_RUN\nnetwork_settings=NOT_APPLIED\n'
