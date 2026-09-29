#!/bin/bash
# SPDX-License-Identifier: MIT
# No system service, native network IO or privileges; all route inputs are synthetic.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
swift test --package-path "$ROOT/Packages/ExternalControl" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/ExternalControl" -c release -Xswiftc -warnings-as-errors
python3 -m unittest discover -s "$ROOT/tests/external_helper" -v
