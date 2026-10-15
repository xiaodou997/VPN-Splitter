#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""STUN binding 检查：返回当前 UDP 出口公网 IP（RFC 5389 XOR-MAPPED-ADDRESS）。

仅用于本机真机验证 UDP relay 出口对照；不修改网络、不写文件、无第三方依赖。
用法：python3 tools/dev/stun_check.py [host] [port]
"""
import os
import socket
import struct
import sys

COOKIE = 0x2112A442


def main() -> int:
    host = sys.argv[1] if len(sys.argv) > 1 else "stun.l.google.com"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 19302
    txn = os.urandom(12)
    request = struct.pack(">HHI", 0x0001, 0, COOKIE) + txn
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(5)
    try:
        sock.sendto(request, (host, port))
        data, _ = sock.recvfrom(2048)
    except (OSError, socket.timeout) as exc:
        print(f"stun=ERROR {type(exc).__name__}")
        return 2
    finally:
        sock.close()
    if len(data) < 20:
        print("stun=ERROR short_response")
        return 2
    mtype, mlen, magic = struct.unpack(">HHI", data[:8])
    if mtype != 0x0101 or magic != COOKIE or data[8:20] != txn:
        print("stun=ERROR bad_response")
        return 2
    offset = 20
    while offset + 4 <= 20 + mlen:
        atype, alen = struct.unpack(">HH", data[offset:offset + 4])
        value = data[offset + 4:offset + 4 + alen]
        if atype == 0x0020 and len(value) >= 8 and value[1] == 0x01:
            port_out = struct.unpack(">H", value[2:4])[0] ^ (COOKIE >> 16)
            addr = socket.inet_ntoa(struct.pack(">I", struct.unpack(">I", value[4:8])[0] ^ COOKIE))
            print(f"stun=OK egress={addr} port={port_out}")
            return 0
        offset += 4 + ((alen + 3) & ~3)
    print("stun=ERROR no_xor_mapped_address")
    return 2


if __name__ == "__main__":
    sys.exit(main())
