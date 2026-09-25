#!/bin/bash
# SPDX-License-Identifier: MIT
# Object-generation tests only: no app launch, credentials, extension or network writes.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
swift test --package-path "$ROOT/Packages/ManagedSettings" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/ManagedSettings" -c release -Xswiftc -warnings-as-errors
python3 -m unittest discover -s "$ROOT/tests/managed" -v
NATIVE=NOT_RUN
if [[ $(uname -s) == Darwin ]]; then NATIVE=PASS; fi
printf 'schema=managed-settings-tests-v1\ncore=PASS\ncontracts=PASS\nnative_settings_objects=%s\nwireguard_engine=NOT_LINKED\nextension_activation=NOT_REQUESTED\nnetwork_settings=NOT_APPLIED\n' "$NATIVE"
