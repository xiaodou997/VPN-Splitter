/* SPDX-License-Identifier: MIT
 * Executes the actual native adapter, replacing only Darwin declarations/syscalls.
 * This is not kernel routing, administrator authentication or macOS ABI evidence.
 */
#include <assert.h>
#include <stdio.h>
#include "darwin_fixture.h"
#include "actual_external_route.c"

static struct { unsigned char bytes[512]; size_t length; int truncated; } messages[32];
static int head, tail, add_calls, delete_calls, fail_add, suppress_reply, wrong_seq, wrong_type, wrong_index;
static int inject_after_get, root = 1, sockets, closes;
static int get_calls, fault_get_index, get_fault, inject_before_add, suppress_delete;
static int radix_replies;
static uint64_t clock_ns;
static er_spec table[8]; static int table_count;
static er_spec specimen(void) { return (er_spec){0xc6336404u, 0xc0000201u, 2, 9, 32}; }
static void reset(void) {
    head = tail = add_calls = delete_calls = fail_add = suppress_reply = wrong_seq = wrong_type = wrong_index = 0;
    inject_after_get = table_count = sockets = closes = 0; root = 1; clock_ns = 1000000000ull;
    get_calls = fault_get_index = get_fault = inject_before_add = suppress_delete = radix_replies = 0;
}
int mach_timebase_info(mach_timebase_info_data_t *info) { info->numer = info->denom = 1; return 0; }
uint64_t mach_continuous_time(void) { clock_ns += 1000; return clock_ns; }
int fake_socket(int family, int type, int protocol) { assert(family == PF_ROUTE && type == SOCK_RAW && protocol == AF_INET); sockets++; return 20; }
int fake_close(int fd) { assert(fd == 20); closes++; return 0; }
int fake_fcntl(int fd, int command, ...) { assert(fd == 20 && (command == F_SETFD || command == F_SETFL)); return 0; }
int fake_setsockopt(int fd, int level, int name, const void *value, socklen_t length) {
    assert(fd == 20 && level == SOL_SOCKET && name == SO_RCVBUF && value && length == sizeof(int)); return 0;
}
uid_t fake_getuid(void) { return root ? 0 : 501; }
uid_t fake_geteuid(void) { return fake_getuid(); }
pid_t fake_getpid(void) { return 4321; }
/* Independent synthetic response encoder. Do not round-trip the production
 * request() builder when testing a returned radix mask. This uses fixture ABI
 * declarations, not captured user bytes or a claim about the installed SDK. */
static size_t wire_span(size_t n) { return n == 0 ? 4 : ((n + 3) / 4) * 4; }
static size_t mask_offset(void) { return sizeof(struct rt_msghdr) + 2 * sizeof(struct sockaddr_in); }
static size_t mask_wire(unsigned char bytes[512], er_spec spec, int type, int sequence,
                        pid_t pid, int error, int flags, unsigned char family, int compact) {
    struct rt_msghdr h; memset(&h, 0, sizeof(h));
    h.rtm_version = RTM_VERSION; h.rtm_type = (uint8_t)type;
    h.rtm_index = spec.interface_index; h.rtm_pid = pid; h.rtm_seq = sequence; h.rtm_errno = error;
    h.rtm_addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK | RTA_IFP;
    h.rtm_flags = flags >= 0 ? flags : RTF_UP | RTF_GATEWAY | RTF_STATIC | RTF_PROTO2 |
                                     (spec.prefix == 32 ? RTF_HOST : 0);
    memset(bytes, 0, 512);
    struct sockaddr_in sa; memset(&sa, 0, sizeof(sa));
    sa.sin_len = sizeof(sa); sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(spec.destination);
    size_t offset = sizeof(h);
    memcpy(bytes + offset, &sa, sizeof(sa)); offset += sizeof(sa);
    sa.sin_addr.s_addr = htonl(spec.gateway);
    memcpy(bytes + offset, &sa, sizeof(sa)); offset += sizeof(sa);
    unsigned char mask[sizeof(struct sockaddr_in)]; memset(mask, 0, sizeof(mask));
    // The three skipped bytes are opaque to the IPv4 prefix, not an address family.
    memset(mask + 1, family, offsetof(struct sockaddr_in, sin_addr) - 1);
    for (unsigned bit = 0; bit < spec.prefix; ++bit)
        mask[offsetof(struct sockaddr_in, sin_addr) + bit / 8] |= (unsigned char)(0x80u >> (bit % 8));
    size_t n = sizeof(mask);
    if (compact) {
        n = spec.prefix == 0 ? 0 : offsetof(struct sockaddr_in, sin_addr) + (spec.prefix + 7) / 8;
    }
    mask[0] = (unsigned char)n;
    memcpy(bytes + offset, mask, n);
    // Padding deliberately nonzero: decode must zero-extend logical mask bytes,
    // never interpret this padding (including sa_len=0) as prefix bits.
    memset(bytes + offset + n, 0xa5, wire_span(n) - n);
    if (n == 0) bytes[offset] = 0;
    offset += wire_span(n);
    struct sockaddr_dl link; memset(&link, 0, sizeof(link));
    link.sdl_len = sizeof(link); link.sdl_family = AF_LINK; link.sdl_index = spec.interface_index;
    memcpy(bytes + offset, &link, sizeof(link)); offset += sizeof(link);
    h.rtm_msglen = (uint16_t)offset; memcpy(bytes, &h, sizeof(h));
    return offset;
}
static void enqueue(er_spec spec, int type, int sequence, pid_t pid, int error, int flags) {
    assert(tail < 32);
    er_context dummy; memset(&dummy, 0, sizeof(dummy)); dummy.pid = pid;
    size_t length;
    if (radix_replies) {
        length = mask_wire(messages[tail].bytes, spec, type, sequence, pid, error, flags, 0xff, 1);
    } else { assert(request(&dummy, RTM_ADD, spec, messages[tail].bytes, &length)); }
    struct rt_msghdr h; memcpy(&h, messages[tail].bytes, sizeof(h));
    h.rtm_type = (uint8_t)type; h.rtm_seq = sequence; h.rtm_pid = pid; h.rtm_errno = error;
    if (flags >= 0) h.rtm_flags = flags;
    memcpy(messages[tail].bytes, &h, sizeof(h)); messages[tail].length = length; messages[tail].truncated = 0; tail++;
}
ssize_t fake_write(int fd, const void *bytes, size_t n) {
    assert(fd == 20);
    struct er_message req; memset(&req, 0, sizeof(req));
    assert(n >= sizeof(struct rt_msghdr) + sizeof(struct sockaddr_in));
    struct rt_msghdr h; memcpy(&h, bytes, sizeof(h));
    if (h.rtm_type == RTM_GET) {
        struct sockaddr_in dst; memcpy(&dst, (const unsigned char *)bytes + sizeof(h), sizeof(dst));
        req.destination = ntohl(dst.sin_addr.s_addr);
    } else { assert(decode(bytes, n, &req)); }
    if (h.rtm_type == RTM_GET) {
        ++get_calls;
        int fault = get_calls == fault_get_index ? get_fault : 0;
        if (fault == 1 || fault == 8) {
            if (fault == 8) { errno = ENETDOWN; return -1; }
            return (ssize_t)n; // query timeout, not a mutation
        }
        er_spec s = specimen(); int found = 0;
        for (int i = 0; i < table_count; ++i) {
            if ((req.destination & prefix_mask(table[i].prefix)) == table[i].destination) { s = table[i]; found = 1; break; }
        }
        int flags = -1;
        if (!found && req.destination == s.gateway) {
            s.destination = s.gateway; s.prefix = 32; flags = RTF_UP | RTF_HOST;
        } else if (!found) {
            s.destination = req.destination & 0x80000000u; s.prefix = 1; s.interface_index = 9; flags = RTF_UP | RTF_GATEWAY;
        }
        if (fault == 9) s.interface_index = 4;
        enqueue(s, fault == 6 ? RTM_ADD : RTM_GET, h.rtm_seq + (fault == 5), h.rtm_pid, fault == 4 ? EACCES : 0, flags);
        if (fault == 2) messages[tail - 1].bytes[2] = 99;
        if (fault == 3) {
            size_t ifp = sizeof(struct rt_msghdr) + 3 * sizeof(struct sockaddr_in);
            messages[tail - 1].bytes[ifp + 1] = AF_INET;
        }
        if (fault == 7) messages[tail - 1].truncated = 1;
        if (fault == 10) {
            unsigned char *mask = messages[tail - 1].bytes + mask_offset();
            mask[offsetof(struct sockaddr_in, sin_addr)] = 0xa0; // non-contiguous /1 or /32
        }
        if (inject_before_add && get_calls == 2) enqueue(s, 99, 0, 777, 0, flags);
        if (fault == 4) { errno = EACCES; return -1; }
        if (found && inject_after_get) {
            inject_after_get = 0; enqueue(s, RTM_CHANGE, 0, 777, 0, -1);
        }
        return (ssize_t)n;
    }
    er_spec s = {req.destination, req.gateway, (uint16_t)req.index, 9, (uint8_t)req.prefix};
    if (h.rtm_type == RTM_ADD) {
        add_calls++;
        if (!fail_add) table[table_count++] = s;
        if (!suppress_reply) {
            if (wrong_index) s.interface_index = 4;
            enqueue(s, wrong_type ? RTM_DELETE : RTM_ADD, h.rtm_seq + wrong_seq, h.rtm_pid, fail_add ? EEXIST : 0, -1);
        }
        if (fail_add) { errno = EEXIST; return -1; } // Still has a matching kernel error reply.
        return (ssize_t)n;
    }
    assert(h.rtm_type == RTM_DELETE); delete_calls++;
    for (int i = 0; i < table_count; ++i) if (table[i].destination == s.destination && table[i].prefix == s.prefix) {
        table[i] = table[--table_count]; break;
    }
    if (!suppress_delete) enqueue(s, RTM_DELETE, h.rtm_seq, h.rtm_pid, 0, -1);
    return (ssize_t)n;
}
ssize_t fake_recvmsg(int fd, struct msghdr *msg, int flags) {
    assert(fd == 20 && flags == MSG_DONTWAIT);
    if (head == tail) { head = tail = 0; errno = EAGAIN; return -1; }
    assert(msg->msg_iovlen == 1 && msg->msg_iov[0].iov_len >= messages[head].length);
    memcpy(msg->msg_iov[0].iov_base, messages[head].bytes, messages[head].length);
    msg->msg_flags = messages[head].truncated ? MSG_TRUNC : 0;
    return (ssize_t)messages[head++].length;
}
int fake_poll(struct pollfd *fds, nfds_t count, int timeout) {
    assert(count == 1 && fds[0].fd == 20);
    if (head < tail) { fds[0].revents = POLLIN; return 1; }
    clock_ns += (uint64_t)timeout * 1000000u; return 0;
}
static int netmask_scenarios(void) {
    int scenarios = 0;
    unsigned char bytes[512]; struct er_message decoded;
    // Every IPv4 prefix and both /1 halves: opaque family bytes never select IPv6.
    const unsigned char families[] = {0, AF_INET, 0xff, AF_LINK, 30};
    for (unsigned family = 0; family < sizeof(families); ++family) {
        for (unsigned prefix = 0; prefix <= 32; ++prefix) {
            for (int compact = 0; compact <= 1; ++compact) {
                er_spec s = specimen(); s.destination = prefix ? 0x80000000u : 0; s.prefix = (uint8_t)prefix;
                size_t n = mask_wire(bytes, s, RTM_GET, 1, 4321, 0, -1, families[family], compact);
                assert(decode(bytes, n, &decoded));
                assert(decoded.has_mask && decoded.prefix == prefix && decoded.destination == s.destination);
                assert(decoded.index == s.interface_index && decoded.gateway == s.gateway);
                if (prefix == 1) {
                    s.destination = 0; n = mask_wire(bytes, s, RTM_GET, 1, 4321, 0, -1, families[family], compact);
                    assert(decode(bytes, n, &decoded) && decoded.prefix == 1 && decoded.mask == 0x80000000u);
                }
            }
        }
    }
    scenarios++;
    // Host routes may omit RTA_NETMASK entirely. A compact zero mask is NOT /32.
    er_spec s = specimen();
    size_t n = mask_wire(bytes, s, RTM_GET, 1, 4321, 0, -1, 0xff, 1);
    size_t offset = mask_offset(), span = wire_span(bytes[offset]);
    memmove(bytes + offset, bytes + offset + span, n - offset - span); n -= span;
    struct rt_msghdr h; memcpy(&h, bytes, sizeof(h)); h.rtm_addrs &= ~RTA_NETMASK;
    h.rtm_msglen = (uint16_t)n; memcpy(bytes, &h, sizeof(h));
    assert(decode(bytes, n, &decoded) && !decoded.has_mask && decoded.prefix == 32);
    s.destination = 0; s.prefix = 0;
    n = mask_wire(bytes, s, RTM_GET, 1, 4321, 0, RTF_UP | RTF_HOST, 0xff, 1);
    assert(!decode(bytes, n, &decoded) && decoded.decode_failure == 12); scenarios++;
    // The mask-slot exception must not permit invalid DST/GATEWAY/IFP families.
    for (unsigned slot = 0; slot < 3; ++slot) {
        n = mask_wire(bytes, specimen(), RTM_GET, 1, 4321, 0, -1, 0xff, 1);
        size_t field = slot < 2 ? sizeof(h) + slot * sizeof(struct sockaddr_in) :
                                 mask_offset() + wire_span(bytes[mask_offset()]);
        bytes[field + 1] = 0xff;
        assert(!decode(bytes, n, &decoded));
        assert(decoded.decode_failure == (slot < 2 ? 8 : 9));
    }
    scenarios++;
    // Mask lengths and alignment bounds remain enforced.
    n = mask_wire(bytes, specimen(), RTM_GET, 1, 4321, 0, -1, 0xff, 0);
    bytes[mask_offset()] = sizeof(struct sockaddr_in) + 1;
    assert(!decode(bytes, n, &decoded) && decoded.decode_failure == 5);
    n = mask_wire(bytes, specimen(), RTM_GET, 1, 4321, 0, -1, 0xff, 1);
    bytes[mask_offset()] = 255;
    assert(!decode(bytes, n, &decoded) && decoded.decode_failure == 4);
    n = mask_wire(bytes, specimen(), RTM_GET, 1, 4321, 0, -1, 0xff, 1);
    memcpy(&h, bytes, sizeof(h)); h.rtm_msglen = (uint16_t)(mask_offset() + 7); memcpy(bytes, &h, sizeof(h));
    assert(!decode(bytes, h.rtm_msglen, &decoded) && decoded.decode_failure == 4); scenarios++;
    // Non-contiguous masks, noncanonical destinations and wrong host masks still fail.
    s = specimen(); s.destination = 0x80000000u; s.prefix = 1;
    n = mask_wire(bytes, s, RTM_GET, 1, 4321, 0, -1, 0xff, 1);
    bytes[mask_offset() + offsetof(struct sockaddr_in, sin_addr)] = 0xa0;
    assert(!decode(bytes, n, &decoded) && decoded.decode_failure == 13);
    s.destination = 0x80000001u;
    n = mask_wire(bytes, s, RTM_GET, 1, 4321, 0, -1, 0xff, 1);
    assert(!decode(bytes, n, &decoded) && decoded.decode_failure == 14);
    s.destination = 0x80000000u;
    n = mask_wire(bytes, s, RTM_GET, 1, 4321, 0, RTF_UP | RTF_HOST, 0xff, 1);
    assert(!decode(bytes, n, &decoded) && decoded.decode_failure == 12); scenarios++;
    // Complete GET-only preflight with canonical target and gateway mask replies.
    for (int as_root = 0; as_root <= 1; ++as_root) {
        reset(); root = as_root; radix_replies = 1; er_context *c = er_open_query(); assert(c);
        er_result r = er_probe(c, specimen()); er_diagnostic d = er_get_diagnostic(c);
        assert(r.status == 0 && !r.token && get_calls == 2 && d.stage == ER_STAGE_GATEWAY_GET);
        assert(d.reason == ER_REASON_NONE && d.decode_field == 0 && d.mutation_attempts == 0);
        assert(er_add(c, specimen()).status == 3 && er_remove(c, 1).status == 1);
        struct er_message reply;
        assert(exchange(c, RTM_ADD, specimen(), &reply) == 1);
        assert(exchange(c, RTM_DELETE, specimen(), &reply) == 1);
        assert(add_calls == 0 && delete_calls == 0 && c->used == 0 && !er_owns(c, 1)); er_close(c);
    }
    scenarios++;
    // Shared decoder must also handle returned masks in ADD/GET/DELETE and events.
    for (unsigned prefix = 24; prefix <= 32; ++prefix) {
        reset(); radix_replies = 1; er_context *c = er_open();
        s = specimen(); s.destination = 0xc6336400u; s.prefix = (uint8_t)prefix;
        er_result r = er_add(c, s); assert(r.status == 0 && er_owns(c, r.token));
        assert(er_remove(c, r.token).status == 0 && table_count == 0);
        assert(er_get_diagnostic(c).mutation_attempts == 2 && add_calls == 1 && delete_calls == 1);
        assert(er_remove(c, r.token).status == 1 && delete_calls == 1); er_close(c);
    }
    scenarios++;
    reset(); radix_replies = 1; er_context *c = er_open(); er_result r = er_add(c, specimen());
    assert(r.status == 0); enqueue(specimen(), RTM_CHANGE, 0, 777, 0, -1);
    assert(er_drain(c) && !er_owns(c, r.token));
    assert(er_remove(c, r.token).status == 1 && delete_calls == 0); er_close(c); scenarios++;
    // A malformed mask still rejects before ADD; no write-uncertainty upgrade.
    for (int query = 1; query <= 2; ++query) {
        reset(); radix_replies = 1; c = er_open(); get_fault = 10; fault_get_index = query;
        assert(er_add(c, specimen()).status == 3);
        er_diagnostic d = er_get_diagnostic(c);
        assert(d.stage == (query == 1 ? ER_STAGE_TARGET_GET : ER_STAGE_GATEWAY_GET));
        assert(d.reason == ER_REASON_DECODE && d.mutation_attempts == 0);
        assert(d.decode_field == (query == 1 ? 13 : 12));
        assert(add_calls == 0 && delete_calls == 0 && table_count == 0); er_close(c);
    }
    scenarios++;
    return scenarios;
}
int main(void) {
    int scenarios = 0;
    reset(); root = 0; assert(er_open() == NULL && sockets == 0); scenarios++;
    reset(); er_context *c = er_open(); assert(c);
    er_spec s = specimen(); s.prefix = 0; assert(er_add(c, s).status == 1 && add_calls == 0);
    s = specimen(); s.gateway = 0x7f000001; assert(er_add(c, s).status == 1 && add_calls == 0);
    s = specimen(); s.interface_index = s.tunnel_index; assert(er_add(c, s).status == 1 && add_calls == 0); er_close(c); scenarios++;
    reset(); c = er_open(); er_result added = er_add(c, specimen());
    assert(added.status == 0 && added.token && er_owns(c, added.token) && table_count == 1);
    assert(er_remove(c, added.token).status == 0 && delete_calls == 1 && table_count == 0);
    assert(er_remove(c, added.token).status == 1 && delete_calls == 1); er_close(c); scenarios++;
    reset(); c = er_open(); fail_add = 1; added = er_add(c, specimen());
    assert(added.status == 1 && added.token == 0 && delete_calls == 0 && !er_owns(c, 1)); er_close(c); scenarios++;
    reset(); c = er_open(); suppress_reply = 1; added = er_add(c, specimen());
    assert(added.status == 2 && !added.token && table_count == 1 && !er_owns(c, 1)); er_close(c); assert(delete_calls == 0); scenarios++;
    reset(); c = er_open(); wrong_seq = 1; added = er_add(c, specimen()); assert(added.status == 2 && !added.token); er_close(c); scenarios++;
    reset(); c = er_open(); wrong_type = 1; added = er_add(c, specimen()); assert(added.status == 2 && !added.token); er_close(c); scenarios++;
    reset(); c = er_open(); wrong_index = 1; added = er_add(c, specimen()); assert(added.status == 2 && !added.token); er_close(c); scenarios++;
    reset(); c = er_open(); added = er_add(c, specimen());
    enqueue(specimen(), RTM_CHANGE, 0, 777, 0, -1);
    assert(er_drain(c) && !er_owns(c, added.token)); assert(er_remove(c, added.token).status == 1 && delete_calls == 0); er_close(c); scenarios++;
    reset(); c = er_open(); added = er_add(c, specimen()); inject_after_get = 1;
    assert(er_remove(c, added.token).status == 1 && delete_calls == 0); er_close(c); scenarios++;
    reset(); c = er_open(); added = er_add(c, specimen());
    enqueue(specimen(), RTM_CHANGE, 0, 777, 0, -1); messages[tail - 1].truncated = 1;
    assert(!er_drain(c) && !er_owns(c, added.token)); assert(er_remove(c, added.token).status == 1 && delete_calls == 0); er_close(c); scenarios++;
    reset(); c = er_open(); added = er_add(c, specimen());
    enqueue(specimen(), RTM_CHANGE, 0, 777, 0, -1); messages[tail - 1].bytes[2] = 99;
    assert(!er_drain(c) && !er_owns(c, added.token)); er_close(c); scenarios++;
    reset(); c = er_open(); added = er_add(c, specimen());
    assert(er_add(c, specimen()).status == 1 && add_calls == 1); er_close(c); assert(delete_calls == 0); scenarios++;
    reset(); c = er_open(); s = specimen(); s.destination &= 0xffffff00u; s.prefix = 24;
    added = er_add(c, s); assert(added.status == 0); assert(er_remove(c, added.token).status == 0); er_close(c); scenarios++;
    reset(); c = er_open(); added = er_add(c, specimen());
    enqueue(specimen(), RTM_CHANGE, 0, 777, EACCES, -1);
    assert(er_drain(c) && er_owns(c, added.token)); assert(er_remove(c, added.token).status == 0); er_close(c); scenarios++;
    /* Query contexts may open unprivileged, but can NEVER issue mutations. */
    for (int as_root = 0; as_root <= 1; ++as_root) {
        reset(); root = as_root; c = er_open_query(); assert(c);
        er_result probed = er_probe(c, specimen()); er_diagnostic d = er_get_diagnostic(c);
        assert(probed.status == 0 && probed.token == 0 && get_calls == 2);
        assert(d.stage == ER_STAGE_GATEWAY_GET && d.reason == ER_REASON_NONE && d.mutation_attempts == 0);
        assert(c->used == 0 && !er_owns(c, 1) && add_calls == 0 && delete_calls == 0);
        assert(er_add(c, specimen()).status == 3 && er_remove(c, 1).status == 1);
        struct er_message reply;
        assert(exchange(c, RTM_ADD, specimen(), &reply) == 1);
        assert(exchange(c, RTM_DELETE, specimen(), &reply) == 1);
        assert(add_calls == 0 && delete_calls == 0 && er_get_diagnostic(c).mutation_attempts == 0);
        er_close(c); scenarios++;
    }
    /* Identical preflight failures via add and GET-only probe; never return a receipt. */
    const int reasons[] = {0, ER_REASON_TIMEOUT, ER_REASON_DECODE, ER_REASON_DECODE,
        ER_REASON_KERNEL, ER_REASON_TIMEOUT, ER_REASON_REPLY_TYPE, ER_REASON_TRUNCATED, ER_REASON_TIMEOUT};
    for (int fault = 1; fault <= 8; ++fault) {
        for (int query = 1; query <= 2; ++query) {
            for (int probe_only = 0; probe_only <= 1; ++probe_only) {
                reset(); c = probe_only ? er_open_query() : er_open();
                get_fault = fault; fault_get_index = query;
                er_result r = probe_only ? er_probe(c, specimen()) : er_add(c, specimen());
                er_diagnostic d = er_get_diagnostic(c);
                assert(r.status != 0 && (!probe_only ? r.status == 3 : 1) && r.token == 0);
                assert(d.stage == (query == 1 ? ER_STAGE_TARGET_GET : ER_STAGE_GATEWAY_GET));
                assert(d.reason == reasons[fault] && d.mutation_attempts == 0);
                if (fault == 2 || fault == 3) assert(d.decode_field > 0);
                if (fault == 4) assert(d.system_errno == EACCES && d.reply_errno == EACCES);
                if (fault == 8) assert(d.system_errno == ENETDOWN);
                assert(get_calls == query && add_calls == 0 && delete_calls == 0 && table_count == 0);
                er_drain(c); er_remove(c, 1); // cleanup must not erase the original cause
                er_diagnostic after = er_get_diagnostic(c);
                assert(after.stage == d.stage && after.reason == d.reason && after.decode_field == d.decode_field);
                er_close(c);
            }
        }
        scenarios++;
    }
    reset(); c = er_open(); get_fault = 9; fault_get_index = 1;
    assert(er_add(c, specimen()).status == 3 && er_get_diagnostic(c).reason == ER_REASON_TARGET_PATH);
    assert(add_calls == 0); er_close(c); scenarios++;
    reset(); c = er_open(); get_fault = 9; fault_get_index = 2;
    assert(er_add(c, specimen()).status == 3 && er_get_diagnostic(c).reason == ER_REASON_GATEWAY_PATH);
    assert(add_calls == 0); er_close(c); scenarios++;
    reset(); c = er_open(); inject_before_add = 1;
    assert(er_add(c, specimen()).status == 3);
    assert(er_get_diagnostic(c).stage == ER_STAGE_ADD && er_get_diagnostic(c).mutation_attempts == 0);
    assert(add_calls == 0); er_close(c); scenarios++;
    reset(); c = er_open(); suppress_reply = 1;
    assert(er_add(c, specimen()).status == 2);
    assert(er_get_diagnostic(c).stage == ER_STAGE_ADD && er_get_diagnostic(c).mutation_attempts == 1);
    assert(add_calls == 1 && table_count == 1 && delete_calls == 0); er_close(c); scenarios++;
    reset(); c = er_open(); fail_add = 1;
    assert(er_add(c, specimen()).status == 1);
    assert(er_get_diagnostic(c).reply_errno == EEXIST && er_get_diagnostic(c).mutation_attempts == 1);
    assert(add_calls == 1 && table_count == 0); er_close(c); scenarios++;
    reset(); c = er_open(); added = er_add(c, specimen()); suppress_delete = 1;
    assert(er_remove(c, added.token).status == 2);
    assert(er_get_diagnostic(c).stage == ER_STAGE_DELETE && er_get_diagnostic(c).mutation_attempts == 2);
    assert(er_remove(c, added.token).status == 1 && delete_calls == 1); er_close(c); scenarios++;
    scenarios += netmask_scenarios();
    printf("routing-socket-adapter=PASS scenarios=%d source=ACTUAL darwin_kernel_io=TEST_DOUBLES network=NOT_APPLIED\n", scenarios);
    return 0;
}
