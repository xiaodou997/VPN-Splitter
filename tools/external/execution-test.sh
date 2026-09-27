#!/bin/bash
# SPDX-License-Identifier: MIT
# Offline tests only; no real routing socket, root journal, or operator apply.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
swift test --package-path "$ROOT/Packages/ExternalExecution" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/ExternalExecution" -c release -Xswiftc -warnings-as-errors
python3 -m unittest discover -s "$ROOT/tests/external_execution" -v
