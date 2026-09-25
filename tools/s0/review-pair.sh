#!/bin/bash
# SPDX-License-Identifier: MIT
# Offline review of existing private S0 snapshots, not a route authorizer.

pair_usage() {
    printf '%s\n' 'Usage: /bin/bash tools/s0/review-pair.sh [before.XXXXXX after.XXXXXX]' \
        'With no arguments, requires exactly one before and one after snapshot.' \
        'Reads existing local files only. No sudo, probes, capture or network writes.' \
        'Only the generated share-summary.txt is suitable for sharing.'
}
pair_error() { printf '%s\n' "$1" >&2; return "${2:-65}"; }
pair_mode() {
    case $PAIR_OS in
        Darwin) /usr/bin/stat -f '%Lp' "$1" 2>/dev/null ;;
        Linux) /usr/bin/stat -c '%a' "$1" 2>/dev/null ;;
        *) return 1 ;;
    esac
}
pair_dir() { [[ -d $1 && ! -L $1 && -O $1 && $(pair_mode "$1") == 700 ]]; }
pair_file() {
    local size
    [[ -f $1 && ! -L $1 && -r $1 && -O $1 && $(pair_mode "$1") == 600 ]] || return 1
    size=$(/usr/bin/wc -c < "$1") || return 1
    (( size <= 4194304 ))
}
pair_field() {
    /usr/bin/awk -F '=' -v key="$2" '$1==key { n++; value=$2 } END { if(n==1) print value; else exit 1 }' "$1"
}
pair_validate() {
    local dir=$1 phase=$2 f stamp begin end
    pair_dir "$dir" || return 1
    for f in capture-state.txt commands.tsv share-summary.txt started-utc.txt finished-utc.txt \
        routes_v4.txt default_v4.txt interfaces.txt hardware_ports.txt dns.txt proxy.txt extensions.txt os.txt architecture.txt; do
        pair_file "$dir/$f" || return 1
    done
    [[ $(/bin/cat "$dir/capture-state.txt") == CAPTURED ]] || return 1
    [[ $(pair_field "$dir/share-summary.txt" schema) == s0-summary-v1 &&
       $(pair_field "$dir/share-summary.txt" phase) == "$phase" &&
       $(pair_field "$dir/share-summary.txt" capture_failed_commands) == 0 ]] || return 1
    /usr/bin/awk -F '\t' '
        BEGIN { n=split("os architecture interfaces routes_v4 routes_v6 default_v4 default_v6 nwi dns proxy vpn_services extensions hardware_ports", a, " "); for(i=1;i<=n;i++) required[a[i]]=1 }
        NR==1 { if($0!="name\tresult\texit_code") bad=1; next }
        { if(NF!=3 || $2!="OK" || $3!="0" || seen[$1]++) bad=1
          if(!($1 in required) && $1!~/^target_([1-9]|1[0-6])$/) bad=1 }
        END { for(k in required) if(seen[k]!=1) bad=1; exit bad }
    ' "$dir/commands.tsv" || return 1
    begin=$(/bin/cat "$dir/started-utc.txt"); end=$(/bin/cat "$dir/finished-utc.txt")
    for stamp in "$begin" "$end"; do
        [[ $stamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
    done
    [[ $begin < $end || $begin == "$end" ]]
}
pair_lookup() {
    /usr/bin/awk -v gw="$2" -v iface="$3" '
        $1=="gateway:" { g++; actualGW=$2 }
        $1=="interface:" { i++; actualIF=$2 }
        $1=="flags:" { f++; if($0~/[<,]UP[,>]/ && $0!~/REJECT|BLACKHOLE|IFSCOPE/) flagsOK=1 }
        END { if(g==1 && i==1 && f==1 && flagsOK && actualGW==gw && actualIF==iface) print "MATCH"; else print "DIFFERENT_OR_UNKNOWN" }
    ' "$1"
}
pair_interface() {
    /usr/bin/awk -v iface="$2" '
        /^[^ \t]/ { on=($1==iface ":"); if(on) { count++; if($0~/[<,]UP[,>]/) up++ } }
        on && $1=="status:" && $2=="active" { active++ }
        on && $1=="inet" { ip++ }
        END { if(count==1 && up==1 && active==1 && ip>0) print "ACTIVE_IPV4"; else print "UNKNOWN_OR_INACTIVE" }
    ' "$1"
}
pair_addresses() {
    /usr/bin/awk -v iface="$2" '/^[^ \t]/ { on=($1==iface ":") } on && $1=="inet" { print $0 }' "$1" | /usr/bin/sort
}
pair_hardware() {
    /usr/bin/awk -v iface="$2" '$1=="Device:" && $2==iface { n++ } END { if(n==1) print "LISTED"; else print "UNKNOWN" }' "$1"
}
pair_compare() {
    local code=0
    /usr/bin/cmp -s "$1" "$2" || code=$?
    case $code in 0) printf 'IDENTICAL_TEXT\n' ;; 1) printf 'CHANGED_TEXT\n' ;; *) printf 'UNKNOWN\n' ;; esac
}
pair_main() {
    set -u
    set -o pipefail
    set -o noclobber
    umask 077
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
    local script_dir root base b a d out f gw iface field b_end a_start
    local path_ok=1 b_lookup=UNKNOWN a_lookup=UNKNOWN activity=UNKNOWN mapping=UNKNOWN addresses=UNKNOWN
    local platform=UNKNOWN extensions=UNKNOWN readiness=REVIEW_REQUIRED
    local -a before_dirs after_dirs
    case ${1:-} in --help|-h) pair_usage; return 0 ;; esac
    [[ $# == 0 || $# == 2 ]] || { pair_usage >&2; return 64; }
    PAIR_OS=$(/usr/bin/uname -s)
    [[ $PAIR_OS == Darwin || $PAIR_OS == Linux ]] || return 69
    script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 73
    root=$(CDPATH= cd -- "$script_dir/../.." && pwd -P) || return 73
    base=$root/.local/s0
    pair_dir "$root/.local" && pair_dir "$base" || { pair_error 'Private snapshot directories must be owned, non-symlink and mode 700.' 73; return $?; }
    if [[ $# == 0 ]]; then
        shopt -s nullglob
        before_dirs=("$base"/before.*); after_dirs=("$base"/after.*)
        [[ ${#before_dirs[@]} == 1 && ${#after_dirs[@]} == 1 ]] || {
            pair_error 'No unique pair. Pass the exact before.XXXXXX and after.XXXXXX basenames; do not delete older snapshots.' 64; return $?;
        }
        b=${before_dirs[0]##*/}; a=${after_dirs[0]##*/}
    else b=$1; a=$2
    fi
    [[ $b =~ ^before\.[A-Za-z0-9]{6}$ && $a =~ ^after\.[A-Za-z0-9]{6}$ ]] || {
        pair_error 'Invalid snapshot basename or phase order.' 64; return $?;
    }
    b=$base/$b; a=$base/$a
    pair_validate "$b" before && pair_validate "$a" after || {
        pair_error 'Snapshot incomplete, unsafe, or unsupported. Inspect original commands.tsv locally; do not change its status to force acceptance.'; return $?;
    }
    b_end=$(/bin/cat "$b/finished-utc.txt"); a_start=$(/bin/cat "$a/started-utc.txt")
    [[ $b_end < $a_start || $b_end == "$a_start" ]] || { pair_error 'Snapshot time intervals overlap or are reversed.'; return $?; }
    [[ -r $script_dir/pair-paths.awk ]] || return 66
    out=$(/usr/bin/mktemp -d "$base/pair-review.XXXXXX") || return 73
    : > "$out/path-candidates.private.tsv" || return 74
    /usr/bin/awk -v details="$out/path-candidates.private.tsv" -f "$script_dir/pair-paths.awk" \
        "$b/routes_v4.txt" "$a/routes_v4.txt" > "$out/path-summary.txt" || return 74
    iface=$(/usr/bin/awk -F '\t' '$1=="physical_interface" { print $2 }' "$out/path-candidates.private.tsv")
    gw=$(/usr/bin/awk -F '\t' '$1=="physical_gateway" { print $2 }' "$out/path-candidates.private.tsv")
    if [[ -n $iface && -n $gw ]]; then
        b_lookup=$(pair_lookup "$b/default_v4.txt" "$gw" "$iface")
        a_lookup=$(pair_lookup "$a/default_v4.txt" "$gw" "$iface")
        if [[ $(pair_interface "$b/interfaces.txt" "$iface") == ACTIVE_IPV4 &&
              $(pair_interface "$a/interfaces.txt" "$iface") == ACTIVE_IPV4 ]]; then activity=ACTIVE_BOTH; fi
        if [[ $(pair_hardware "$b/hardware_ports.txt" "$iface") == LISTED &&
              $(pair_hardware "$a/hardware_ports.txt" "$iface") == LISTED ]]; then mapping=LISTED_BOTH; fi
        if [[ $activity == ACTIVE_BOTH ]]; then
            addresses=CHANGED
            [[ $(pair_addresses "$b/interfaces.txt" "$iface") == "$(pair_addresses "$a/interfaces.txt" "$iface")" ]] && addresses=UNCHANGED
        fi
    fi
    if /usr/bin/cmp -s "$b/os.txt" "$a/os.txt" && /usr/bin/cmp -s "$b/architecture.txt" "$a/architecture.txt"; then
        platform=IDENTICAL_RECORDED_VALUES
    else platform=DIFFERENT_OR_UNKNOWN
    fi
    extensions=$(/usr/bin/awk '/^[[:space:]]*[0-9]+ extension\(s\)/ { n++; v=$1 } END {
        if(n!=1) print "UNKNOWN"; else if(v+0>0) print "PRESENT_REVIEW_LOCALLY"; else print "NONE_LISTED_NOT_PROOF_OF_ABSENCE" }
    ' "$a/extensions.txt") || return 74
    for field in 'physical_default_before=UNIQUE' 'physical_default_continuity=MATCH' \
        'vpn_ipv4_default_pair=SINGLE_PAIR' 'other_ipv4_tunnel_routes=NONE_OBSERVED'; do
        /usr/bin/grep -Fxq "$field" "$out/path-summary.txt" || path_ok=0
    done
    if [[ $path_ok == 1 && $b_lookup == MATCH && $a_lookup == MATCH && $activity == ACTIVE_BOTH &&
          $mapping == LISTED_BOTH && $addresses == UNCHANGED && $platform == IDENTICAL_RECORDED_VALUES ]]; then
        readiness=CANDIDATE_REQUIRES_LIVE_PREFLIGHT
    fi
    {
        printf '%s\n' 'schema=s0-pair-review-v1' 'input_pair=VALID_CAPTURE_FILES' \
            "recorded_platform=$platform" 'same_machine=USER_MUST_CONFIRM' 'snapshot_freshness=NOT_ASSERTED'
        /bin/cat "$out/path-summary.txt"
        printf '%s\n' "default_lookup_before=$b_lookup" "default_lookup_after=$a_lookup" \
            "physical_interface_activity=$activity" "physical_hardware_mapping=$mapping" "physical_ipv4_addresses=$addresses" \
            "dns_snapshot=$(pair_compare "$b/dns.txt" "$a/dns.txt")" "proxy_snapshot=$(pair_compare "$b/proxy.txt" "$a/proxy.txt")" \
            "network_extensions_after=$extensions" "pair_readiness=$readiness" \
            'network_mutations=NONE' 'traffic_probes=NOT_RUN' 'live_state=NOT_CHECKED' \
            'gateway_reachability=NOT_TESTED' 'enforcement=UNDETERMINED' 'compatibility=UNKNOWN' 'actual_egress=NOT_TESTED'
    } > "$out/share-summary.txt" || return 74
    printf '%s\n' 'PRIVATE: numeric path candidates only; not commands, not authorization, not current state.' \
        'Check the locally documented S0-03 procedure before any privileged operation.' > "$out/PRIVATE.txt" || return 74
    /bin/cat "$out/share-summary.txt"
    printf '\nLocal review directory: %s\n' "$out"
    printf '%s\n' 'Share only share-summary.txt. Keep path-candidates.private.tsv local. No network state has changed.'
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then pair_main "$@"; fi
