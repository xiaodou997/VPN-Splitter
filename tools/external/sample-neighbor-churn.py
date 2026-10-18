#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only WASCLONED neighbor-cache churn sampler.

Samples the IPv4 routing table at a fixed cadence and records only *shapes*
(flag strings, prefix lengths, per-run salted hashes of row destinations) so
churn experiments (ADR-EX-INT-11 epoch exemption) can correlate observed
add/remove events with Helper lease_terminal epoch_added/epoch_removed shapes
without persisting raw LAN addresses. Never adds, deletes, or repairs routes.
"""
import argparse
import collections
import hashlib
import json
import os
import re
import subprocess
import time


def table_lines():
    try:
        result = subprocess.run(['/usr/sbin/netstat', '-rn', '-f', 'inet'],
                                capture_output=True, text=True, timeout=5)
        return result.stdout.splitlines() if result.returncode == 0 else []
    except subprocess.TimeoutExpired:
        return []


def rows_for(lines, interface):
    """Return {salted_destination: flag_text} for rows bound to the interface."""
    rows = {}
    in_inet = False
    for line in lines:
        if line.startswith('Internet:'):
            in_inet = True
            continue
        if line.startswith('Internet6:'):
            in_inet = False
            continue
        if not in_inet:
            continue
        fields = line.split()
        if len(fields) < 4 or fields[-1] != interface:
            continue
        destination, flags = fields[0], fields[2]
        rows[destination] = flags
    return rows


def shape_of(destination, flags):
    prefix = '/32' if destination.endswith('/32') else ('/other' if '/' in destination else '/host')
    cloned = 'cloned' if ('W' in flags or 'UHLWI' in flags) else 'other'
    return f'{cloned}{prefix}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--interface', required=True)
    parser.add_argument('--output', type=str, required=True)
    parser.add_argument('--seconds', type=int, default=600)
    parser.add_argument('--interval', type=float, default=5.0)
    args = parser.parse_args()
    if not re.fullmatch(r'en[0-9]+', args.interface):
        parser.error('requires a physical en interface')
    if not 1 <= args.seconds <= 7200 or not 0.5 <= args.interval <= 60:
        parser.error('duration 1..7200 s, interval 0.5..60 s')
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    salt = os.urandom(16)
    previous = {}
    start = time.monotonic()
    with os.fdopen(fd, 'w') as output:
        while time.monotonic() - start < args.seconds:
            begin = time.monotonic_ns()
            rows = rows_for(table_lines(), args.interface)
            fingerprints = {hashlib.sha256(salt + d.encode()).hexdigest()[:16]: (d, f)
                            for d, f in rows.items()}
            shapes = collections.Counter(shape_of(d, f) for d, f in rows.items())
            added = [fp for fp in fingerprints if fp not in previous]
            removed = [fp for fp in previous if fp not in fingerprints]
            churn_shapes = collections.Counter(
                shape_of(fingerprints[fp][0], fingerprints[fp][1]) for fp in added + removed)
            record = dict(sample_begin_ns=begin,
                          sample_end_ns=time.monotonic_ns(),
                          rows_total=len(rows),
                          cloned_rows=sum(n for s, n in shapes.items() if s.startswith('cloned')),
                          shapes=dict(shapes),
                          added_count=len(added), removed_count=len(removed),
                          churn_shapes=dict(churn_shapes),
                          network_writes='NONE', raw_addresses='NOT_RECORDED')
            output.write(json.dumps(record) + '\n'); output.flush()
            previous = fingerprints
            time.sleep(args.interval)
    print('sampler_finished=true; network_writes=NONE; raw_addresses=NOT_RECORDED')


if __name__ == '__main__':
    main()
