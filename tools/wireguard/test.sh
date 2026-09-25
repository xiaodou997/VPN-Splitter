#!/bin/bash
# SPDX-License-Identifier: MIT
# Offline build-tool contracts only; does not download or compile a VPN engine.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
python3 -m unittest discover -s "$ROOT/tests/wireguard" -v
printf 'schema=wireguard-build-tool-tests-v1\ncontracts=PASS\nnative_compile_link=NOT_RUN\nnetwork_settings=NOT_APPLIED\n'
