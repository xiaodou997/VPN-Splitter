/* SPDX-License-Identifier: MIT
 * Actual adapter with synthetic protocol dispatch and independent IPv6 framing.
 * All kernel/syscall/ABI data is a TEST DOUBLE; no socket or network is touched.
 */
#define main prior_route_harness_main
#include "route_harness.c"
#undef main

static size_t ipv6_wire(unsigned char bytes[512], int type, int seq, pid_t pid) {
    memset(bytes, 0, 512);
    struct rt_msghdr h; memset(&h, 0, sizeof(h));
    h.rtm_version = RTM_VERSION; h.rtm_type = (uint8_t)type;
    h.rtm_seq = seq; h.rtm_pid = pid; h.rtm_index = 2;
    h.rtm_flags = RTF_UP | RTF_GATEWAY;
    h.rtm_addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK | RTA_IFP;
    size_t offset = sizeof(h);
    // Independent Darwin-format address vector using SDK/fixture size declarations.
    for (int i = 0; i < 2; ++i) {
        bytes[offset] = sizeof(struct sockaddr_in6); bytes[offset + 1] = AF_INET6;
        bytes[offset + 8] = 0x20; bytes[offset + 9] = 0x01;
        bytes[offset + 10] = 0x0d; bytes[offset + 11] = 0xb8;
        bytes[offset + 23] = (unsigned char)i;
        offset += sizeof(struct sockaddr_in6);
    }
    bytes[offset] = 16; // compact /64 mask at the IPv6 address offset
    memset(bytes + offset + 1, 0xff, 15); offset += 16;
    struct sockaddr_dl link; memset(&link, 0, sizeof(link));
    link.sdl_len = sizeof(link); link.sdl_family = AF_LINK; link.sdl_index = 2;
    memcpy(bytes + offset, &link, sizeof(link)); offset += sizeof(link);
    h.rtm_msglen = (uint16_t)offset; memcpy(bytes, &h, sizeof(h));
    return offset;
}
static void enqueue_v6(int type, int seq, pid_t pid) {
    if (socket_protocol && socket_protocol != AF_INET6) { filtered_messages++; return; }
    assert(tail < 32);
    messages[tail].length = ipv6_wire(messages[tail].bytes, type, seq, pid);
    messages[tail].truncated = 0; tail++;
}
static void unrelated_v6(int type, int seq, pid_t pid) {
    (void)type; (void)seq; (void)pid;
    enqueue_v6(RTM_CHANGE, 0, 777);
}
static int forged_type;
static void forged_v6(int type, int seq, pid_t pid) {
    if (type == forged_type) enqueue_v6(type, seq, pid);
}
static void replacement_on_remove(int type, int seq, pid_t pid) {
    (void)seq; (void)pid;
    if (type == RTM_GET && table_count) enqueue(specimen(), RTM_CHANGE, 0, 777, 0, -1);
}
static void legacy_reproduction(void) {
    reset(); er_context *c = er_open(); assert(c && socket_protocol == AF_INET);
    assert(er_probe(c, specimen()).status == 0); // both GETs pass
    er_result r = er_add(c, specimen()); er_diagnostic d = er_get_diagnostic(c);
    assert(r.status == 2 && !r.token && !er_owns(c, 1));
    assert(d.stage == ER_STAGE_ADD && d.reason == ER_REASON_TIMEOUT && d.mutation_attempts == 1);
    assert(add_calls == 1 && table_count == 1 && filtered_messages == 1 && delete_calls == 0);
    er_close(c); assert(table_count == 1); // close is not rollback
    puts("legacy-dispatch=REPRODUCED stage=add reason=timeout mutation_attempts=1 synthetic_route_remaining=1");
}
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "legacy") == 0) { legacy_reproduction(); return 0; }
    assert(argc == 1);
    int scenarios = 0;
    reset(); er_context *c = er_open(); assert(c && socket_protocol == 0);
    er_result r = er_add(c, specimen());
    assert(r.status == 0 && r.token && er_owns(c, r.token) && table_count == 1);
    assert(er_remove(c, r.token).status == 0 && table_count == 0);
    assert(filtered_messages == 0 && add_calls == 1 && delete_calls == 1);
    assert(er_get_diagnostic(c).mutation_attempts == 2); er_close(c); scenarios++;

    for (int as_root = 0; as_root <= 1; ++as_root) {
        reset(); root = as_root; c = er_open_query(); assert(c && socket_protocol == 0);
        notification_hook = unrelated_v6;
        assert(er_probe(c, specimen()).status == 0 && get_calls == 2);
        assert(er_add(c, specimen()).status == 3 && er_remove(c, 1).status == 1);
        struct er_message m;
        assert(exchange(c, RTM_ADD, specimen(), &m) == 1);
        assert(exchange(c, RTM_DELETE, specimen(), &m) == 1);
        assert(add_calls == 0 && delete_calls == 0 && !er_owns(c, 1)); er_close(c);
    }
    scenarios++;
    // Foreign IPv6 events can arrive during every GET, ADD and DELETE wait.
    reset(); radix_replies = 1; notification_hook = unrelated_v6; c = er_open();
    r = er_add(c, specimen()); assert(r.status == 0 && er_owns(c, r.token));
    assert(er_remove(c, r.token).status == 0 && table_count == 0);
    assert(add_calls == 1 && delete_calls == 1); er_close(c); scenarios++;

    unsigned char bytes[512];
    const int changes[] = {RTM_ADD, RTM_DELETE, RTM_CHANGE, RTM_LOCK, RTM_REDIRECT, RTM_RESOLVE};
    reset(); c = er_open(); r = er_add(c, specimen()); assert(r.status == 0);
    for (unsigned i = 0; i < sizeof(changes) / sizeof(changes[0]); ++i) {
        size_t n = ipv6_wire(bytes, changes[i], 0, 777);
        assert(event(c, bytes, n) && er_owns(c, r.token));
    }
    assert(er_remove(c, r.token).status == 0); er_close(c); scenarios++;

    // A matching reply with an IPv6 body is NOT an unrelated notification.
    const int forged[] = {RTM_GET, RTM_ADD, RTM_DELETE};
    for (unsigned i = 0; i < sizeof(forged) / sizeof(forged[0]); ++i) {
        reset(); c = er_open(); forged_type = forged[i];
        if (forged_type == RTM_DELETE) {
            r = er_add(c, specimen()); assert(r.status == 0);
            notification_hook = forged_v6;
            assert(er_remove(c, r.token).status == 2);
            assert(er_get_diagnostic(c).mutation_attempts == 2);
        } else {
            notification_hook = forged_v6; r = er_add(c, specimen());
            assert(r.status == (forged_type == RTM_GET ? 3 : 2));
            assert(!r.token && er_get_diagnostic(c).mutation_attempts == (forged_type == RTM_GET ? 0u : 1u));
        }
        assert(er_get_diagnostic(c).reason == ER_REASON_DECODE); er_close(c);
    }
    scenarios++;
    // Same-key IPv4 notifications tagged protocol 0 must still revoke receipts.
    reset(); c = er_open(); r = er_add(c, specimen()); assert(r.status == 0);
    enqueue(specimen(), RTM_CHANGE, 0, 777, 0, -1);
    assert(er_drain(c) && !er_owns(c, r.token));
    assert(er_remove(c, r.token).status == 1 && delete_calls == 0); er_close(c); scenarios++;
    reset(); c = er_open(); r = er_add(c, specimen()); assert(r.status == 0);
    notification_hook = replacement_on_remove;
    assert(er_remove(c, r.token).status == 1 && delete_calls == 0); er_close(c); scenarios++;

    // Do not relabel an IPv4-length body as IPv6 to bypass decode failures.
    reset(); c = er_open(); r = er_add(c, specimen()); assert(r.status == 0);
    enqueue(specimen(), RTM_CHANGE, 0, 777, 0, -1);
    messages[tail - 1].bytes[sizeof(struct rt_msghdr) + 1] = AF_INET6;
    assert(!er_drain(c) && !er_owns(c, r.token)); er_close(c); scenarios++;
    // Incomplete headers, address vectors and unknown families remain fatal.
    for (int defect = 0; defect < 10; ++defect) {
        reset(); c = er_open(); r = er_add(c, specimen()); assert(r.status == 0);
        size_t n = ipv6_wire(bytes, RTM_CHANGE, 0, 777);
        struct rt_msghdr h; memcpy(&h, bytes, sizeof(h));
        switch (defect) {
        case 0: h.rtm_msglen--; break;
        case 1: h.rtm_version++; break;
        case 2: h.rtm_addrs |= 1 << RTAX_MAX; break;
        case 3: h.rtm_addrs &= ~RTA_DST; break;
        case 4: bytes[sizeof(h)] = 255; break;
        case 5: bytes[sizeof(h) + 1] = 0xfe; break;
        case 6: bytes[sizeof(h) + sizeof(struct sockaddr_in6)] = 1; break;
        case 7: bytes[sizeof(h) + 2 * sizeof(struct sockaddr_in6)] = 255; break;
        case 8: bytes[n - sizeof(struct sockaddr_dl) + offsetof(struct sockaddr_dl, sdl_alen)] = 255; break;
        case 9: n--; h.rtm_msglen = (uint16_t)n; break;
        }
        memcpy(bytes, &h, sizeof(h));
        assert(!event(c, bytes, n) && !er_owns(c, r.token));
        assert(er_remove(c, r.token).status == 1 && delete_calls == 0); er_close(c);
    }
    scenarios++;
    reset(); c = er_open(); r = er_add(c, specimen()); assert(r.status == 0);
    enqueue_v6(RTM_CHANGE, 0, 777); messages[tail - 1].truncated = 1;
    assert(!er_drain(c) && !er_owns(c, r.token)); er_close(c); scenarios++;
    reset(); c = er_open(); r = er_add(c, specimen()); assert(r.status == 0);
    size_t n = ipv6_wire(bytes, 99, 0, 777);
    assert(!event(c, bytes, n) && !er_owns(c, r.token)); er_close(c); scenarios++;
    // A genuine lost ADD reply is still uncertain, not success via table matching.
    reset(); c = er_open(); suppress_reply = 1; r = er_add(c, specimen());
    assert(r.status == 2 && !r.token && table_count == 1 && delete_calls == 0);
    assert(er_get_diagnostic(c).mutation_attempts == 1); er_close(c); scenarios++;
    printf("routing-notifications=PASS scenarios=%d source=ACTUAL darwin_kernel_io=TEST_DOUBLES network=NOT_APPLIED\n", scenarios);
    return 0;
}
