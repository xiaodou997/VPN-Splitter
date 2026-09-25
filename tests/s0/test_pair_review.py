# SPDX-License-Identifier: MIT
"""Synthetic offline checks only; no live macOS or network operations."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "tools" / "s0"
COMMANDS = ("os architecture interfaces routes_v4 routes_v6 default_v4 default_v6 "
            "nwi dns proxy vpn_services extensions hardware_ports").split()
HEADER = "Routing tables\n\nInternet:\nDestination Gateway Flags Netif Expire\n"
PHYSICAL = "default 192.0.2.1 UGScg en7\n"
PAIR = "0/1 198.51.100.1 UGScg utun9\n128.0/1 198.51.100.1 UGSc utun9\n"
IFACES = "en7: flags=8863<UP,BROADCAST,RUNNING,MULTICAST> mtu 1500\n\tinet 192.0.2.2 netmask 0xffffff00 broadcast 192.0.2.255\n\tstatus: active\n"
LOOKUP = "route to: default\ndestination: default\ngateway: 192.0.2.1\ninterface: en7\nflags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>\n"


def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(0o600)


class PairReviewTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="s0-pair-tests-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.tools = self.root / "tools" / "s0"
        self.tools.mkdir(parents=True)
        for name in ("review-pair.sh", "pair-paths.awk"):
            shutil.copy2(TOOLS / name, self.tools / name)
        (self.root / ".local").mkdir(mode=0o700)
        self.base = self.root / ".local" / "s0"
        self.base.mkdir(mode=0o700)
        self.before = self.snapshot("before", "AAAAAA", PHYSICAL, "10:00:00", "10:01:00")
        self.after = self.snapshot("after", "BBBBBB", PHYSICAL + PAIR, "10:02:00", "10:03:00")

    def snapshot(self, phase, suffix, routes, start, end):
        directory = self.base / f"{phase}.{suffix}"
        directory.mkdir(mode=0o700)
        data = {
            "capture-state.txt": "CAPTURED\n",
            "commands.tsv": "name\tresult\texit_code\n" + "".join(f"{n}\tOK\t0\n" for n in COMMANDS),
            "share-summary.txt": f"schema=s0-summary-v1\nphase={phase}\ncapture_failed_commands=0\n",
            "started-utc.txt": f"2026-09-25T{start}Z\n",
            "finished-utc.txt": f"2026-09-25T{end}Z\n",
            "routes_v4.txt": HEADER + routes,
            "default_v4.txt": LOOKUP,
            "interfaces.txt": IFACES,
            "hardware_ports.txt": "Hardware Port: Ethernet\nDevice: en7\nEthernet Address: 00:00:00:00:00:01\n",
            "dns.txt": "DNS configuration\nresolver #1\n  nameserver[0] : 192.0.2.53\n",
            "proxy.txt": "<dictionary> {\n}\n",
            "extensions.txt": "0 extension(s)\n",
            "os.txt": "ProductName: macOS\nProductVersion: 26.0\nBuildVersion: SYNTHETIC\n",
            "architecture.txt": "arm64\n",
        }
        for name, text in data.items():
            write(directory / name, text)
        return directory

    def run_tool(self, *args):
        result = subprocess.run(["/bin/bash", str(self.tools / "review-pair.sh"), *args],
                                capture_output=True, text=True, timeout=10)
        fields = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        return result, fields

    def changed(self, directory, filename, old, new):
        p = directory / filename
        write(p, p.read_text().replace(old, new))

    def review_required(self):
        result, fields = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(fields["pair_readiness"], "REVIEW_REQUIRED")
        self.assertEqual(fields["compatibility"], "UNKNOWN")
        return fields

    def test_normal_pair_is_candidate_not_authorization(self):
        result, fields = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(fields["pair_readiness"], "CANDIDATE_REQUIRES_LIVE_PREFLIGHT")
        self.assertEqual(fields["live_state"], "NOT_CHECKED")
        self.assertEqual(fields["compatibility"], "UNKNOWN")
        self.assertEqual(fields["actual_egress"], "NOT_TESTED")
        self.assertEqual(fields["network_mutations"], "NONE")

    def test_private_identifiers_never_in_summary(self):
        write(self.after / "dns.txt", "secret.company.invalid 203.0.113.31\n")
        write(self.after / "extensions.txt", "1 extension(s)\n* * PRIVATE-TEAM secret.bundle.app\n")
        result, fields = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(fields["dns_snapshot"], "CHANGED_TEXT")
        self.assertEqual(fields["network_extensions_after"], "PRESENT_REVIEW_LOCALLY")
        for secret in ("192.0.2.1", "198.51.100.1", "en7", "utun9", "PRIVATE-TEAM", "secret.company.invalid", "secret.bundle"):
            self.assertNotIn(secret, result.stdout)
        report = next(self.base.glob("pair-review.*"))
        details = report / "path-candidates.private.tsv"
        self.assertIn("192.0.2.1", details.read_text())
        self.assertEqual(report.stat().st_mode & 0o777, 0o700)
        self.assertEqual(details.stat().st_mode & 0o777, 0o600)
        self.assertEqual((report / "share-summary.txt").stat().st_mode & 0o777, 0o600)

    def test_two_before_snapshots_require_selection(self):
        self.snapshot("before", "CCCCCC", PHYSICAL, "09:00:00", "09:01:00")
        result, _ = self.run_tool()
        self.assertEqual(result.returncode, 64)
        result, fields = self.run_tool(self.before.name, self.after.name)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(fields["input_pair"], "VALID_CAPTURE_FILES")

    def test_missing_pair(self):
        shutil.rmtree(self.before)
        self.assertEqual(self.run_tool()[0].returncode, 64)

    def test_no_traversal_or_phase_reversal(self):
        for args in (("../before.AAAAAA", self.after.name), (self.after.name, self.before.name)):
            self.assertEqual(self.run_tool(*args)[0].returncode, 64)

    def test_symlink_input_file_rejected(self):
        p = self.after / "dns.txt"
        p.unlink()
        p.symlink_to(self.before / "dns.txt")
        self.assertEqual(self.run_tool()[0].returncode, 65)

    def test_symlink_directory_rejected(self):
        real = self.base / "saved"
        self.before.rename(real)
        self.before.symlink_to(real, target_is_directory=True)
        self.assertEqual(self.run_tool()[0].returncode, 65)

    def test_world_readable_raw_file_rejected(self):
        (self.after / "routes_v4.txt").chmod(0o644)
        self.assertEqual(self.run_tool()[0].returncode, 65)

    def test_unsafe_parent_rejected(self):
        self.base.chmod(0o755)
        self.assertEqual(self.run_tool()[0].returncode, 73)

    def test_partial_and_forged_command_status_rejected(self):
        write(self.after / "capture-state.txt", "PARTIAL\n")
        self.assertEqual(self.run_tool()[0].returncode, 65)
        write(self.after / "capture-state.txt", "CAPTURED\n")
        self.changed(self.after, "commands.tsv", "dns\tOK\t0", "dns\tFAILED\t1")
        self.assertEqual(self.run_tool()[0].returncode, 65)

    def test_missing_or_duplicate_command_rejected(self):
        p = self.after / "commands.tsv"
        original = p.read_text()
        write(p, original.replace("dns\tOK\t0\n", ""))
        self.assertEqual(self.run_tool()[0].returncode, 65)
        write(p, original + "dns\tOK\t0\n")
        self.assertEqual(self.run_tool()[0].returncode, 65)

    def test_unknown_schema_and_duplicate_phase_rejected(self):
        p = self.after / "share-summary.txt"
        original = p.read_text()
        write(p, original.replace("s0-summary-v1", "s0-summary-v99"))
        self.assertEqual(self.run_tool()[0].returncode, 65)
        write(p, original + "phase=after\n")
        self.assertEqual(self.run_tool()[0].returncode, 65)

    def test_overlap_rejected(self):
        write(self.before / "finished-utc.txt", "2026-09-25T10:02:01Z\n")
        self.assertEqual(self.run_tool()[0].returncode, 65)

    def test_missing_header_is_not_candidate(self):
        write(self.after / "routes_v4.txt", PHYSICAL + PAIR)
        self.assertEqual(self.review_required()["physical_default_before"], "UNKNOWN")

    def test_malformed_route_table_is_not_candidate(self):
        write(self.after / "routes_v4.txt", HEADER + PHYSICAL + PAIR + "partial\n")
        self.review_required()

    def test_ambiguous_physical_default(self):
        write(self.before / "routes_v4.txt", HEADER + PHYSICAL + "default 203.0.113.1 UGScg en8\n")
        self.assertEqual(self.review_required()["physical_default_before"], "AMBIGUOUS")

    def test_scoped_defaults_do_not_create_ambiguity(self):
        write(self.before / "routes_v4.txt", HEADER + PHYSICAL + "default 203.0.113.1 UGScIg en8\n")
        self.assertEqual(self.run_tool()[1]["physical_default_before"], "UNIQUE")

    def test_changed_physical_gateway(self):
        self.changed(self.after, "routes_v4.txt", "192.0.2.1", "192.0.2.254")
        self.assertEqual(self.review_required()["physical_default_continuity"], "CHANGED")

    def test_scoped_or_rejected_half_not_accepted(self):
        original = (self.after / "routes_v4.txt").read_text()
        for flag in ("UGScIg", "UGScR", "UGScB", "GSc"):
            write(self.after / "routes_v4.txt", original.replace("198.51.100.1 UGScg", f"198.51.100.1 {flag}"))
            self.review_required()

    def test_different_tunnel_or_gateway_halves(self):
        original = (self.after / "routes_v4.txt").read_text()
        for replacement in ("128.0/1 198.51.100.2 UGSc utun9", "128.0/1 198.51.100.1 UGSc utun10"):
            write(self.after / "routes_v4.txt", original.replace("128.0/1 198.51.100.1 UGSc utun9", replacement))
            self.review_required()

    def test_duplicate_half_and_extra_tunnel(self):
        write(self.after / "routes_v4.txt", HEADER + PHYSICAL + PAIR + "0/1 198.51.100.1 UGSc utun9\n")
        self.review_required()
        write(self.after / "routes_v4.txt", HEADER + PHYSICAL + PAIR + "10/8 link#99 U utun10\n")
        self.assertEqual(self.review_required()["other_ipv4_tunnel_routes"], "REVIEW_REQUIRED")

    def test_tunnel_in_before_is_not_clean_baseline(self):
        write(self.before / "routes_v4.txt", HEADER + PHYSICAL + "10/8 link#99 U utun8\n")
        self.review_required()

    def test_lookup_must_agree(self):
        self.changed(self.after, "default_v4.txt", "en7", "utun9")
        self.assertEqual(self.review_required()["default_lookup_after"], "DIFFERENT_OR_UNKNOWN")

    def test_inactive_interface(self):
        self.changed(self.after, "interfaces.txt", "status: active", "status: inactive")
        self.assertEqual(self.review_required()["physical_interface_activity"], "UNKNOWN")

    def test_missing_hardware_mapping(self):
        self.changed(self.after, "hardware_ports.txt", "en7", "en8")
        self.review_required()

    def test_changed_ipv4_address_or_os(self):
        self.changed(self.after, "interfaces.txt", "192.0.2.2", "192.0.2.3")
        self.assertEqual(self.review_required()["physical_ipv4_addresses"], "CHANGED")
        write(self.after / "interfaces.txt", IFACES)
        self.changed(self.after, "os.txt", "26.0", "26.1")
        self.review_required()

    def test_no_input_changes(self):
        originals = {p: p.read_bytes() for d in (self.before, self.after) for p in d.iterdir()}
        self.assertEqual(self.run_tool()[0].returncode, 0)
        for path, content in originals.items():
            self.assertEqual(path.read_bytes(), content)

    def test_invalid_gateway_never_emitted(self):
        self.changed(self.before, "routes_v4.txt", "192.0.2.1", "bad.command")
        result, fields = self.run_tool()
        self.assertEqual(fields["pair_readiness"], "REVIEW_REQUIRED")
        self.assertNotIn("bad.command", result.stdout)

    def test_path_with_spaces(self):
        # The temporary parent may contain spaces without leaking identifiers.
        moved = self.root.with_name(self.root.name + " space")
        self.root.rename(moved)
        self.addCleanup(lambda: shutil.rmtree(moved, ignore_errors=True))
        self.tools = moved / "tools" / "s0"
        self.assertEqual(self.run_tool()[0].returncode, 0)

    def test_help_needs_no_snapshots(self):
        shutil.rmtree(self.base)
        self.assertEqual(self.run_tool("--help")[0].returncode, 0)


if __name__ == "__main__":
    unittest.main()
