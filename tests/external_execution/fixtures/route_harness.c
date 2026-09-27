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
static uint64_t clock_ns;
static er_spec table[8]; static int table_count;
static er_spec specimen(void) { return (er_spec){0xc6336404u, 0xc0000201u, 2, 9, 32}; }
static void reset(void) {
    head = tail = add_calls = delete_calls = fail_add = suppress_reply = wrong_seq = wrong_type = wrong_index = 0;
    inject_after_get = table_count = sockets = closes = 0; root = 1; clock_ns = 1000000000ull;
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
static void enqueue(er_spec spec, int type, int sequence, pid_t pid, int error, int flags) {
    assert(tail < 32);
    er_context dummy; memset(&dummy, 0, sizeof(dummy)); dummy.pid = pid;
    size_t length;
    assert(request(&dummy, RTM_ADD, spec, messages[tail].bytes, &length));
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
        enqueue(s, RTM_GET, h.rtm_seq, h.rtm_pid, 0, flags);
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
    enqueue(s, RTM_DELETE, h.rtm_seq, h.rtm_pid, 0, -1); return (ssize_t)n;
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
    printf("routing-socket-adapter=PASS scenarios=%d source=ACTUAL darwin_kernel_io=TEST_DOUBLES network=NOT_APPLIED\n", scenarios);
    return 0;
}
