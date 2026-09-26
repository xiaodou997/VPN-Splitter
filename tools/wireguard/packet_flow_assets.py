# SPDX-License-Identifier: MIT
"""Explicit packetFlow build candidate; existing descriptor builds stay unchanged."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path

LOCK = 'third-party/wireguard-go/packet-flow-lock.json'
UPSTREAM = {
    'Sources/Shared/Model/TunnelConfiguration+WgQuickConfig.swift': '86af010c69c5f2dc59a3585386ad394af846705f',
    'Sources/Shared/Model/String+ArrayConversion.swift': '97984f82ef0cfb5d19f20cd5be387260691ab61a',
    'Sources/WireGuardKitGo/wireguard.h': 'fdb66c2dee8ae74067501bc31dc6548e9d6f40cf',
}
EXTRA_APPLE_PATHS = [p for p in UPSTREAM if p.startswith('Sources/Shared/')]
GO_FILES = ['packet-flow-api.go', 'packet-flow-queue.go', 'packet-flow-tun.go', 'packet-flow-queue_test.go']
NATIVE_FILES = ['SplitterNativeConfiguration.swift', 'SplitterPacketFlowBackend.swift', 'splitter-packet-flow.h']
SOURCES = (['tools/wireguard/bridge/' + name for name in GO_FILES] +
           ['tools/wireguard/native/' + name for name in NATIVE_FILES] +
           ['integrations/wireguard/ManagedWireGuardNativeInput.swift', 'tools/wireguard/packet_flow_assets.py'])
FLOW_SYMBOLS = {'_wgTurnOnPacketFlow', '_wgTurnOffPacketFlow', '_wgReadPacketFlow', '_wgWritePacketFlow'}


def blob(data: bytes) -> str:
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()


def ordinary(root: Path, relative: str) -> bytes:
    path = root / relative
    cursor = path
    while cursor != root:
        if cursor.is_symlink():
            raise ValueError('E_PACKET_FLOW_SYMLINK')
        cursor = cursor.parent
    if not path.is_file():
        raise ValueError('E_PACKET_FLOW_MISSING')
    return path.read_bytes()


def checked_packet_flow(root: Path, base_lock: dict) -> dict:
    lock = json.loads(ordinary(root, LOCK))
    if (lock.get('schema') != 'packet-flow-build-v1' or lock.get('upstream') != UPSTREAM or
            set(lock.get('sources', {})) != set(SOURCES) or
            lock.get('apple_revision') != base_lock['apple']['revision'] or
            lock.get('engine_revision') != base_lock['engine']['revision']):
        raise ValueError('E_PACKET_FLOW_LOCK')
    for path, expected in lock['sources'].items():
        if blob(ordinary(root, path)) != expected:
            raise ValueError('E_PACKET_FLOW_SOURCE_CHANGED')
    return lock


def stage_packet_flow(root: Path, base_lock: dict, apple: Path, bridge: Path) -> None:
    checked_packet_flow(root, base_lock)
    originals = {path: ordinary(apple, path) for path in UPSTREAM}
    if any(blob(originals[p]) != expected for p, expected in UPSTREAM.items()):
        raise ValueError('E_PACKET_FLOW_UPSTREAM_CHANGED')
    output = {}
    for path in EXTRA_APPLE_PATHS:
        output[apple / 'Sources/WireGuardKit' / Path(path).name] = originals[path]
    for name in NATIVE_FILES:
        folder = 'WireGuardKitGo' if name.endswith('.h') else 'WireGuardKit'
        output[apple / 'Sources' / folder / name] = ordinary(root, 'tools/wireguard/native/' + name)
    for name in GO_FILES:
        output[bridge / name] = ordinary(root, 'tools/wireguard/bridge/' + name)
    # Validate every destination before writing. Build workspaces are private exports,
    # never the original source cache, installed application, or system interface.
    if any(path.exists() or path.is_symlink() for path in output):
        raise ValueError('E_PACKET_FLOW_DESTINATION_EXISTS')
    for path, data in output.items():
        with path.open('xb') as target:
            target.write(data)
    header = apple / 'Sources/WireGuardKitGo/wireguard.h'
    header.write_bytes(originals['Sources/WireGuardKitGo/wireguard.h'] +
                       b'\n// VPN-Splitter public packetFlow ABI (separate from descriptor ABI).\n#include "splitter-packet-flow.h"\n')


def require_packet_flow_symbols(text: str) -> None:
    defined = set()
    for line in text.splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[-2] != 'U':
            try:
                int(fields[-3], 16)
            except ValueError:
                continue
            defined.add(fields[-1])
    if not FLOW_SYMBOLS <= defined:
        raise ValueError('E_PACKET_FLOW_LINK_SYMBOLS')
