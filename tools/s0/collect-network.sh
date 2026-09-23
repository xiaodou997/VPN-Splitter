#!/bin/bash
# SPDX-License-Identifier: MIT
# S0 development tool only. No route/DNS writes, probes or credential reads.
# Sourceable for synthetic tests; direct execution always checks the platform.

s0_usage() {
    printf '%s\n' 'Usage: /bin/bash tools/s0/collect-network.sh before|after|reverted [IPv4 ...]' \
        'Collect local network state; at most 16 numeric IPv4 targets, no hostnames.' \
        'Raw output stays in .local/s0/ and is PRIVATE, NOT anonymized.' \
        'Only share-summary.txt contains allowlisted, address-free hints.' \
        'No sudo. No traffic probes. Labels do not prove the VPN state.'
}

s0_ipv4() {
    local value=$1 part
    local -a parts
    [[ $value =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a parts <<< "$value"
    for part in "${parts[@]}"; do
        [[ ${#part} -le 3 ]] || return 1
        [[ $part == 0 || $part != 0* ]] || return 1
        (( 10#$part <= 255 )) || return 1
    done
}

s0_private_dir() {
    local directory=$1
    [[ ! -L $directory ]] || return 1
    if [[ ! -e $directory ]]; then /bin/mkdir -m 700 "$directory" || return 1; fi
    [[ -d $directory && -O $directory ]] || return 1
    # Existing directories must already be private; never chmod user data.
    [[ $(/usr/bin/stat -f '%Lp' "$directory" 2>/dev/null) == 700 ]]
}

s0_abort() {
    if [[ -n ${S0_CHILD:-} ]]; then
        kill -TERM "$S0_CHILD" 2>/dev/null || :
        /bin/sleep 1
        kill -KILL "$S0_CHILD" 2>/dev/null || :
        wait "$S0_CHILD" 2>/dev/null || :
        S0_CHILD=
    fi
    if [[ -n ${S0_OUT:-} ]]; then
        printf '%s\n' 'INTERRUPTED' >| "$S0_OUT/capture-state.txt" || return 74
    fi
}

s0_capture() {
    local name=$1 result=OK code=0 started timed_out=0
    shift
    [[ $name =~ ^[a-z][a-z0-9_]*$ && $1 == /* ]] || return 64
    if [[ ! -x $1 ]]; then
        result=UNAVAILABLE; code=127
        : > "$S0_OUT/$name.txt" || return 74
        : > "$S0_OUT/$name.stderr.txt" || return 74
    else
        # Bound output size as well as time. Platform block units may differ.
        (ulimit -f 2048 || exit 70; exec "$@" </dev/null) \
            > "$S0_OUT/$name.txt" 2> "$S0_OUT/$name.stderr.txt" &
        S0_CHILD=$!; started=$SECONDS
        while kill -0 "$S0_CHILD" 2>/dev/null; do
            if (( SECONDS - started >= S0_TIMEOUT )); then
                timed_out=1
                kill -TERM "$S0_CHILD" 2>/dev/null || :
                /bin/sleep 1
                kill -KILL "$S0_CHILD" 2>/dev/null || :
                break
            fi
            /bin/sleep 1
        done
        wait "$S0_CHILD" 2>/dev/null || code=$?
        S0_CHILD=
        if (( timed_out )); then result=TIMEOUT; code=124
        elif (( code != 0 )); then result=FAILED
        fi
    fi
    [[ $result == OK ]] || S0_FAILURES=$((S0_FAILURES + 1))
    printf '%s\t%s\t%s\n' "$name" "$result" "$code" >> "$S0_OUT/commands.tsv" || return 74
}

s0_collect_all() {
    local index=0 target
    s0_capture os /usr/bin/sw_vers || return
    s0_capture architecture /usr/bin/uname -m || return
    s0_capture interfaces /sbin/ifconfig -a || return
    s0_capture routes_v4 /usr/sbin/netstat -rn -f inet || return
    s0_capture routes_v6 /usr/sbin/netstat -rn -f inet6 || return
    s0_capture default_v4 /sbin/route -n get -inet default || return
    s0_capture default_v6 /sbin/route -n get -inet6 default || return
    s0_capture nwi /usr/sbin/scutil --nwi || return
    s0_capture dns /usr/sbin/scutil --dns || return
    s0_capture proxy /usr/sbin/scutil --proxy || return
    s0_capture vpn_services /usr/sbin/scutil --nc list || return
    s0_capture extensions /usr/bin/systemextensionsctl list || return
    s0_capture hardware_ports /usr/sbin/networksetup -listallhardwareports || return
    for target in "$@"; do
        index=$((index + 1))
        s0_capture "target_$index" /sbin/route -n get -inet "$target" || return
    done
}

s0_summary() {
    local phase=$1 parser=$2 routes_result
    printf '%s\n' 'schema=s0-summary-v1' "phase=$phase" \
        "capture_failed_commands=$S0_FAILURES" 'network_mutations=NONE' \
        'traffic_probes=NOT_RUN' 'raw_files=PRIVATE_NOT_REDACTED' \
        'snapshot_consistency=SEQUENTIAL_NON_ATOMIC' || return 74
    routes_result=$(/usr/bin/awk -F '\t' '$1 == "routes_v4" { print $2 }' "$S0_OUT/commands.tsv") || return 74
    if [[ $routes_result == OK ]]; then
        /usr/bin/awk -f "$parser" "$S0_OUT/routes_v4.txt"
    else
        printf '%s\n' 'ipv4_full_tunnel_hint=UNKNOWN' 'compatibility=UNKNOWN' 'actual_egress=NOT_TESTED'
    fi
}

s0_main() {
    set -u
    set -o pipefail
    set -o noclobber
    umask 077
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
    local phase=${1:-} target script_dir root version major
    if [[ $phase == --help || $phase == -h ]]; then s0_usage; return 0; fi
    case $phase in before|after|reverted) ;; *) s0_usage >&2; return 64 ;; esac
    shift
    (( $# <= 16 )) || { printf 'Too many targets.\n' >&2; return 64; }
    for target in "$@"; do
        s0_ipv4 "$target" || { printf 'Targets must be canonical numeric IPv4 addresses.\n' >&2; return 64; }
    done
    [[ $(/usr/bin/uname -s) == Darwin ]] || { printf 'Capture requires macOS; no snapshot created.\n' >&2; return 69; }
    (( EUID != 0 )) || { printf 'Do not run this tool with sudo/root.\n' >&2; return 77; }
    [[ $(/usr/bin/uname -m) == arm64 ]] || { printf 'S0 baseline requires arm64.\n' >&2; return 69; }
    version=$(/usr/bin/sw_vers -productVersion) || return 69
    major=${version%%.*}
    [[ $major =~ ^[0-9]+$ && ${#major} -le 3 ]] || return 69
    (( 10#$major >= 26 )) || { printf 'S0 baseline requires macOS 26+.\n' >&2; return 69; }
    script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 73
    root=$(CDPATH= cd -- "$script_dir/../.." && pwd -P) || return 73
    [[ -f $script_dir/route-hints.awk ]] || return 66
    s0_private_dir "$root/.local" && s0_private_dir "$root/.local/s0" || {
        printf 'Unsafe .local directory: use a private, owned, non-symlink directory with mode 700.\n' >&2
        return 73
    }
    S0_OUT=$(/usr/bin/mktemp -d "$root/.local/s0/$phase.XXXXXX") || return 73
    S0_CHILD=; S0_TIMEOUT=10; S0_FAILURES=0
    trap 's0_abort; exit 130' INT
    trap 's0_abort; exit 143' TERM HUP
    trap 's0_abort' EXIT
    printf '%s\n' IN_PROGRESS > "$S0_OUT/capture-state.txt" || return 74
    printf 'name\tresult\texit_code\n' > "$S0_OUT/commands.tsv" || return 74
    /bin/date -u '+%Y-%m-%dT%H:%M:%SZ' > "$S0_OUT/started-utc.txt" || return 74
    printf '%s\n' 'PRIVATE: contains network identifiers; not anonymized. Do not upload raw files.' > "$S0_OUT/PRIVATE.txt" || return 74
    s0_collect_all "$@" || return 74
    s0_summary "$phase" "$script_dir/route-hints.awk" > "$S0_OUT/share-summary.txt" || return 74
    /bin/date -u '+%Y-%m-%dT%H:%M:%SZ' > "$S0_OUT/finished-utc.txt" || return 74
    if (( S0_FAILURES )); then
        printf '%s\n' PARTIAL >| "$S0_OUT/capture-state.txt" || return 74
    else
        printf '%s\n' CAPTURED >| "$S0_OUT/capture-state.txt" || return 74
    fi
    trap - EXIT INT TERM HUP
    printf 'Private snapshot: %s\n' "$S0_OUT"
    /bin/cat "$S0_OUT/share-summary.txt"
    printf '%s\n' 'Only share-summary.txt is address-free. Raw files require manual review and redaction.'
    (( S0_FAILURES == 0 )) || return 2
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then s0_main "$@"; fi
