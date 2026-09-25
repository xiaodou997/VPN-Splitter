#!/bin/bash
# SPDX-License-Identifier: MIT
# Build only. Never installs/activates an extension, saves a VPN profile, or invokes sudo.
set -euo pipefail
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
mode=${1:-preflight}
case "$mode" in preflight|unsigned|development|developer-id) ;; *) echo 'Usage: build.sh preflight|unsigned|development|developer-id' >&2; exit 64;; esac
[[ $# -le 1 ]] || exit 64
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo 'Requires an arm64 Mac.' >&2; exit 69; }
[[ $EUID != 0 ]] || { echo 'Do not run with sudo/root.' >&2; exit 77; }
root=$(cd "$(dirname "$0")/../.." && pwd -P)
version=$(/usr/bin/sw_vers -productVersion); major=${version%%.*}
[[ $major =~ ^[0-9]+$ ]] && (( major >= 26 )) || { echo 'Requires macOS 26+.' >&2; exit 69; }
for dir in "$root/.local" "$root/.local/s1"; do
  [[ ! -L $dir ]] || exit 73
  [[ -e $dir ]] || mkdir -m 700 "$dir"
  [[ -d $dir && -O $dir && $(stat -f '%Lp' "$dir") == 700 ]] || { echo 'Local output directory must be owned, non-symlink, mode 700.' >&2; exit 73; }
done
out=$(mktemp -d "$root/.local/s1/$mode.XXXXXX")
echo 'PRIVATE BUILD LOGS: review before sharing. No credentials belong here.' > "$out/PRIVATE.txt"
finish() {
  local code=$?
  trap - EXIT
  printf 'schema=s1-build-v1\nmode=%s\nexit_code=%s\nnetwork_settings=NOT_APPLIED\nextension_activation=NOT_REQUESTED\n' "$mode" "$code" > "$out/share-summary.txt"
  cat "$out/share-summary.txt"
  printf 'Local results: %s\n' "$out"
  exit "$code"
}
trap finish EXIT
{
  /usr/bin/sw_vers
  /usr/bin/uname -m
  /usr/bin/xcode-select -p
  /usr/bin/xcodebuild -version
  /usr/bin/xcrun --sdk macosx --show-sdk-version
  /usr/bin/xcrun swift --version
} > "$out/toolchain.private.txt" 2>&1
sdk=$(/usr/bin/xcrun --sdk macosx --show-sdk-version); sdk_major=${sdk%%.*}
[[ $sdk_major =~ ^[0-9]+$ ]] && (( sdk_major >= 26 )) || { echo 'Select a full Xcode with macOS SDK 26+.' >&2; exit 69; }
if [[ $mode == preflight ]]; then
  /usr/bin/xcodebuild -list -project "$root/apps/macos/VPN-Splitter.xcodeproj" > "$out/project-list.private.txt" 2>&1
  exit 0
fi
args=()
config=Debug
case "$mode" in
  unsigned) args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO);;
  development|developer-id)
    local_config="$root/apps/macos/Config/Signing.local.xcconfig"
    [[ -f $local_config && ! -L $local_config ]] || { echo 'Create Config/Signing.local.xcconfig from the example first.' >&2; exit 78; }
    team=$(awk -F '=' '/^[[:space:]]*VPN_DEVELOPMENT_TEAM[[:space:]]*=/ {v=$2;gsub(/[[:space:]]/,"",v);n++} END {if(n==1) print v}' "$local_config")
    [[ $team =~ ^[A-Z0-9]{10}$ && $team != YOURTEAMID ]] || { echo 'Set a real 10-character VPN_DEVELOPMENT_TEAM locally.' >&2; exit 78; }
    if [[ $mode == developer-id ]]; then config=DeveloperID; fi
    # Account/profile creation is intentionally NOT enabled via -allowProvisioningUpdates.
    ;;
esac
set +e
/usr/bin/xcodebuild -project "$root/apps/macos/VPN-Splitter.xcodeproj" -scheme VPN-Splitter \
  -configuration "$config" -destination 'generic/platform=macOS' \
  -derivedDataPath "$out/DerivedData" -disableAutomaticPackageResolution \
  "${args[@]}" build > "$out/build.private.log" 2>&1
code=$?
set -e
if (( code != 0 )); then echo 'Build failed. Inspect build.private.log locally; share only relevant error lines.' >&2; exit "$code"; fi
app="$out/DerivedData/Build/Products/$config/VPN-Splitter.app"
if [[ $mode == unsigned ]]; then
  echo 'Unsigned compile succeeded. Do not install or activate this artifact.'
else
  /usr/bin/xcrun python3 "$root/tools/s1/verify-bundle.py" "$app" "$mode" > "$out/signing-summary.txt"
  cat "$out/signing-summary.txt"
fi
printf 'Built artifact (not installed): %s\n' "$app"
