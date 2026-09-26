# SPDX-License-Identifier: MIT
"""Offline checks. Apple frameworks, signing and live NE behavior are NOT tested."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parent / "fixtures"
spec = importlib.util.spec_from_file_location("s1_generator", ROOT / "tools/s1/generate-project.py")
GEN = importlib.util.module_from_spec(spec)
spec.loader.exec_module(GEN)


class LaunchIntegrationTests(unittest.TestCase):
    def test_checked_in_project_is_generated(self):
        self.assertEqual(GEN.render(), (ROOT / "apps/macos/VPN-Splitter.xcodeproj/project.pbxproj").read_text())

    def test_both_formal_targets_link_contract(self):
        objects = GEN.build_project()["objects"]
        for role in ("app", "tunnel"):
            dependency = GEN.ident(role + ".managed.package")
            self.assertEqual(objects[dependency]["productName"], "ProviderConfiguration")
            self.assertIn(dependency, objects[GEN.ident(role + ".target")]["packageProductDependencies"])
            self.assertIn(GEN.ident(role + ".managed.link"), objects[GEN.ident(role + ".frameworks")]["files"])
        self.assertEqual(objects[GEN.ident("managed.package")]["relativePath"], "../../Packages/ProviderConfiguration")
        self.assertIn(GEN.ident("app.ManagedTunnelLaunchClient.swift"),
                      [o["fileRef"] for o in objects.values() if o["isa"] == "PBXBuildFile" and "fileRef" in o])

    def test_legacy_target_settings_and_no_remote_dependency(self):
        objects = GEN.build_project()["objects"]
        self.assertEqual(len([o for o in objects.values() if o["isa"] == "PBXNativeTarget"]), 2)
        self.assertFalse(any(o["isa"] == "XCRemoteSwiftPackageReference" for o in objects.values()))
        for configuration in ("Debug", "Release", "DeveloperID"):
            settings = objects[GEN.ident("tunnel." + configuration)]["buildSettings"]
            self.assertEqual(settings["ENABLE_APP_SANDBOX"], "YES")
            self.assertEqual(settings["LD_RUNPATH_SEARCH_PATHS"], ["$(inherited)", "@executable_path/../Frameworks"])
        source = (ROOT / "apps/macos/PacketTunnel/PacketTunnelProvider.swift").read_text()
        for invocation in ("setTunnelNetworkSettings(", "readPackets(", "writePackets(", "NWConnection(", "URLSession."):
            self.assertNotIn(invocation, source)
        self.assertIn("code: 1001", source)
        self.assertIn("code: 2001", source)
        self.assertIn("code: 2002", source)
        self.assertNotIn("completionHandler(nil)", source)

    def test_dev_dispatch_keeps_existing_modes(self):
        # Execute dispatcher against harmless stubs, never real build/open/network scripts.
        with tempfile.TemporaryDirectory(prefix="vpn-dispatch-test-") as directory:
            root = Path(directory)
            shutil.copyfile(ROOT / "dev.sh", root / "dev.sh")
            scripts = ["localdev/build.sh", "localdev/test.sh", "wireguard/build.sh",
                       "wireguard/test.sh", "provider/test.sh"]
            for relative in scripts:
                path = root / "tools" / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('#!/bin/bash\necho "' + relative + ' $*"\n')
            doctor = root / "tools/dev/doctor.py"
            doctor.parent.mkdir(parents=True, exist_ok=True)
            doctor.write_text('import sys\nprint("doctor " + " ".join(sys.argv[1:]))\n')
            cases = [([], "doctor app"), (["doctor", "engine"], "doctor engine"),
                     (["run"], "localdev/build.sh run"), (["test"], "localdev/test.sh"),
                     (["engine"], "doctor engine\nwireguard/build.sh build"),
                     (["engine", "--fetch"], "doctor engine\nwireguard/build.sh build --fetch"),
                     (["engine-test"], "wireguard/test.sh"),
                     (["provider-test"], "provider/test.sh")]
            for arguments, expected in cases:
                result = subprocess.run(["/bin/bash", str(root / "dev.sh"), *arguments],
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)
            for arguments in (["provider-test", "--fetch"], ["run", "extra"], ["unknown"]):
                result = subprocess.run(["/bin/bash", str(root / "dev.sh"), *arguments],
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")

    def test_native_source_flow_with_explicit_doubles(self):
        swiftc = shutil.which("swiftc")
        self.assertIsNotNone(swiftc, "Swift compiler is required; do not silently skip execution")
        with tempfile.TemporaryDirectory(prefix="vpn-launch-test-") as directory:
            build = Path(directory)
            suffix = "dylib" if sys.platform == "darwin" else "so"
            def run(args, env=None):
                result = subprocess.run(args, cwd=build, capture_output=True, text=True,
                                        timeout=120, env=env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                return result
            for module in ("NetworkExtension", "os", "PolicyCore", "ProviderConfiguration"):
                source = (ROOT / "Packages/ProviderConfiguration/Sources/ProviderConfiguration/ManagedLaunch.swift"
                          if module == "ProviderConfiguration" else FIXTURES / (module + ".swift"))
                run([swiftc, "-swift-version", "6", "-warnings-as-errors", "-emit-library", "-emit-module",
                     "-module-name", module, str(source), "-o", str(build / ("lib" + module + "." + suffix))])
            # Exactly one explicit replacement supplies a bundle ID to the test executable.
            # It is NOT evidence of Bundle.main or real signed extension identity validation.
            source = (ROOT / "apps/macos/PacketTunnel/PacketTunnelProvider.swift").read_text()
            self.assertEqual(source.count("Bundle.main.bundleIdentifier"), 1)
            # Force this legacy metadata-only harness to stay metadata-only on Mac too.
            # This is a test COPY; production macOS branches are never removed.
            self.assertEqual(source.count("#if os(macOS)"), 5)
            source = source.replace("#if os(macOS)", "#if VPNSPLITTER_DISABLED_NATIVE_IN_METADATA_TEST")
            (build / "PacketTunnelProvider.swift").write_text(source.replace(
                "Bundle.main.bundleIdentifier", 'Optional("test.vpnsplitter.provider")'))
            executable = build / "launch-harness"
            run([swiftc, "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
                 "-I", str(build), "-L", str(build), "-lNetworkExtension", "-los", "-lPolicyCore",
                 "-lProviderConfiguration", str(ROOT / "apps/macos/App/ManagedTunnelLaunchClient.swift"),
                 str(build / "PacketTunnelProvider.swift"), str(FIXTURES / "LaunchHarness.swift"),
                 "-o", str(executable)])
            env = dict(os.environ)
            env["DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"] = str(build)
            result = run([str(executable)], env=env)
            self.assertIn("launch-harness=PASS scenarios=11 framework=TEST_DOUBLES bundle=INJECTED", result.stdout)
            print(result.stdout.strip() + " native_xpc=NOT_TESTED")


if __name__ == "__main__":
    unittest.main()
