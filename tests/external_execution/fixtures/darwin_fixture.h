/* SPDX-License-Identifier: MIT
 * TEST DOUBLE: model of required Darwin declarations. Not an SDK ABI fixture.
 * All route sockets, PID/UID, I/O and clocks below are simulated.
 */
#ifndef DARWIN_FIXTURE_H
#define DARWIN_FIXTURE_H
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stddef.h>
#include <unistd.h>
#include <poll.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
struct er_test_sockaddr_in { uint8_t sin_len, sin_family; uint16_t sin_port; struct in_addr sin_addr; unsigned char pad[8]; };
#define sockaddr_in er_test_sockaddr_in
struct sockaddr_dl { uint8_t sdl_len, sdl_family; uint16_t sdl_index; uint8_t sdl_type, sdl_nlen, sdl_alen, sdl_slen; char sdl_data[12]; };
struct rt_msghdr {
    uint16_t rtm_msglen; uint8_t rtm_version, rtm_type; uint16_t rtm_index, padding;
    int32_t rtm_flags, rtm_addrs; pid_t rtm_pid; int32_t rtm_seq, rtm_errno, rtm_use;
    uint32_t rtm_inits; uint32_t metrics[14];
};
#define RTM_VERSION 5
#define RTM_ADD 1
#define RTM_DELETE 2
#define RTM_CHANGE 3
#define RTM_GET 4
#define RTM_LOSING 5
#define RTM_REDIRECT 6
#define RTM_MISS 7
#define RTM_LOCK 8
#define RTM_RESOLVE 11
#define RTM_NEWADDR 12
#define RTM_DELADDR 13
#define RTM_IFINFO 14
#define RTM_NEWMADDR 15
#define RTM_DELMADDR 16
#define RTAX_MAX 8
#define RTAX_DST 0
#define RTAX_GATEWAY 1
#define RTAX_NETMASK 2
#define RTAX_IFP 4
#define RTA_DST (1 << RTAX_DST)
#define RTA_GATEWAY (1 << RTAX_GATEWAY)
#define RTA_NETMASK (1 << RTAX_NETMASK)
#define RTA_IFP (1 << RTAX_IFP)
#define RTF_UP 1
#define RTF_GATEWAY 2
#define RTF_HOST 4
#define RTF_REJECT 8
#define RTF_DYNAMIC 16
#define RTF_MODIFIED 32
#define RTF_LLINFO 1024
#define RTF_STATIC 2048
#define RTF_BLACKHOLE 4096
#define RTF_PROTO2 16384
#define RTF_WASCLONED 131072
#define RTF_IFSCOPE 16777216
#ifndef AF_LINK
#define AF_LINK 18
#endif
typedef struct { uint32_t numer, denom; } mach_timebase_info_data_t;
#define KERN_SUCCESS 0
int mach_timebase_info(mach_timebase_info_data_t *info);
uint64_t mach_continuous_time(void);
int fake_socket(int, int, int);
int fake_close(int);
int fake_fcntl(int, int, ...);
int fake_setsockopt(int, int, int, const void *, socklen_t);
uid_t fake_getuid(void);
uid_t fake_geteuid(void);
pid_t fake_getpid(void);
ssize_t fake_write(int, const void *, size_t);
ssize_t fake_recvmsg(int, struct msghdr *, int);
int fake_poll(struct pollfd *, nfds_t, int);
#define socket fake_socket
#define close fake_close
#define fcntl fake_fcntl
#define setsockopt fake_setsockopt
#define getuid fake_getuid
#define geteuid fake_geteuid
#define getpid fake_getpid
#define write fake_write
#define recvmsg fake_recvmsg
#define poll fake_poll
#endif
