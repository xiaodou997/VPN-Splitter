#!/bin/bash
# SPDX-License-Identifier: MIT
# Offline regression only: no app launch, live Keychain access, or network changes.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
swift test --package-path "$ROOT/Packages/AppCore" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/AppCore" -c release -Xswiftc -warnings-as-errors
python3 -m unittest discover -s "$ROOT/tests/localdev" -v
printf 'schema=localdev-tests-v1\ncore=PASS\ncontracts=PASS\nmac_gui=NOT_RUN\nlive_keychain=NOT_RUN\nnetwork_settings=NOT_APPLIED\n'
