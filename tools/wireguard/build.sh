#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$ROOT/tools/wireguard/build.py" "$@"
