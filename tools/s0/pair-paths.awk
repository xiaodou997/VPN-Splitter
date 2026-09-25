# SPDX-License-Identifier: MIT
# Read-only IPv4 path candidates. stdout is allowlisted; details stays private.
function ipv4(s, a,n,i) {
    n=split(s,a,"."); if(n!=4) return 0
    for(i=1;i<=4;i++) if(a[i]!~/^[0-9]+$/ || length(a[i])>3 ||
        (length(a[i])>1 && substr(a[i],1,1)=="0") || a[i]+0>255) return 0
    return 1
}
FNR==1 { side++; header=0; column=0 }
$1=="Destination" {
    if(header) bad[side]=1
    header=1; headers[side]++
    for(i=1;i<=NF;i++) if($i=="Netif") column=i
    if(column<4) bad[side]=1
    next
}
!header || !NF { next }
{
    if(column<4 || NF<column) { bad[side]=1; next }
    rows[side]++
    dst=$1; gw=$2; flags=$3; iface=$column
    if(flags!~/U/ || flags~/[IRB]/) next
    if((dst=="default" || dst=="0.0.0.0/0") && iface~/^en[0-9]+$/) {
        if(flags!~/G/ || !ipv4(gw)) { bad[side]=1; next }
        physical[side]++; physicalGW[side]=gw; physicalIF[side]=iface
    }
    if(iface!~/^utun[0-9]+$/) next
    tunnel[side,iface]=1
    if(dst=="default" || dst=="0.0.0.0/0") defaults[side]++
    if(dst=="0/1" || dst=="0.0.0.0/1") {
        halves[side]++; lower[side]++; lowGW[side]=gw; lowIF[side]=iface
    }
    if(dst=="128.0/1" || dst=="128.0.0.0/1") {
        halves[side]++; upper[side]++; highGW[side]=gw; highIF[side]=iface
    }
}
END {
    for(k in tunnel) { split(k,a,SUBSEP); tunnels[a[1]]++ }
    valid=(side==2 && headers[1]==1 && headers[2]==1 && rows[1]>0 && rows[2]>0 && !bad[1] && !bad[2])
    candidate="UNKNOWN"; continuity="UNKNOWN"; pair="UNKNOWN"; other="UNKNOWN"
    if(valid) {
        candidate=(physical[1]==1 ? "UNIQUE" : (physical[1]>1 ? "AMBIGUOUS" : "NONE"))
        if(physical[1]==1) {
            continuity=(physical[2]==1 ? ((physicalGW[1]==physicalGW[2] && physicalIF[1]==physicalIF[2]) ? "MATCH" : "CHANGED") : (physical[2]>1 ? "AMBIGUOUS" : "MISSING"))
        }
        pair="NOT_SINGLE_PAIR"
        if(lower[2]==1 && upper[2]==1 && lowGW[2]==highGW[2] && lowIF[2]==highIF[2] && ipv4(lowGW[2]) && !defaults[2]) pair="SINGLE_PAIR"
        other=(!tunnels[1] && tunnels[2]==1 ? "NONE_OBSERVED" : "REVIEW_REQUIRED")
    }
    print "physical_default_before=" candidate
    print "physical_default_continuity=" continuity
    print "vpn_ipv4_default_pair=" pair
    print "other_ipv4_tunnel_routes=" other
    if(details!="" && valid && candidate=="UNIQUE") {
        print "physical_interface\t" physicalIF[1] > details
        print "physical_gateway\t" physicalGW[1] > details
        if(pair=="SINGLE_PAIR") {
            print "vpn_interface\t" lowIF[2] > details
            print "vpn_gateway\t" lowGW[2] > details
        }
        close(details)
    }
}
