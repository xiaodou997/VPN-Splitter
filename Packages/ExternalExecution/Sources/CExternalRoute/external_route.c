/* SPDX-License-Identifier: MIT
 * Finite foreground routing-socket adapter. One serial owner per context.
 * No shell, flush/change/default-route operation, DNS write, or persisted ownership.
 * BSD routing sockets have no atomic compare-and-delete or route ownership cookie.
 * A matching live receipt and readback reduce races; they do NOT prove absence of
 * a hostile privileged ABA writer or every possible dropped kernel notification.
 */
#include "external_route.h"
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <time.h>

#if defined(__APPLE__)
#include <sys/socket.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netinet/in.h>
#include <mach/mach_time.h>

#define ER_LIMIT 8
#define ER_BYTES 65536
#define ER_EVENTS 1024
struct er_owned { er_spec spec; int live; };
struct er_context {
    int fd, sequence, poisoned, used;
    pid_t pid;
    int writable, failed;
    uint32_t mutation_attempts;
    er_diagnostic diagnostic, first_failure;
    struct er_owned owned[ER_LIMIT];
};
struct er_message {
    struct rt_msghdr header;
    uint32_t destination, gateway, mask;
    unsigned prefix, index;
    int has_destination, has_gateway, has_mask, decode_failure;
};
static er_result result(int status, uint64_t token) { return (er_result){status, token}; }
static void begin_stage(er_context *c, int stage) {
    memset(&c->diagnostic, 0, sizeof(c->diagnostic)); c->diagnostic.stage = stage;
}
static void diagnose(er_context *c, int reason, int field, int system_errno) {
    c->diagnostic.reason = reason; c->diagnostic.decode_field = field;
    c->diagnostic.system_errno = system_errno;
    if (!c->failed) { c->first_failure = c->diagnostic; c->failed = 1; }
}
er_diagnostic er_get_diagnostic(const er_context *c) {
    er_diagnostic d = {0};
    if (!c) { d.reason = ER_REASON_INVALID; return d; }
    d = c->failed ? c->first_failure : c->diagnostic;
    d.mutation_attempts = c->mutation_attempts; return d;
}
static int bad_decode(struct er_message *out, int field) { out->decode_failure = field; return 0; }
static size_t aligned(size_t n) { return n ? (n + 3u) & ~(size_t)3u : 4u; }
static uint32_t prefix_mask(unsigned n) { return n ? UINT32_MAX << (32u - n) : 0; }
static int unicast(uint32_t value) {
    unsigned first = value >> 24;
    return first != 0 && first != 127 && first < 224 && (value >> 16) != 0xa9fe;
}
static int spec_valid(er_spec s) {
    return s.prefix >= 24 && s.prefix <= 32 && s.interface_index && s.tunnel_index &&
        s.interface_index != s.tunnel_index && unicast(s.destination) && unicast(s.gateway) &&
        s.destination == (s.destination & prefix_mask(s.prefix));
}
double er_continuous_seconds(void) {
    mach_timebase_info_data_t info;
    if (mach_timebase_info(&info) != KERN_SUCCESS || !info.denom) return -1;
    return (double)mach_continuous_time() * (double)info.numer / (double)info.denom / 1e9;
}
/* Copies from bounded bytes; no unaligned casts or hardcoded rt_msghdr ABI sizes. */
static int decode(const unsigned char *bytes, size_t length, struct er_message *out) {
    memset(out, 0, sizeof(*out));
    if (length < sizeof(struct rt_msghdr)) return bad_decode(out, 1);
    memcpy(&out->header, bytes, sizeof(out->header));
    struct rt_msghdr *h = &out->header;
    if (h->rtm_msglen != length || h->rtm_version != RTM_VERSION || h->rtm_addrs < 0 ||
        ((unsigned)h->rtm_addrs >> RTAX_MAX) != 0) return bad_decode(out, 2);
    out->index = h->rtm_index;
    size_t offset = sizeof(*h);
    for (int i = 0; i < RTAX_MAX; ++i) {
        if (!(h->rtm_addrs & (1 << i))) continue;
        if (offset + 2 > length) return bad_decode(out, 3);
        size_t n = bytes[offset], span = aligned(n);
        if (span > length - offset || (n < 2 && i != RTAX_NETMASK)) return bad_decode(out, 4);
        unsigned family = bytes[offset + 1];
        if (i == RTAX_NETMASK) {
            /* A radix key mask is not a standalone socket address. XNU may fill
             * its skipped prefix bytes (including the family position) with 0xff
             * and omit trailing zero bytes. Interpret its bits using the separately
             * validated IPv4 destination, not the mask's apparent family. Never
             * read beyond sa_len into alignment padding or the following IFP.
             * Diagnostic field 7 (the old mask-family rejection) stays reserved. */
            if (n > sizeof(struct sockaddr_in)) return bad_decode(out, 5);
            struct sockaddr_in mask; memset(&mask, 0, sizeof(mask));
            memcpy(&mask, bytes + offset, n);
            out->mask = ntohl(mask.sin_addr.s_addr); out->has_mask = 1;
        } else if (i == RTAX_DST || i == RTAX_GATEWAY) {
            if (family == AF_INET) {
                if (n > sizeof(struct sockaddr_in)) return bad_decode(out, 5);
                if (n < offsetof(struct sockaddr_in, sin_addr) + 4) return bad_decode(out, 6);
                struct sockaddr_in sa; memset(&sa, 0, sizeof(sa)); memcpy(&sa, bytes + offset, n);
                uint32_t ip = ntohl(sa.sin_addr.s_addr);
                if (i == RTAX_DST) { out->destination = ip; out->has_destination = 1; }
                if (i == RTAX_GATEWAY) { out->gateway = ip; out->has_gateway = 1; }
            } else if (i == RTAX_DST || family != AF_LINK) return bad_decode(out, 8);
        }
        if (i == RTAX_IFP) {
            if (family != AF_LINK || n < offsetof(struct sockaddr_dl, sdl_index) + sizeof(uint16_t)) return bad_decode(out, 9);
            uint16_t index; memcpy(&index, bytes + offset + offsetof(struct sockaddr_dl, sdl_index), sizeof(index));
            if (out->index && index && out->index != index) return bad_decode(out, 10);
            if (index) out->index = index;
        }
        offset += span;
    }
    if (offset != length || !out->has_destination) return bad_decode(out, 11);
    if (h->rtm_flags & RTF_HOST) {
        if (out->has_mask && out->mask != UINT32_MAX) return bad_decode(out, 12);
        out->prefix = 32; out->mask = UINT32_MAX;
    } else {
        unsigned bits = 0; uint32_t mask = out->mask;
        while (mask & 0x80000000u) { ++bits; mask <<= 1; }
        if (mask) return bad_decode(out, 13);
        out->prefix = bits;
    }
    if ((out->destination & out->mask) != out->destination) return bad_decode(out, 14);
    return 1;
}
static int same_key(const struct er_message *m, er_spec s) {
    return m->has_destination && m->destination == s.destination && m->prefix == s.prefix;
}
static int matches(const struct er_message *m, er_spec s) {
    const int required = RTF_UP | RTF_GATEWAY | RTF_STATIC | RTF_PROTO2;
    const int forbidden = RTF_IFSCOPE | RTF_REJECT | RTF_BLACKHOLE | RTF_LLINFO | RTF_WASCLONED | RTF_DYNAMIC | RTF_MODIFIED;
    return same_key(m, s) && m->has_gateway && m->gateway == s.gateway && m->index == s.interface_index &&
        (m->header.rtm_flags & required) == required && !(m->header.rtm_flags & forbidden);
}
/* Protocol-0 sockets also deliver IPv6 notifications. Only a fully framed,
 * explicitly IPv6 event can be unrelated to our IPv4 keys. This is classification,
 * not an IPv6 route plan/receipt. Unknown families and malformed frames still stop.
 * Matching replies never use this path: exchange() must decode them as IPv4. */
static int separate_ipv6_event(const unsigned char *bytes, size_t length) {
    struct rt_msghdr h;
    if (length < sizeof(h)) return 0;
    memcpy(&h, bytes, sizeof(h));
    if (h.rtm_msglen != length || h.rtm_version != RTM_VERSION || h.rtm_addrs < 0 ||
        ((unsigned)h.rtm_addrs >> RTAX_MAX) != 0 || !(h.rtm_addrs & RTA_DST)) return 0;
    size_t offset = sizeof(h);
    for (int i = 0; i < RTAX_MAX; ++i) {
        if (!(h.rtm_addrs & (1 << i))) continue;
        if (offset + 2 > length) return 0;
        size_t n = bytes[offset], span = aligned(n);
        if (span > length - offset) return 0;
        unsigned family = bytes[offset + 1];
        if (i == RTAX_NETMASK || i == RTAX_GENMASK) {
            if (n > sizeof(struct sockaddr_in6)) return 0;
        } else if (i == RTAX_DST) {
            if (n != sizeof(struct sockaddr_in6) || family != AF_INET6) return 0;
        } else if (family == AF_LINK) {
            const size_t data = offsetof(struct sockaddr_dl, sdl_data);
            if (n < data ||
                (size_t)bytes[offset + offsetof(struct sockaddr_dl, sdl_nlen)] +
                bytes[offset + offsetof(struct sockaddr_dl, sdl_alen)] +
                bytes[offset + offsetof(struct sockaddr_dl, sdl_slen)] > n - data) return 0;
        } else if (family != AF_INET6 || n != sizeof(struct sockaddr_in6) || i == RTAX_IFP) {
            return 0;
        }
        offset += span;
    }
    return offset == length;
}
static void poison(er_context *c) { c->poisoned = 1; for (int i = 0; i < c->used; ++i) c->owned[i].live = 0; }
/* External writes to the same key revoke the receipt even if they restore identical
 * fields. Readback alone never reactivates a revoked receipt. Interface changes are
 * independently detected by the shared observer; they confer no new delete rights. */
static int event(er_context *c, const unsigned char *b, size_t n) {
    if (n < 4) { diagnose(c, ER_REASON_EVENT, 0, 0); poison(c); return 0; }
    uint16_t length; memcpy(&length, b, 2);
    if (length != n || b[2] != RTM_VERSION) { diagnose(c, ER_REASON_EVENT, 0, 0); poison(c); return 0; }
    c->diagnostic.reply_type = b[3];
    switch (b[3]) {
    case RTM_ADD: case RTM_DELETE: case RTM_CHANGE: case RTM_LOCK: case RTM_REDIRECT: case RTM_RESOLVE: {
        struct er_message m;
        if (!decode(b, n, &m)) {
            if (separate_ipv6_event(b, n)) return 1;
            diagnose(c, ER_REASON_EVENT, m.decode_failure, 0); poison(c); return 0;
        }
        if (m.header.rtm_errno) return 1;
        for (int i = 0; i < c->used; ++i) if (same_key(&m, c->owned[i].spec)) c->owned[i].live = 0;
        return 1;
    }
    case RTM_GET: case RTM_MISS: case RTM_LOSING:
    case RTM_IFINFO: case RTM_NEWADDR: case RTM_DELADDR: case RTM_NEWMADDR: case RTM_DELMADDR:
        return 1;
    default: diagnose(c, ER_REASON_EVENT, 0, 0); poison(c); return 0;
    }
}
/* One datagram; reported truncation/overflow/unknown format poisons all receipts. */
static int receive(er_context *c, unsigned char *bytes, size_t *length) {
    struct iovec v = {bytes, ER_BYTES};
    struct msghdr msg; memset(&msg, 0, sizeof(msg)); msg.msg_iov = &v; msg.msg_iovlen = 1;
    ssize_t n = recvmsg(c->fd, &msg, MSG_DONTWAIT);
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
    if (n < 0 && errno == EINTR) return 0;
    if (n <= 0 || n > ER_BYTES || (msg.msg_flags & MSG_TRUNC)) {
        diagnose(c, (msg.msg_flags & MSG_TRUNC) ? ER_REASON_TRUNCATED : ER_REASON_RECEIVE, 0, n < 0 ? errno : 0);
        poison(c); return -1;
    }
    *length = (size_t)n; return 1;
}
int32_t er_drain(er_context *c) {
    if (!c) return 0;
    if (c->poisoned) { diagnose(c, ER_REASON_POISONED, 0, 0); return 0; }
    unsigned char bytes[ER_BYTES]; size_t n;
    for (unsigned i = 0; i < ER_EVENTS; ++i) {
        int r = receive(c, bytes, &n);
        if (r == 0) return 1;
        if (r < 0 || !event(c, bytes, n)) return 0;
    }
    diagnose(c, ER_REASON_EVENT_LIMIT, 0, 0); poison(c); return 0;
}
static int append(unsigned char *bytes, size_t *length, const void *sa, size_t n) {
    if (*length + aligned(n) > 512) return 0;
    memcpy(bytes + *length, sa, n); *length += aligned(n); return 1;
}
static int request(er_context *c, int type, er_spec s, unsigned char *bytes, size_t *length) {
    if (c->sequence == INT_MAX) return 0;
    memset(bytes, 0, 512); *length = sizeof(struct rt_msghdr);
    struct rt_msghdr h; memset(&h, 0, sizeof(h));
    h.rtm_version = RTM_VERSION; h.rtm_type = (unsigned char)type;
    h.rtm_pid = c->pid; h.rtm_seq = ++c->sequence;
    h.rtm_addrs = RTA_DST | RTA_IFP;
    struct sockaddr_in sa; memset(&sa, 0, sizeof(sa)); sa.sin_len = sizeof(sa); sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(s.destination);
    if (!append(bytes, length, &sa, sizeof(sa))) return 0;
    if (type != RTM_GET) {
        h.rtm_index = s.interface_index;
        h.rtm_flags = RTF_UP | RTF_GATEWAY | RTF_STATIC | RTF_PROTO2 | (s.prefix == 32 ? RTF_HOST : 0);
        h.rtm_addrs |= RTA_GATEWAY | RTA_NETMASK;
        sa.sin_addr.s_addr = htonl(s.gateway); if (!append(bytes, length, &sa, sizeof(sa))) return 0;
        sa.sin_addr.s_addr = htonl(prefix_mask(s.prefix)); if (!append(bytes, length, &sa, sizeof(sa))) return 0;
    }
    struct sockaddr_dl link; memset(&link, 0, sizeof(link)); link.sdl_len = sizeof(link); link.sdl_family = AF_LINK;
    link.sdl_index = type == RTM_GET ? 0 : s.interface_index;
    if (!append(bytes, length, &link, sizeof(link))) return 0;
    h.rtm_msglen = (unsigned short)*length; memcpy(bytes, &h, sizeof(h)); return 1;
}
/* Refusal requires the matching kernel response. A write syscall, log line or
 * exit code alone never creates a receipt. No resend follows any failure. */
static int exchange(er_context *c, int type, er_spec s, struct er_message *reply) {
    // This guard is in the lowest send path as well as in the public API.
    // A root caller cannot turn a query-only context into a write context.
    if (!c->writable && type != RTM_GET) { diagnose(c, ER_REASON_READ_ONLY, 0, 0); return 1; }
    if (!er_drain(c)) return 2;
    if (type == RTM_DELETE) {
        int owned = 0;
        for (int i = 0; i < c->used; ++i) if (c->owned[i].live &&
            c->owned[i].spec.destination == s.destination && c->owned[i].spec.prefix == s.prefix) owned = 1;
        if (!owned) { diagnose(c, ER_REASON_OWNERSHIP, 0, 0); return 1; } /* drain above may have revoked the checked receipt */
    }
    unsigned char message[512]; size_t length;
    if (!request(c, type, s, message, &length)) { diagnose(c, ER_REASON_REQUEST, 0, 0); return 1; }
    const int sequence = c->sequence;
    double start = er_continuous_seconds(), deadline = start + 2;
    if (start < 0) { diagnose(c, ER_REASON_CLOCK, 0, 0); poison(c); return 2; }
    if (type == RTM_ADD || type == RTM_DELETE) {
        if (c->mutation_attempts == UINT32_MAX) { diagnose(c, ER_REASON_REQUEST, 0, 0); return 1; }
        ++c->mutation_attempts; // BEFORE syscall, even a negative return can be ambiguous.
    }
    ssize_t sent = write(c->fd, message, length);
    const int send_errno = sent < 0 ? errno : 0;
    c->diagnostic.system_errno = send_errno;
    /* Darwin may return a kernel errno AND queue its reply. Still require the reply;
       an unconfirmed write remains unknown, never "not applied". */
    if (sent != (ssize_t)length && sent >= 0) { diagnose(c, ER_REASON_SEND, 0, 0); poison(c); return 2; }
    unsigned char bytes[ER_BYTES]; size_t n;
    for (unsigned count = 0; count < ER_EVENTS; ++count) {
        double now = er_continuous_seconds();
        if (now < start || now >= deadline) { diagnose(c, now < start ? ER_REASON_CLOCK : ER_REASON_TIMEOUT, 0, send_errno); poison(c); return 2; }
        struct pollfd p = {c->fd, POLLIN, 0};
        int polled = poll(&p, 1, (int)((deadline - now) * 1000) + 1);
        if (polled < 0 && errno == EINTR) continue;
        if (polled <= 0 || (p.revents & (POLLERR | POLLHUP | POLLNVAL))) {
            diagnose(c, polled == 0 ? ER_REASON_TIMEOUT : ER_REASON_POLL, 0, polled < 0 ? errno : send_errno);
            poison(c); return 2;
        }
        int got = receive(c, bytes, &n);
        if (got < 0) return 2;
        if (!got) continue;
        if (n >= sizeof(struct rt_msghdr)) {
            struct rt_msghdr h; memcpy(&h, bytes, sizeof(h));
            if (h.rtm_pid == c->pid && h.rtm_seq == sequence) {
                c->diagnostic.reply_type = h.rtm_type; c->diagnostic.reply_errno = h.rtm_errno;
                if (h.rtm_type != type) { diagnose(c, ER_REASON_REPLY_TYPE, 0, send_errno); poison(c); return 2; }
                if (!decode(bytes, n, reply)) { diagnose(c, ER_REASON_DECODE, reply->decode_failure, send_errno); poison(c); return 2; }
                int valid = type == RTM_GET ?
                    ((s.destination & reply->mask) == reply->destination) :
                    (same_key(reply, s) && reply->has_gateway && reply->gateway == s.gateway && reply->index == s.interface_index);
                if (!valid) { diagnose(c, ER_REASON_REPLY_KEY, 0, send_errno); poison(c); return 2; }
                if (h.rtm_errno) { diagnose(c, ER_REASON_KERNEL, 0, send_errno); return 1; }
                return 0;
            }
        }
        if (!event(c, bytes, n)) return 2;
    }
    diagnose(c, ER_REASON_EVENT_LIMIT, 0, send_errno); poison(c); return 2;
}
static er_context *open_context(int writable) {
    if (writable && (getuid() != 0 || geteuid() != 0)) return NULL;
    /* XNU can broadcast the echo of a full-length IPv4 ADD with protocol 0,
     * while GET/DELETE reports carry AF_INET. An AF_INET subscription silently
     * misses that ADD echo even after the kernel has installed the route.
     * Subscribe without a family filter; retain strict IPv4 reply matching and
     * classify unrelated IPv6 events separately. Do not disable SO_USELOOPBACK. */
    int fd = socket(PF_ROUTE, SOCK_RAW, 0);
    if (fd < 0) return NULL;
    int buffer = 262144;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || fcntl(fd, F_SETFL, O_NONBLOCK) < 0 ||
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, sizeof(buffer)) < 0) { close(fd); return NULL; }
    er_context *c = calloc(1, sizeof(*c));
    if (!c) { close(fd); return NULL; }
    c->fd = fd; c->pid = getpid(); c->writable = writable; return c;
}
er_context *er_open(void) { return open_context(1); }
er_context *er_open_query(void) { return open_context(0); }
void er_close(er_context *c) { if (c) { close(c->fd); memset(c, 0, sizeof(*c)); free(c); } }
int32_t er_owns(er_context *c, uint64_t token) {
    return c && !c->poisoned && token > 0 && token <= (uint64_t)c->used && c->owned[token - 1].live;
}
static int preflight(er_context *c, er_spec s) {
    struct er_message m;
    begin_stage(c, ER_STAGE_TARGET_GET);
    int r = exchange(c, RTM_GET, s, &m);
    if (r) return r;
    if (m.index != s.tunnel_index || m.prefix >= s.prefix || !(m.header.rtm_flags & RTF_UP) ||
        (m.header.rtm_flags & (RTF_REJECT | RTF_BLACKHOLE | RTF_IFSCOPE))) {
        diagnose(c, ER_REASON_TARGET_PATH, 0, 0); return 1;
    }
    er_spec gateway = s; gateway.destination = s.gateway;
    begin_stage(c, ER_STAGE_GATEWAY_GET);
    r = exchange(c, RTM_GET, gateway, &m);
    if (r) return r;
    if (m.index != s.interface_index || !(m.header.rtm_flags & RTF_UP) ||
        (m.header.rtm_flags & (RTF_REJECT | RTF_BLACKHOLE))) {
        diagnose(c, ER_REASON_GATEWAY_PATH, 0, 0); return 1;
    }
    return 0;
}
er_result er_probe(er_context *c, er_spec s) {
    if (!c) return result(1, 0);
    if (!spec_valid(s)) { diagnose(c, ER_REASON_INVALID, 0, 0); return result(1, 0); }
    // A successful probe creates no receipt or later permission to add/delete.
    return result(preflight(c, s), 0);
}
er_result er_add(er_context *c, er_spec s) {
    if (!c) return result(1, 0);
    if (!c->writable) { diagnose(c, ER_REASON_READ_ONLY, 0, 0); return result(3, 0); }
    if (!spec_valid(s) || c->used >= ER_LIMIT || c->poisoned) return result(1, 0);
    for (int i = 0; i < c->used; ++i) if (c->owned[i].spec.destination == s.destination && c->owned[i].spec.prefix == s.prefix) return result(1, 0);
    // A failed GET is uncertain observation, NOT an uncertain ADD.
    if (preflight(c, s)) return result(3, 0);
    struct er_message m;
    const uint32_t before = c->mutation_attempts;
    begin_stage(c, ER_STAGE_ADD);
    /* Occupy the slot BEFORE ADD so any interleaved same-key event invalidates it. */
    int slot = c->used++; c->owned[slot] = (struct er_owned){s, 1};
    int r = exchange(c, RTM_ADD, s, &m);
    if (r || !c->owned[slot].live || !matches(&m, s)) {
        if (!r) diagnose(c, ER_REASON_OWNERSHIP, 0, 0);
        c->owned[slot].live = 0;
        if (c->mutation_attempts == before) return result(3, 0);
        return result(r == 1 ? 1 : 2, 0);
    }
    return result(0, (uint64_t)slot + 1);
}
er_result er_remove(er_context *c, uint64_t token) {
    if (!c) return result(1, 0);
    if (!c->writable) { diagnose(c, ER_REASON_READ_ONLY, 0, 0); return result(1, 0); }
    begin_stage(c, ER_STAGE_REMOVE_GET);
    if (!er_drain(c) || !er_owns(c, token)) return result(1, 0);
    er_spec s = c->owned[token - 1].spec; struct er_message m;
    int r = exchange(c, RTM_GET, s, &m);
    if (r || !matches(&m, s) || !er_drain(c) || !er_owns(c, token)) return result(r == 2 ? 2 : 1, 0);
    /* No BSD CAS is available: the foreground trial requires a cooperative,
       controlled environment. A concurrent privileged replacement can still race. */
    begin_stage(c, ER_STAGE_DELETE);
    r = exchange(c, RTM_DELETE, s, &m);
    if (r == 0 && !c->owned[token - 1].live) r = 2;
    c->owned[token - 1].live = 0; /* No retry or second delete with this receipt. */
    return result(r, 0);
}
#else
/* No routing socket is ever opened on the offline-test platform. */
struct er_context { int unused; };
er_context *er_open(void) { return NULL; }
er_context *er_open_query(void) { return NULL; }
er_result er_probe(er_context *c, er_spec s) { (void)c; (void)s; return (er_result){1, 0}; }
er_diagnostic er_get_diagnostic(const er_context *c) { (void)c; er_diagnostic d = {0}; d.reason = ER_REASON_INVALID; return d; }
void er_close(er_context *c) { (void)c; }
int32_t er_drain(er_context *c) { (void)c; return 0; }
int32_t er_owns(er_context *c, uint64_t token) { (void)c; (void)token; return 0; }
er_result er_add(er_context *c, er_spec s) { (void)c; (void)s; return (er_result){1, 0}; }
er_result er_remove(er_context *c, uint64_t t) { (void)c; (void)t; return (er_result){1, 0}; }
double er_continuous_seconds(void) { struct timespec ts; return clock_gettime(CLOCK_MONOTONIC, &ts) == 0 ? ts.tv_sec + ts.tv_nsec / 1e9 : -1; }
#endif

static volatile sig_atomic_t stop_flag = 0;
static void stop_handler(int signal_number) { (void)signal_number; stop_flag = 1; }
void er_install_stop_handlers(void) {
    struct sigaction action; memset(&action, 0, sizeof(action));
    action.sa_handler = stop_handler; sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, NULL); sigaction(SIGTERM, &action, NULL); sigaction(SIGHUP, &action, NULL);
}
int32_t er_stop_requested(void) { return stop_flag != 0; }
int32_t er_console_confirm(void) {
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) return 0;
    double began = er_continuous_seconds();
    if (began < 0) return 0;
    char line[16]; size_t used = 0;
    while (!stop_flag && used < sizeof(line)) {
        double now = er_continuous_seconds();
        if (now < began || now - began >= 30) return 0;
        struct pollfd p = {STDIN_FILENO, POLLIN, 0};
        int ready = poll(&p, 1, 100);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0 || (p.revents & (POLLERR | POLLHUP | POLLNVAL))) return 0;
        if (!ready) continue;
        ssize_t n = read(STDIN_FILENO, line + used, 1);
        if (n != 1) return 0;
        if (line[used++] == '\n') return used == 6 && memcmp(line, "APPLY\n", 6) == 0;
    }
    return 0;
}
int32_t er_console_poll(void) {
    if (stop_flag) return 1;
    struct pollfd p = {STDIN_FILENO, POLLIN, 0};
    int ready = poll(&p, 1, 200);
    if (ready < 0 && errno == EINTR) return stop_flag != 0;
    return ready != 0; /* Any line/EOF/error terminates this finite lease. */
}
