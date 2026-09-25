#!/bin/bash
# SPDX-License-Identifier: MIT
# S0 local preparation only. Writes private files, never routes/DNS; no probes.

pf_usage() {
    printf '%s\n' 'Usage: /bin/bash tools/s0/preflight-target.sh [D_IPV4 V_IPV4]' \
        'D: authorized public test service to bypass. V: different VPN control service.' \
        'No arguments: ask locally. Keep the original VPN connected.' \
        'No sudo, active probes, credential reads, or network configuration changes.'
}
pf_address() {
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    /usr/bin/awk -v value="$1" -v kind="$2" 'BEGIN {
        n=split(value,a,"."); if(n!=4) exit 1
        for(i=1;i<=4;i++) if(a[i]!~/^[0-9]+$/ || length(a[i])>3 ||
            (length(a[i])>1 && substr(a[i],1,1)=="0") || a[i]+0>255) exit 1
        if(a[1]==0 || a[1]==127 || a[1]>=224 || (a[1]==169 && a[2]==254)) exit 1
        if(kind=="D" && (a[1]==10 || (a[1]==100 && a[2]>=64 && a[2]<=127) ||
            (a[1]==172 && a[2]>=16 && a[2]<=31) || (a[1]==192 && a[2]==168) ||
            (a[1]==192 && a[2]==0 && (a[3]==0 || a[3]==2)) ||
            (a[1]==192 && a[2]==88 && a[3]==99) ||
            (a[1]==198 && (a[2]==18 || a[2]==19 || (a[2]==51 && a[3]==100))) ||
            (a[1]==203 && a[2]==0 && a[3]==113))) exit 1
    }'
}
pf_field() {
    /usr/bin/awk -F '=' -v key="$2" '$1==key { n++; v=$2 } END { if(n==1 && NF>=1) print v; else exit 1 }' "$1"
}
pf_paths() {
    # Private stdout: only validated tokens. Reject ambiguous active IPv4 tunnels.
    /usr/bin/awk '
        function ip(s,a,n,i) {
            n=split(s,a,"."); if(n!=4) return 0
            for(i=1;i<=4;i++) if(a[i]!~/^[0-9]+$/ || length(a[i])>3 || a[i]+0>255 ||
                (length(a[i])>1 && substr(a[i],1,1)=="0")) return 0
            return 1
        }
        $1=="Destination" { headers++; for(i=1;i<=NF;i++) if($i=="Netif") col=i; next }
        !headers || !NF { next }
        { if(col<4 || NF<col) { bad=1; next }; rows++
          d=$1; g=$2; f=$3; dev=$col
          if(f!~/U/ || f~/[IRB]/) next
          if(d=="default" || d=="0.0.0.0/0") {
              if(dev~/^en[0-9]+$/ && f~/G/ && ip(g)) { p++; pg=g; pi=dev }
              else bad=1
          }
          if(dev!~/^utun[0-9]+$/) next
          tunnels[dev]=1
          if(d=="0/1" || d=="0.0.0.0/1") { lo++; lg=g; li=dev }
          if(d=="128.0/1" || d=="128.0.0.0/1") { hi++; hg=g; he=dev }
        }
        END {
            for(k in tunnels) nt++
            if(headers!=1 || !rows || bad || p!=1 || lo!=1 || hi!=1 || nt!=1 ||
                lg!=hg || li!=he || !ip(lg)) exit 1
            print "physical_interface=" pi; print "physical_gateway=" pg
            print "vpn_interface=" li; print "vpn_gateway=" lg
        }' "$1"
}
pf_lookup() {
    /usr/bin/awk -v dev="$2" -v gateway="$3" -v onlink="$4" '
        $1=="gateway:" { g++; gw=$2 }
        $1=="interface:" { i++; iface=$2 }
        $1=="flags:" { f++; ok=($0~/[<,]UP[,>]/ && $0!~/REJECT|BLACKHOLE/ && (onlink=="yes" || $0!~/IFSCOPE/))
            routed=($0~/[<,]GATEWAY[,>]/) }
        END { exit !(i==1 && f==1 && ok && iface==dev &&
            (onlink=="yes" ? !routed : (g==1 && gw==gateway))) }
    ' "$1"
}
pf_interface() {
    /usr/bin/awk -v dev="$2" '
        /^[^ \t]/ { on=($1==dev ":"); if(on) { n++; if($0~/[<,]UP[,>]/) up++ } }
        on && $1=="status:" && $2=="active" { active++ }
        on && $1=="inet" { ips++ }
        END { exit !(n==1 && up==1 && active==1 && ips>0) }' "$1"
}
pf_no_host_route() {
    /usr/bin/awk -v target="$2" '
        $1=="Destination" { header++; for(i=1;i<=NF;i++) if($i=="Netif") col=i; next }
        !header || !NF { next }
        { if(col<4 || NF<col) bad=1
          if($1==target || $1==target "/32") found=1 }
        END { exit !(header==1 && col>=4 && !bad && !found) }' "$1"
}
pf_not_infrastructure() {
    # Conservatively block DNS servers, interface addresses and all next-hop IPv4s.
    /usr/bin/awk -v target="$4" '
        FILENAME==ARGV[1] && $1~/^nameserver\[[0-9]+\]$/ && $3==target { found=1 }
        FILENAME==ARGV[2] && $1=="inet" && $2==target { found=1 }
        FILENAME==ARGV[3] && $2==target { found=1 }
        END { exit found }' "$1" "$2" "$3"
}
pf_check() {
    # Synthetic-testable decision; every result is a fixed enum, never input text.
    local dir=$1 d=$2 v=$3 pi pg vi vg bad=0 result
    pi=$(pf_field "$dir/paths_start.private.txt" physical_interface) || return 65
    pg=$(pf_field "$dir/paths_start.private.txt" physical_gateway) || return 65
    vi=$(pf_field "$dir/paths_start.private.txt" vpn_interface) || return 65
    vg=$(pf_field "$dir/paths_start.private.txt" vpn_gateway) || return 65
    result=CHANGED_OR_UNKNOWN
    if pf_paths "$dir/routes_end.txt" > "$dir/paths_end.private.txt" &&
        /usr/bin/cmp -s "$dir/paths_start.private.txt" "$dir/paths_end.private.txt"; then result=MATCH; else bad=1; fi
    printf 'live_path_continuity=%s\n' "$result"
    result=UNKNOWN_OR_INACTIVE
    if pf_interface "$dir/interfaces.txt" "$pi" && /usr/bin/awk -v dev="$pi" \
        '$1=="Device:" && $2==dev { n++ } END { exit n!=1 }' "$dir/hardware.txt"; then result=ACTIVE_LISTED; else bad=1; fi
    printf 'physical_interface=%s\n' "$result"
    result=DIFFERENT_OR_UNKNOWN
    if pf_lookup "$dir/default.txt" "$pi" "$pg" no; then result=MATCH; else bad=1; fi
    printf 'physical_default_lookup=%s\n' "$result"
    result=NOT_CONFIRMED
    if pf_lookup "$dir/gateway.txt" "$pi" '' yes; then result=ON_LINK_ROUTE_OBSERVED; else bad=1; fi
    printf 'gateway_path=%s\n' "$result"
    result=NOT_CONFIRMED
    if pf_lookup "$dir/target_d.txt" "$vi" "$vg" no; then result=VPN_ROUTE_OBSERVED; else bad=1; fi
    printf 'direct_target_baseline=%s\n' "$result"
    result=NOT_CONFIRMED
    # V may have a tunnel-specific gateway different from the /1 gateway.
    if /usr/bin/awk -v dev="$vi" '$1=="interface:" { n++; ok=($2==dev) }
        $1=="flags:" { f++; up=($0~/[<,]UP[,>]/ && $0!~/REJECT|BLACKHOLE|IFSCOPE/) }
        END { exit !(n==1 && ok && f==1 && up) }' "$dir/target_v.txt"; then result=VPN_ROUTE_OBSERVED; else bad=1; fi
    printf 'vpn_control_baseline=%s\n' "$result"
    result=EXISTS_OR_UNKNOWN
    if pf_no_host_route "$dir/routes_start.txt" "$d" && pf_no_host_route "$dir/routes_end.txt" "$d"; then result=NONE_OBSERVED; else bad=1; fi
    printf 'direct_target_existing_host_route=%s\n' "$result"
    result=MATCH_OR_UNKNOWN
    if pf_not_infrastructure "$dir/dns.txt" "$dir/interfaces.txt" "$dir/routes_start.txt" "$d" &&
        pf_not_infrastructure "$dir/dns.txt" "$dir/interfaces.txt" "$dir/routes_end.txt" "$d"; then result=NONE_IN_CHECKED_FIELDS; else bad=1; fi
    printf 'direct_target_infrastructure_match=%s\n' "$result"
    if (( bad )); then printf 'preflight_readiness=BLOCKED\n'; return 2; fi
    printf 'preflight_readiness=MANUAL_EXPERIMENT_CANDIDATE\n'
}
pf_main() {
    set -u; set -o pipefail; set -o noclobber; umask 077
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
    local d=${1:-} v=${2:-} answer script_dir root pi pg vi vg status=0 major
    case $d in --help|-h) pf_usage; return 0 ;; esac
    [[ $# == 0 || $# == 2 ]] || { pf_usage >&2; return 64; }
    [[ $(/usr/bin/uname -s) == Darwin && $(/usr/bin/uname -m) == arm64 ]] || {
        printf 'Requires a macOS arm64 test machine.\n' >&2; return 69; }
    (( EUID != 0 )) || { printf 'Do not run with sudo/root.\n' >&2; return 77; }
    major=$(/usr/bin/sw_vers -productVersion) || return 69; major=${major%%.*}
    [[ $major =~ ^[0-9]{1,3}$ ]] && (( 10#$major >= 26 )) || return 69
    [[ -t 0 ]] || { printf 'Use a local interactive terminal.\n' >&2; return 64; }
    if [[ $# == 0 ]]; then
        read -r -p 'D: authorized public test IPv4 to bypass: ' d || return 64
        read -r -p 'V: different IPv4 service that must remain on VPN: ' v || return 64
    fi
    pf_address "$d" D && pf_address "$v" V && [[ $d != "$v" ]] || {
        printf 'Invalid, disallowed or identical target addresses. No capture created.\n' >&2; return 64; }
    printf '%s\n' 'Confirm: same test Mac; original VPN connected; permitted split-routing experiment;' \
        'local console/recovery available; D is NOT a VPN endpoint, DNS server, gateway,' \
        'remote-control path or other infrastructure; both services are authorized.' \
        'Review installed extensions locally. Do not disable enforcement to make this pass.'
    read -r -p 'Type PREPARE to perform READ-ONLY checks only: ' answer || return 64
    [[ $answer == PREPARE ]] || { printf 'Cancelled.\n'; return 0; }
    script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 73
    root=$(CDPATH= cd -- "$script_dir/../.." && pwd -P) || return 73
    source "$script_dir/collect-network.sh" || return 66
    s0_private_dir "$root/.local" && s0_private_dir "$root/.local/s0" || return 73
    S0_OUT=$(/usr/bin/mktemp -d "$root/.local/s0/preflight.XXXXXX") || return 73
    S0_TIMEOUT=10; S0_FAILURES=0; S0_CHILD=
    trap 's0_abort; exit 130' INT; trap 's0_abort; exit 143' TERM HUP; trap 's0_abort' EXIT
    printf 'IN_PROGRESS\n' > "$S0_OUT/capture-state.txt" || return 74
    printf 'name\tresult\texit_code\n' > "$S0_OUT/commands.tsv" || return 74
    /bin/date -u '+%Y-%m-%dT%H:%M:%SZ' > "$S0_OUT/started-utc.txt" || return 74
    printf 'PRIVATE: not redacted. No network changes or active probes.\n' > "$S0_OUT/PRIVATE.txt" || return 74
    s0_capture routes_start /usr/sbin/netstat -rn -f inet || return 74
    if (( S0_FAILURES )) || ! pf_paths "$S0_OUT/routes_start.txt" > "$S0_OUT/paths_start.private.txt"; then
        printf 'Current route candidates are not unique; stop and inspect locally.\n' >&2; return 65
    fi
    pi=$(pf_field "$S0_OUT/paths_start.private.txt" physical_interface) || return 65
    pg=$(pf_field "$S0_OUT/paths_start.private.txt" physical_gateway) || return 65
    vi=$(pf_field "$S0_OUT/paths_start.private.txt" vpn_interface) || return 65
    vg=$(pf_field "$S0_OUT/paths_start.private.txt" vpn_gateway) || return 65
    s0_capture os /usr/bin/sw_vers || return 74
    s0_capture interfaces /sbin/ifconfig -a || return 74
    s0_capture hardware /usr/sbin/networksetup -listallhardwareports || return 74
    s0_capture default /sbin/route -n get -inet default || return 74
    s0_capture gateway /sbin/route -n get -inet "$pg" || return 74
    s0_capture target_d /sbin/route -n get -inet "$d" || return 74
    s0_capture target_v /sbin/route -n get -inet "$v" || return 74
    s0_capture dns /usr/sbin/scutil --dns || return 74
    s0_capture proxy /usr/sbin/scutil --proxy || return 74
    s0_capture extensions /usr/bin/systemextensionsctl list || return 74
    s0_capture routes_end /usr/sbin/netstat -rn -f inet || return 74
    {
        printf '%s\n' 'schema=s0-target-preflight-v1' "capture_failed_commands=$S0_FAILURES"
        if (( S0_FAILURES )); then printf 'preflight_readiness=BLOCKED_CAPTURE\n'; status=2
        else pf_check "$S0_OUT" "$d" "$v" || status=$?; fi
        printf '%s\n' 'same_machine_and_target_scope=USER_ATTESTED_NOT_VERIFIED' \
            'network_mutations=NONE' 'traffic_probes=NOT_RUN' 'gateway_reachability=NOT_TESTED' \
            'enforcement=UNDETERMINED' 'compatibility=UNKNOWN' 'actual_egress=NOT_TESTED' \
            'snapshot_consistency=SEQUENTIAL_NON_ATOMIC' 'automatic_rollback=NOT_IMPLEMENTED'
    } > "$S0_OUT/share-summary.txt" || return 74
    if (( status == 0 )); then
        {
            printf '# LOCAL VALUES ONLY. Do not source this file; follow SINGLE-TARGET.md.\n'
            printf "D='%s'\nV='%s'\nG='%s'\nP='%s'\nT='%s'\n" "$d" "$v" "$pg" "$pi" "$vi"
            printf '\nNo commands were executed. Conditions can change immediately.\n'
        } > "$S0_OUT/targets.private.txt" || return 74
        /bin/cp "$script_dir/SINGLE-TARGET.md" "$S0_OUT/runbook.private.md" || return 74
    fi
    /bin/date -u '+%Y-%m-%dT%H:%M:%SZ' > "$S0_OUT/finished-utc.txt" || return 74
    if (( S0_FAILURES )); then printf 'PARTIAL\n' >| "$S0_OUT/capture-state.txt" || return 74
    else printf 'CAPTURED\n' >| "$S0_OUT/capture-state.txt" || return 74; fi
    trap - EXIT INT TERM HUP
    /bin/cat "$S0_OUT/share-summary.txt"
    printf '\nPrivate results: %s\nOnly share-summary.txt is shareable.\n' "$S0_OUT"
    if (( status == 0 )); then printf 'Read targets.private.txt and runbook.private.md LOCALLY before any manual experiment.\n'; fi
    return "$status"
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then pf_main "$@"; fi
