#!/bin/bash
# SPDX-License-Identifier: MIT
# Synthetic/offline only; never invokes native network collection or opens the app.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
swift test --package-path "$ROOT/Packages/ExternalCore" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/ExternalCore" -c release -Xswiftc -warnings-as-errors
python3 -m unittest discover -s "$ROOT/tests/external" -v
