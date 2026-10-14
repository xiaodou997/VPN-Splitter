#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Bounded read-only timing evidence; never applies, stops, or repairs routes."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import time


def query(args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=2)
        return result.stdout.strip() if result.returncode == 0 else None
    except subprocess.TimeoutExpired:
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target-file', type=Path, required=True)
    parser.add_argument('--interface', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--seconds', type=int, default=80)
    args = parser.parse_args()
    if not re.fullmatch(r'en[0-9]+', args.interface) or not 1 <= args.seconds <= 120:
        parser.error('requires a physical en interface and duration 1..120 seconds')
    target = str(ipaddress.IPv4Address(args.target_file.read_text().strip()))
    # Keep raw local address/router only in memory; do not hash or publish them.
    def physical():
        return (query(['/usr/sbin/ipconfig', 'getifaddr', args.interface]),
                query(['/usr/sbin/ipconfig', 'getoption', args.interface, 'router']))
    baseline = physical()
    if not all(baseline):
        raise SystemExit('physical_baseline_unavailable; no monitoring started')
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    start = time.monotonic()
    with os.fdopen(fd, 'w') as output:
        while time.monotonic() - start < args.seconds:
            before = time.monotonic_ns()
            values = physical()
            route = query(['/sbin/route', '-n', 'get', target])
            match = re.search(r'^\s*interface:\s*(\S+)', route or '', re.M)
            interface = match.group(1) if match else None
            kind = ('physical' if interface == args.interface else
                    'tunnel' if interface and re.fullmatch(r'utun[0-9]+', interface) else 'other_or_unknown')
            record = dict(sample_begin_ns=before, sample_end_ns=time.monotonic_ns(),
                          physical_observed=all(values),
                          physical_changed=(values != baseline) if all(values) else None,
                          target_path=kind)
            output.write(json.dumps(record) + '\n'); output.flush()
            time.sleep(.25)
    print('monitor_finished=true; network_writes=NONE; raw_addresses=NOT_RECORDED')


if __name__ == '__main__':
    main()
