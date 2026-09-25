"""Synthetic/offline S0 tests. These do NOT certify macOS or VPN behavior."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/s0/collect-network.sh"
PARSER = ROOT / "tools/s0/route-hints.awk"
BASH = "/bin/bash"
AWK = shutil.which("awk")
HEADER = "Routing tables\n\nInternet:\nDestination Gateway Flags Netif Expire\n"


def shell(code, *args, timeout=15):
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"}
    return subprocess.run(
        [BASH, "--noprofile", "--norc", "-c", 'source "$1"; shift; ' + code,
         "s0-test", str(SCRIPT), *args],
        text=True, capture_output=True, env=env, timeout=timeout,
    )


class InputTests(unittest.TestCase):
    def test_syntax(self):
        subprocess.run([BASH, "-n", str(SCRIPT)], check=True)

    def test_ipv4_valid(self):
        for value in ["0.0.0.0", "192.0.2.1", "255.255.255.255"]:
            with self.subTest(value=value):
                self.assertEqual(shell('s0_ipv4 "$1"', value).returncode, 0)

    def test_ipv4_invalid(self):
        for value in ["", "example.invalid", "::1", "192.0.2.1/32", "256.1.1.1",
                      "1.2.3", "1.2.3.4.5", "01.2.3.4", "-n", "1.2.3.4;id",
                      "1.2.3.4\n", "9" * 500 + ".1.1.1"]:
            with self.subTest(value=value):
                self.assertNotEqual(shell('s0_ipv4 "$1"', value).returncode, 0)

    def test_help(self):
        p = shell('s0_main --help')
        self.assertEqual(p.returncode, 0)
        self.assertIn("PRIVATE", p.stdout)

    def test_bad_phase(self):
        self.assertEqual(shell('s0_main wrong').returncode, 64)

    def test_hostname_rejected_without_echo(self):
        p = shell('s0_main before "$1"', "private-host.example")
        self.assertEqual(p.returncode, 64)
        self.assertNotIn("private-host", p.stdout + p.stderr)

    def test_target_limit(self):
        p = shell('s0_main before "$@"', *(["192.0.2.1"] * 17))
        self.assertEqual(p.returncode, 64)

    @unittest.skipIf(os.uname().sysname == "Darwin", "Linux refusal test only")
    def test_non_darwin_refused(self):
        p = shell('s0_main before')
        self.assertEqual(p.returncode, 69)
        self.assertIn("no snapshot", p.stderr)
        self.assertFalse((ROOT / ".local").exists())

    def test_symlink_parent_refused(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "link"
            path.symlink_to(d, target_is_directory=True)
            self.assertNotEqual(shell('s0_private_dir "$1"', str(path)).returncode, 0)

    def test_dispatch_allowlist(self):
        p = shell('s0_capture() { printf "%s|" "$@"; printf "\\n"; }; s0_collect_all "$1"', "192.0.2.1")
        self.assertEqual(p.returncode, 0)
        rows = p.stdout.splitlines()
        self.assertEqual(len(rows), 14)
        self.assertIn("target_1|/sbin/route|-n|get|-inet|192.0.2.1|", rows)
        for row in rows:
            fields = row.split("|")
            self.assertTrue(fields[1].startswith("/"))
            if fields[1] == "/sbin/route":
                self.assertEqual(fields[2:4], ["-n", "get"])
            if fields[1] == "/usr/sbin/scutil":
                self.assertIn(fields[2:], [["--nwi", ""], ["--dns", ""], ["--proxy", ""], ["--nc", "list", ""]])

    def test_dispatch_stops_on_storage_failure(self):
        p = shell('s0_capture() { return 74; }; s0_collect_all; exit $?')
        self.assertEqual(p.returncode, 74)


class HintTests(unittest.TestCase):
    def hint(self, body, header=HEADER):
        p = subprocess.run([AWK, "-f", str(PARSER)], input=header + body,
                           text=True, capture_output=True, check=True)
        self.assertEqual(p.stderr, "")
        lines = p.stdout.strip().splitlines()
        self.assertEqual(lines[1:], ["compatibility=UNKNOWN", "actual_egress=NOT_TESTED"])
        return lines[0].split("=", 1)[1]

    def test_pair_with_scoped_bridges(self):
        self.assertEqual(self.hint("default 192.0.2.1 UGScg en0\n"
            "default link#90 UCSIg bridge7\n0/1 192.0.2.254 UGScg utun9\n"
            "128.0/1 192.0.2.254 UGSc utun9\n"), "SPLIT_DEFAULT_PAIR")

    def test_full_notation(self):
        self.assertEqual(self.hint("0.0.0.0/1 192.0.2.254 UGSc utun9\n"
            "128.0.0.0/1 192.0.2.254 UGSc utun9\n"), "SPLIT_DEFAULT_PAIR")

    def test_different_interfaces_not_pair(self):
        self.assertEqual(self.hint("0/1 192.0.2.254 UGSc utun9\n"
            "128.0/1 192.0.2.254 UGSc utun8\n"), "INCOMPLETE_OR_MIXED_PAIR")

    def test_different_gateways_not_pair(self):
        self.assertEqual(self.hint("0/1 192.0.2.254 UGSc utun9\n"
            "128.0/1 192.0.2.253 UGSc utun9\n"), "INCOMPLETE_OR_MIXED_PAIR")

    def test_single_half(self):
        self.assertEqual(self.hint("0/1 192.0.2.254 UGSc utun9\n"), "INCOMPLETE_OR_MIXED_PAIR")

    def test_tunnel_default(self):
        self.assertEqual(self.hint("default link#90 UGSc utun9\n"), "TUNNEL_DEFAULT")

    def test_scoped_reject_blackhole_down(self):
        for flags in ["UCSI", "UGR", "UGB", "GSc"]:
            with self.subTest(flags=flags):
                self.assertEqual(self.hint(f"default link#90 {flags} utun9\n"), "NONE_OBSERVED")

    def test_multiple_and_duplicate(self):
        self.assertEqual(self.hint("default link#90 UGSc utun9\n"
                                  "default link#91 UGSc utun8\n"), "MULTIPLE_CANDIDATES")
        self.assertEqual(self.hint("0/1 192.0.2.254 UGSc utun9\n"
            "0/1 192.0.2.254 UGSc utun9\n128.0/1 192.0.2.254 UGSc utun9\n"), "MULTIPLE_CANDIDATES")

    def test_unknown_format_and_empty(self):
        self.assertEqual(self.hint("", header=""), "UNKNOWN")
        self.assertEqual(self.hint(""), "UNKNOWN")
        self.assertEqual(self.hint("unexpected output\n"), "UNKNOWN")
        self.assertEqual(self.hint("default x UGSc utun9\n", header="Destination Gateway Flags Iface\n"), "UNKNOWN")

    def test_no_input_echo(self):
        result = self.hint("default PRIVATE_GATEWAY UGSc PRIVATE_INTERFACE\n")
        self.assertEqual(result, "NONE_OBSERVED")
        self.assertNotIn("PRIVATE", result)


class CaptureTests(unittest.TestCase):
    def run_capture(self, executable, *args, limit=3):
        with tempfile.TemporaryDirectory() as directory:
            p = shell('umask 077; S0_OUT=$1; shift; S0_CHILD=; S0_TIMEOUT=$1; shift; '
                      'S0_FAILURES=0; s0_capture sample "$@"', directory, str(limit), executable, *args)
            root = Path(directory)
            files = {f.name: f.read_text() for f in root.iterdir() if f.is_file()}
            modes = {f.name: f.stat().st_mode & 0o777 for f in root.iterdir() if f.is_file()}
            return p, files, modes

    def test_success_private_permissions(self):
        p, files, modes = self.run_capture("/bin/echo", "SYNTHETIC_SECRET")
        self.assertEqual(p.returncode, 0)
        self.assertEqual(files["commands.tsv"], "sample\tOK\t0\n")
        self.assertNotIn("SYNTHETIC_SECRET", p.stdout + p.stderr)
        self.assertEqual(set(modes.values()), {0o600})

    def test_nonzero(self):
        p, files, _ = self.run_capture("/bin/false")
        self.assertEqual(p.returncode, 0)  # capture completed, command did not succeed
        self.assertEqual(files["commands.tsv"], "sample\tFAILED\t1\n")

    def test_unavailable(self):
        _, files, _ = self.run_capture("/nonexistent/s0-test-command")
        self.assertEqual(files["commands.tsv"], "sample\tUNAVAILABLE\t127\n")

    def test_timeout(self):
        _, files, _ = self.run_capture("/bin/sleep", "5", limit=1)
        self.assertEqual(files["commands.tsv"], "sample\tTIMEOUT\t124\n")

    def test_summary_failed_route_is_unknown(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "commands.tsv").write_text("routes_v4\tFAILED\t1\n")
            Path(d, "routes_v4.txt").write_text("PRIVATE_DATA_DO_NOT_ECHO")
            p = shell('S0_OUT=$1; S0_FAILURES=1; s0_summary before "$2"', d, str(PARSER))
            self.assertEqual(p.returncode, 0)
            self.assertIn("ipv4_full_tunnel_hint=UNKNOWN", p.stdout)
            self.assertNotIn("PRIVATE_DATA", p.stdout + p.stderr)

    def test_interrupt_cleanup(self):
        with tempfile.TemporaryDirectory() as d:
            p = shell('S0_OUT=$1; /bin/sleep 20 & S0_CHILD=$!; child=$S0_CHILD; '
                      's0_abort; if kill -0 "$child" 2>/dev/null; then exit 1; fi', d)
            self.assertEqual(p.returncode, 0)
            self.assertEqual(Path(d, "capture-state.txt").read_text(), "INTERRUPTED\n")


if __name__ == "__main__":
    unittest.main()
