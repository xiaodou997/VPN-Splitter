# SPDX-License-Identifier: MIT
"""Synthetic parser/decision tests; never call macOS commands or modify networking."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/s0/preflight-target.sh"
D, V = "93.184.216.34", "10.90.0.9"  # String fixtures only, never contacted.
ROUTES = """Routing tables

Internet:
Destination Gateway Flags Netif Expire
0/1 100.64.55.1 UGScg utun7
128.0/1 100.64.55.1 UGSc utun7
default 10.20.0.1 UGScg en2
default link#40 UCSIg bridge100 !
10.20  link#4 UC en2
100.64.55.2 100.64.55.2 UH utun7
"""
INTERFACES = """en2: flags=8863<UP,BROADCAST,RUNNING,MULTICAST> mtu 1500
    inet 10.20.0.9 netmask 0xffffff00 broadcast 10.20.0.255
    status: active
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
    inet 100.64.55.2 --> 100.64.55.2 netmask 0xffffff00
"""


def lookup(dev="utun7", gw="100.64.55.1", flags="UP,GATEWAY,DONE,STATIC"):
    return f"   route to: {D}\n destination: default\n gateway: {gw}\n interface: {dev}\n flags: <{flags}>\n"


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

    def run_fn(self, name, *args):
        return subprocess.run(
            ["/bin/bash", "-c", 'source "$1"; shift; "$@"', "test", str(SCRIPT), name, *map(str, args)],
            text=True, capture_output=True, timeout=5, check=False)

    def write(self, name, text):
        p = self.dir / name
        p.write_text(text, encoding="utf-8")
        return p

    def fixture(self):
        self.write("routes_start.txt", ROUTES)
        self.write("routes_end.txt", ROUTES)
        paths = self.run_fn("pf_paths", self.dir / "routes_start.txt")
        self.assertEqual(paths.returncode, 0, paths.stderr)
        self.write("paths_start.private.txt", paths.stdout)
        self.write("interfaces.txt", INTERFACES)
        self.write("hardware.txt", "Hardware Port: Ethernet\nDevice: en2\n")
        self.write("default.txt", lookup("en2", "10.20.0.1"))
        self.write("gateway.txt", lookup("en2", "aa:bb:cc:dd:ee:ff", "UP,HOST,DONE,LLINFO,IFSCOPE"))
        self.write("target_d.txt", lookup())
        self.write("target_v.txt", lookup())
        self.write("dns.txt", "resolver #1\n  nameserver[0] : 10.90.0.53\n")

    def check(self, edits=None, expected=0):
        self.fixture()
        for name, text in (edits or {}).items():
            self.write(name, text)
        r = self.run_fn("pf_check", self.dir, D, V)
        self.assertEqual(r.returncode, expected, r.stdout + r.stderr)
        for secret in (D, V, "en2", "utun7", "10.20.0.1", "100.64.55.1", "aa:bb"):
            self.assertNotIn(secret, r.stdout)
        return r.stdout

    def test_public_address(self):
        self.assertEqual(self.run_fn("pf_address", D, "D").returncode, 0)

    def test_vpn_private_control(self):
        self.assertEqual(self.run_fn("pf_address", V, "V").returncode, 0)

    def test_invalid_address_inputs(self):
        for ip in ("", "1.2.3", "1.2.3.4.5", "01.2.3.4", "1.2.3.256", "-x", "$(touch x)", "1.2.3.4\n5.6.7.8", "a.b.c.d", r"93\056184.216.34"):
            with self.subTest(ip=ip):
                self.assertNotEqual(self.run_fn("pf_address", ip, "D").returncode, 0)

    def test_disallowed_direct_ranges(self):
        for ip in ("0.2.3.4", "10.2.3.4", "100.64.0.1", "127.0.0.1", "169.254.1.1", "172.16.1.2", "192.168.1.1", "192.0.2.1", "192.0.0.9", "192.88.99.1", "198.18.0.1", "198.51.100.1", "203.0.113.1", "224.0.0.1", "255.255.255.255"):
            with self.subTest(ip=ip):
                self.assertNotEqual(self.run_fn("pf_address", ip, "D").returncode, 0)

    def test_unicast_only_control(self):
        for ip in ("0.0.0.0", "127.0.0.1", "169.254.1.1", "224.0.0.1"):
            self.assertNotEqual(self.run_fn("pf_address", ip, "V").returncode, 0)

    def test_candidate(self):
        self.assertIn("preflight_readiness=MANUAL_EXPERIMENT_CANDIDATE", self.check())

    def test_missing_half(self):
        f = self.write("r", ROUTES.replace("128.0/1 100.64.55.1 UGSc utun7\n", ""))
        self.assertNotEqual(self.run_fn("pf_paths", f).returncode, 0)

    def test_different_half_gateway(self):
        f = self.write("r", ROUTES.replace("128.0/1 100.64.55.1", "128.0/1 100.64.56.1"))
        self.assertNotEqual(self.run_fn("pf_paths", f).returncode, 0)

    def test_different_half_interface(self):
        f = self.write("r", ROUTES.replace("UGSc utun7", "UGSc utun8"))
        self.assertNotEqual(self.run_fn("pf_paths", f).returncode, 0)

    def test_second_physical_default(self):
        f = self.write("r", ROUTES + "default 10.22.0.1 UGSc en3\n")
        self.assertNotEqual(self.run_fn("pf_paths", f).returncode, 0)

    def test_second_ipv4_tunnel(self):
        f = self.write("r", ROUTES + "10.99/16 10.99.0.1 UGSc utun9\n")
        self.assertNotEqual(self.run_fn("pf_paths", f).returncode, 0)

    def test_unknown_gateway_format(self):
        f = self.write("r", ROUTES.replace("10.20.0.1 UGScg", "somewhere UGScg"))
        self.assertNotEqual(self.run_fn("pf_paths", f).returncode, 0)

    def test_empty_or_malformed_table(self):
        for text in ("", "Destination Gateway Flags\n", ROUTES + "oops\n", ROUTES + "Destination Gateway Flags Netif\n"):
            self.assertNotEqual(self.run_fn("pf_paths", self.write("r", text)).returncode, 0)

    def test_continuity_changed(self):
        self.check({"routes_end.txt": ROUTES.replace("10.20.0.1", "10.20.0.2")}, 2)

    def test_interface_inactive(self):
        self.check({"interfaces.txt": INTERFACES.replace("status: active", "status: inactive")}, 2)

    def test_missing_hardware_mapping(self):
        self.check({"hardware.txt": "Device: en8\n"}, 2)

    def test_duplicate_hardware_mapping(self):
        self.check({"hardware.txt": "Device: en2\nDevice: en2\n"}, 2)

    def test_wrong_default_lookup(self):
        self.check({"default.txt": lookup()}, 2)

    def test_routed_gateway_rejected(self):
        self.check({"gateway.txt": lookup("en2", "10.20.0.2")}, 2)

    def test_wrong_gateway_interface(self):
        self.check({"gateway.txt": lookup("utun7", "link#7", "UP,HOST")}, 2)

    def test_direct_target_not_on_vpn(self):
        self.check({"target_d.txt": lookup("en2", "10.20.0.1")}, 2)

    def test_vpn_control_not_on_vpn(self):
        self.check({"target_v.txt": lookup("en2", "10.20.0.1")}, 2)

    def test_control_with_separate_tunnel_gateway(self):
        self.check({"target_v.txt": lookup("utun7", "10.90.0.1")})

    def test_reject_blackhole_scoped_destination(self):
        for flag in ("REJECT", "BLACKHOLE", "IFSCOPE"):
            with self.subTest(flag=flag):
                self.check({"target_d.txt": lookup(flags="UP,GATEWAY," + flag)}, 2)
                # check() creates a fresh fixture, but reuses paths_end intentionally.

    def test_host_route_cidr_blocks(self):
        self.check({"routes_end.txt": ROUTES + f"{D}/32 10.20.0.1 UGHS en2\n"}, 2)

    def test_host_route_bare_blocks_even_scoped(self):
        self.check({"routes_end.txt": ROUTES + f"{D} 100.64.55.1 UGHWI utun7\n"}, 2)

    def test_dns_target_blocked(self):
        self.check({"dns.txt": f"nameserver[0] : {D}\n"}, 2)

    def test_local_interface_target_blocked(self):
        self.check({"interfaces.txt": INTERFACES + f"en3: flags=1<UP>\n inet {D} netmask 0xffffff00\n"}, 2)

    def test_nexthop_target_blocked(self):
        self.check({"routes_end.txt": ROUTES + f"10.60/16 {D} UGSc utun7\n"}, 2)

    def test_empty_lookup_blocked(self):
        self.check({"target_d.txt": ""}, 2)

    def test_duplicate_lookup_fields_blocked(self):
        self.check({"target_d.txt": lookup() + "interface: utun7\n"}, 2)

    def test_help_no_system_actions(self):
        r = subprocess.run(["/bin/bash", str(SCRIPT), "--help"], capture_output=True, text=True, timeout=5)
        self.assertEqual(r.returncode, 0)
        self.assertIn("No sudo", r.stdout)

    def test_no_route_write_or_probe_command_in_tool(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertNotRegex(text, r"(?m)^\s*(?:sudo|/usr/bin/sudo|curl|/usr/bin/curl|ping|/sbin/ping)\s")
        self.assertNotRegex(text, r"/sbin/route\s+-n\s+(?:add|delete|change|flush)\b")


if __name__ == "__main__":
    unittest.main()
