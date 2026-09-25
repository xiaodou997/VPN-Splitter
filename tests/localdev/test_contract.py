"""Offline source/project contracts, NOT macOS SDK or UI validation. T-LD01/05."""
import re
import subprocess
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps/macos/LocalDev"
PROJECT = APP / "VPN-Splitter-LocalDev.xcodeproj"
PBX = (PROJECT / "project.pbxproj").read_text()
UI = (APP / "LocalDevApp.swift").read_text()
BUILD = ROOT / "tools/localdev/build.sh"


class LocalDevContractTests(unittest.TestCase):
    def test_one_app_no_embedded_extension(self):
        self.assertEqual(PBX.count("isa = PBXNativeTarget;"), 1)
        self.assertNotIn("PBXCopyFilesBuildPhase", PBX)
        self.assertNotIn("PacketTunnel", PBX)
        self.assertIn('productType = "com.apple.product-type.application";', PBX)

    def test_separate_local_identity(self):
        self.assertEqual(PBX.count('CODE_SIGN_IDENTITY = "-";'), 2)
        self.assertEqual(PBX.count('DEVELOPMENT_TEAM = "";'), 2)
        self.assertEqual(PBX.count('CODE_SIGN_ENTITLEMENTS = "";'), 2)
        self.assertNotIn("Signing.local", PBX)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = "com.vpnsplitter.localdev";', PBX)

    def test_platform_is_26_arm64(self):
        self.assertEqual(PBX.count("MACOSX_DEPLOYMENT_TARGET = 26.0;"), 2)
        self.assertEqual(PBX.count("ARCHS = arm64;"), 2)

    def test_local_dependency_paths_exist(self):
        relative = re.search(r"relativePath = ([^;]+);", PBX).group(1)
        self.assertTrue((APP / relative / "Package.swift").resolve().is_file())
        package = (ROOT / "Packages/AppCore/Package.swift").read_text()
        self.assertIn('.package(path: "../PolicyCore")', package)
        self.assertNotIn(".package(url:", package)

    def test_shared_scheme_only_runs_local_app(self):
        scheme = ET.parse(PROJECT / "xcshareddata/xcschemes/VPN-Splitter-LocalDev.xcscheme")
        entries = scheme.findall(".//BuildActionEntry")
        self.assertEqual(len(entries), 1)
        for reference in scheme.findall(".//BuildableReference"):
            self.assertEqual(reference.get("BlueprintIdentifier"), "A10000000000000000000005")
            self.assertEqual(reference.get("BuildableName"), "VPN-Splitter-LocalDev.app")

    def test_source_reference_exists(self):
        self.assertIn("path = LocalDevApp.swift;", PBX)
        self.assertTrue((APP / "LocalDevApp.swift").is_file())

    def test_no_runtime_network_or_process_modules(self):
        paths = [APP / "LocalDevApp.swift"] + list((ROOT / "Packages/AppCore/Sources/AppCore").glob("*.swift"))
        for path in paths:
            text = path.read_text()
            for forbidden in ["import NetworkExtension", "import SystemExtensions", "import Network\n",
                              "URLSession", "Process()", "NETunnelProviderManager", "setTunnelNetworkSettings"]:
                self.assertNotIn(forbidden, text, str(path))

    def test_localdev_banner_and_unsupported_boundary(self):
        self.assertIn("本地开发模式：不接管网络", UI)
        self.assertIn("暂不支持；启用时会阻止预览", UI)
        self.assertIn("未检查基础设施/peer", (ROOT / "Packages/AppCore/Sources/AppCore/LocalSession.swift").read_text())

    def test_native_build_not_unsigned_spike(self):
        text = BUILD.read_text()
        self.assertIn("apps/macos/LocalDev/VPN-Splitter-LocalDev.xcodeproj", text)
        self.assertNotIn("tools/s1", text)
        self.assertIn("codesign --verify --strict", text)
        self.assertIn("Signature=adhoc", text)
        self.assertIn('if [[ "$MODE" == run ]]', text)

    def test_shell_syntax(self):
        subprocess.run(["/bin/bash", "-n", str(BUILD)], check=True, capture_output=True)

    def test_no_network_mutation_commands(self):
        text = BUILD.read_text()
        for command in ["sudo ", "route add", "route delete", "networksetup ", "systemextensionsctl ", "spctl "]:
            self.assertNotIn(command, text)

    def test_diagnostic_input_change_clears_old_result(self):
        self.assertIn('.onChange(of: target) { _, _ in explanation = "" }', UI)
        self.assertIn("if session.selectedID != previous", UI)


if __name__ == "__main__":
    unittest.main()
