# SPDX-License-Identifier: MIT
# Conservative, IPv4-only hints from numeric macOS netstat output.
# Never print input fields. A hint is not an egress/compatibility verdict.
BEGIN { header = 0; rows = 0; malformed = 0; halves = 0; defaults = 0 }
$1 == "Destination" {
    header = 1; column = 0
    for (i = 1; i <= NF; i++) if ($i == "Netif") column = i
    if (!column) malformed = 1
    next
}
!header || !NF { next }
{
    if (!column || NF < column) { malformed = 1; next }
    rows++
    destination = $1; gateway = $2; flags = $3; interface = $column
    # Ignore scoped, rejected, blackhole and non-up routes.
    if (flags !~ /U/ || flags ~ /[IRB]/) next
    if (interface !~ /^utun[0-9]+$/) next
    if (destination == "default" || destination == "0.0.0.0/0") defaults++
    key = gateway SUBSEP interface
    if (destination == "0/1" || destination == "0.0.0.0/1") {
        lower[key]++; halves++
    }
    if (destination == "128.0/1" || destination == "128.0.0.0/1") {
        upper[key]++; halves++
    }
}
END {
    pairs = 0; duplicate = 0
    for (key in lower) {
        if (lower[key] > 1) duplicate = 1
        if (upper[key]) pairs++
    }
    for (key in upper) if (upper[key] > 1) duplicate = 1
    hint = "NONE_OBSERVED"
    if (!header || malformed || !rows) hint = "UNKNOWN"
    else if (duplicate || pairs > 1 || defaults > 1 || (pairs && defaults)) hint = "MULTIPLE_CANDIDATES"
    else if (pairs == 1 && halves == 2) hint = "SPLIT_DEFAULT_PAIR"
    else if (halves) hint = "INCOMPLETE_OR_MIXED_PAIR"
    else if (defaults == 1) hint = "TUNNEL_DEFAULT"
    print "ipv4_full_tunnel_hint=" hint
    print "compatibility=UNKNOWN"
    print "actual_egress=NOT_TESTED"
}
