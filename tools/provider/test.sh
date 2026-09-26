#!/bin/bash
# SPDX-License-Identifier: MIT
# Offline only: no preferences, Keychain, signed extension, or network changes.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
swift test --package-path "$ROOT/Packages/ProviderConfiguration" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/ProviderConfiguration" -c release -Xswiftc -warnings-as-errors
python3 -m unittest discover -s "$ROOT/tests/provider" -v
