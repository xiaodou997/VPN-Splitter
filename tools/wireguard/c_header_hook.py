# SPDX-License-Identifier: MIT
"""Make the pinned WireGuardKitC umbrella header self-contained for Clang modules."""
from __future__ import annotations
from pathlib import Path
from policy_hook import git_blob

HEADER_PATH = 'Sources/WireGuardKitC/WireGuardKitC.h'
HEADER_BLOB = '54e4783d40f3346f431f92ce6e970ae4024cd417'
PATCHED_HEADER_BLOB = '84c53f7068ef9d3665e7f53d851f388806877342'


def patch_c_header(data: bytes) -> bytes:
    if git_blob(data) != HEADER_BLOB:
        raise ValueError('E_WG_UPSTREAM_C_HEADER_CHANGED')
    # u_char/u_int16_t/u_int32_t are BSD aliases declared by this public header.
    # Do not depend on a Swift file importing Darwin first, rewrite structs,
    # invent typedefs, include SDK-private _types paths, or disable modules.
    result = data.replace(b'#include "key.h"\n',
                          b'#include <sys/types.h>\n\n#include "key.h"\n', 1)
    if git_blob(result) != PATCHED_HEADER_BLOB:
        raise ValueError('E_WG_C_HEADER_RESULT_CHANGED')
    return result


def prepare_c_header(apple: Path, lock: dict) -> str:
    """Patch this run's exported source only; original caches are not passed here."""
    if (lock['apple']['blobs'].get(HEADER_PATH) != HEADER_BLOB
            or lock.get('patched_c_header_blob') != PATCHED_HEADER_BLOB):
        raise ValueError('E_WG_C_HEADER_LOCK')
    header = apple / HEADER_PATH
    current = header
    while True:
        if current.is_symlink():
            raise ValueError('E_WG_C_HEADER_PATH')
        if current == apple:
            break
        current = current.parent
    if not header.is_file():
        raise ValueError('E_WG_C_HEADER_PATH')
    # Validate both hashes and the lock before any write. The file is freshly
    # exported by build.py; no reuse of partially patched snapshots is allowed.
    modified = patch_c_header(header.read_bytes())
    header.write_bytes(modified)
    return git_blob(modified)
