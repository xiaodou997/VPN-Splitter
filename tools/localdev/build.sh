#!/bin/bash
# SPDX-License-Identifier: MIT
# Ordinary local app only; never build or activate the signing-spike extension.
set -euo pipefail
umask 077
MODE=${1:-build}
finish() {
    local code=$?
    printf 'schema=localdev-build-v1\nmode=%s\nexit_code=%s\nnetwork_settings=NOT_APPLIED\nextension_activation=NOT_REQUESTED\n' "$MODE" "$code"
}
trap finish EXIT
case "$MODE" in
    build|run) ;;
    *) echo "Usage: /bin/bash tools/localdev/build.sh [build|run]" >&2; exit 2 ;;
esac
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ]]; then
    echo "LocalDev app requires an Apple Silicon Mac with macOS 26+ and full Xcode." >&2
    exit 2
fi
VERSION=$(/usr/bin/sw_vers -productVersion)
if [[ ${VERSION%%.*} -lt 26 ]]; then
    echo "macOS 26+ is required." >&2; exit 2
fi
OUT="$ROOT/.local/localdev"
PROJECT="$ROOT/apps/macos/LocalDev/VPN-Splitter-LocalDev.xcodeproj"
APP="$OUT/DerivedData/Build/Products/Debug/VPN-Splitter-LocalDev.app"
mkdir -p "$OUT"
if ! /usr/bin/xcodebuild -project "$PROJECT" -scheme VPN-Splitter-LocalDev \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$OUT/DerivedData" build \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    CODE_SIGN_ENTITLEMENTS= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    PROVISIONING_PROFILE= PROVISIONING_PROFILE_SPECIFIER= \
    > "$OUT/build.log" 2>&1; then
    tail -n 60 "$OUT/build.log" >&2
    echo "Build failed; local log: $OUT/build.log" >&2
    exit 1
fi
if [[ -d "$APP/Contents/Library/SystemExtensions" || -d "$APP/Contents/PlugIns" ]]; then
    echo "Unexpected embedded extension; refusing to open." >&2; exit 3
fi
/usr/bin/codesign --verify --strict "$APP"
/usr/bin/codesign -dvv "$APP" 2> "$OUT/signature.txt"
if ! grep -q '^Signature=adhoc$' "$OUT/signature.txt"; then
    echo "Expected ad-hoc local signature; refusing to open." >&2; exit 3
fi
printf 'LocalDev app: %s\n' "$APP"
if [[ "$MODE" == run ]]; then
    /usr/bin/open "$APP"
    echo "Open requested. Confirm the LocalDev banner in the window; this is not a UI test result."
fi
