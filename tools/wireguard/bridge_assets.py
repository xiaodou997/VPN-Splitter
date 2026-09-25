# SPDX-License-Identifier: MIT
"""Verify the thin Go bridge and stage only the reviewed files, never the engine."""
from __future__ import annotations
from pathlib import Path
from policy_hook import git_blob

BRIDGE_DIRECTORY = 'tools/wireguard/bridge'
BRIDGE_FILES = frozenset({'api-apple.go', 'lifecycle.go', 'lifecycle_test.go'})
UPSTREAM_BRIDGE_BLOB = '5d24982ac5b71ba0ab84afe972652a2d4f8549e5'
PATCH_PATH = 'third-party/wireguard-apple/patches/0003-bridge-ownership.patch'


def read_ordinary(root: Path, relative: str) -> bytes:
    target = root / relative
    current = target
    while current != root:
        if current.is_symlink():
            raise ValueError('E_WG_BRIDGE_SYMLINK')
        current = current.parent
    if not target.is_file():
        raise ValueError('E_WG_BRIDGE_MISSING')
    return target.read_bytes()


def checked_bridge(root: Path, lock: dict) -> dict[str, bytes]:
    spec = lock['bridge']
    if set(spec['files']) != BRIDGE_FILES:
        raise ValueError('E_WG_BRIDGE_FILE_SET')
    result = {}
    for name in sorted(BRIDGE_FILES):
        data = read_ordinary(root, BRIDGE_DIRECTORY + '/' + name)
        if git_blob(data) != spec['files'][name]:
            raise ValueError('E_WG_BRIDGE_SOURCE_CHANGED')
        result[name] = data
    hook = read_ordinary(root, 'tools/wireguard/bridge_assets.py')
    if git_blob(hook) != spec['installer_blob']:
        raise ValueError('E_WG_BRIDGE_INSTALLER_CHANGED')
    if git_blob(read_ordinary(root, PATCH_PATH)) != spec['review_patch_blob']:
        raise ValueError('E_WG_BRIDGE_REVIEW_CHANGED')
    revision = 'const splitterEngineRevision = "' + lock['engine']['revision'] + '"'
    if revision.encode() not in result['api-apple.go']:
        raise ValueError('E_WG_BRIDGE_ENGINE_IDENTITY')
    if lock['apple']['blobs'].get('Sources/WireGuardKitGo/api-apple.go') != UPSTREAM_BRIDGE_BLOB:
        raise ValueError('E_WG_BRIDGE_BASE_CHANGED')
    return result


def stage_bridge(sources: dict[str, bytes], upstream: bytes, destination: Path) -> None:
    if git_blob(upstream) != UPSTREAM_BRIDGE_BLOB:
        raise ValueError('E_WG_BRIDGE_BASE_CHANGED')
    if set(sources) != BRIDGE_FILES:
        raise ValueError('E_WG_BRIDGE_FILE_SET')
    # No overwrite or merge with an old build. The public-source export is unchanged.
    destination.mkdir(mode=0o700)
    for name, data in sorted(sources.items()):
        with (destination / name).open('xb') as output:
            output.write(data)
