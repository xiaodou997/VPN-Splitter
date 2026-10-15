// SPDX-License-Identifier: MIT
// STUN binding 检查（RFC 5389 XOR-MAPPED-ADDRESS）：打印 UDP 出口公网 IP。
// 仅用于本机真机验证 UDP relay 出口对照；不修改网络、不写文件。
#include <arpa/inet.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *host = argc > 1 ? argv[1] : "stun.l.google.com";
    const char *port = argc > 2 ? argv[2] : "19302";
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    if (getaddrinfo(host, port, &hints, &res) || !res) { puts("stun=ERROR resolve"); return 2; }
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct timeval tv = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    unsigned char req[20] = {0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42};
    arc4random_buf(req + 8, 12);
    if (sendto(fd, req, sizeof(req), 0, res->ai_addr, res->ai_addrlen) < 0) {
        puts("stun=ERROR send"); return 2;
    }
    unsigned char buf[2048];
    ssize_t n = recv(fd, buf, sizeof(buf), 0);
    freeaddrinfo(res);
    close(fd);
    if (n < 20 || buf[0] != 0x01 || buf[1] != 0x01 || memcmp(buf + 8, req + 8, 12)) {
        puts("stun=ERROR response"); return 2;
    }
    unsigned mlen = (buf[2] << 8) | buf[3];
    for (unsigned off = 20; off + 4 <= 20 + mlen && off + 4 <= (unsigned)n;) {
        unsigned atype = (buf[off] << 8) | buf[off + 1];
        unsigned alen = (buf[off + 2] << 8) | buf[off + 3];
        unsigned char *v = buf + off + 4;
        if (atype == 0x0020 && alen >= 8 && v[1] == 0x01) {
            unsigned short p = ((v[2] << 8) | v[3]) ^ 0x2112;
            unsigned a = ((unsigned)v[4] << 24 | v[5] << 16 | v[6] << 8 | v[7]) ^ 0x2112A442u;
            printf("stun=OK egress=%u.%u.%u.%u port=%u\n",
                   (a >> 24) & 255, (a >> 16) & 255, (a >> 8) & 255, a & 255, p);
            return 0;
        }
        off += 4 + ((alen + 3) & ~3u);
    }
    puts("stun=ERROR no_xor_mapped_address");
    return 2;
}
