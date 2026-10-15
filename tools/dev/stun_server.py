#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""STUN 应答替身：本机 LAN  UDP 服务，对 binding request 回合法 response，
XOR-MAPPED-ADDRESS 固定写本机 en0 地址（证明报文走了哪条路径回来）。
仅用于本机真机验证 UDP relay 数据面；不修改网络。
用法：python3 tools/dev/stun_server.py [listen_port] [advertised_ip]
"""
import socket
import struct
import sys

COOKIE = 0x2112A442


def main() -> int:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9999
    advertise = sys.argv[2] if len(sys.argv) > 2 else "192.168.2.28"
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", port))
    sock.settimeout(120)
    print(f"listening :{port} advertise={advertise}", flush=True)
    try:
        data, peer = sock.recvfrom(2048)
    except socket.timeout:
        print("stun_server=TIMEOUT")
        return 2
    if len(data) < 20 or data[4:8] != struct.pack(">I", COOKIE):
        print("stun_server=ERROR bad_request")
        return 2
    xip = struct.unpack(">I", socket.inet_aton(advertise))[0] ^ COOKIE
    attr = struct.pack(">HHBBH", 0x0020, 8, 0, 0x01, 9999 ^ (COOKIE >> 16)) + struct.pack(">I", xip)
    response = struct.pack(">HHI", 0x0101, len(attr), COOKIE) + data[8:20] + attr
    sock.sendto(response, peer)
    print(f"stun_server=ANSWERED peer={peer[0]}:{peer[1]}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
