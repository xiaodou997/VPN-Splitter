#!/bin/bash
# SPDX-License-Identifier: MIT
# Pure rule/probe tests. No Network Extension activation or network changes.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
swift test --package-path "$ROOT/Packages/ExternalFlowWire" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/ExternalFlowWire" -c release -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/ExternalFlow" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/ExternalFlow" -c release -Xswiftc -warnings-as-errors
python3 -m unittest discover -s "$ROOT/tests/external_flow" -v
