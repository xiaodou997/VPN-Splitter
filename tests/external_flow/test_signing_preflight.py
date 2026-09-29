# SPDX-License-Identifier: MIT
import importlib.util, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / "tools/external/flow-signing-preflight.py"

def module():
    spec = importlib.util.spec_from_file_location("flow_signing_preflight", PATH)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value

class FlowSigningPreflightTests(unittest.TestCase):
    def test_identity_parser_only_accepts_developer_id_application(self):
        m = module()
        text = '''
  1) AAA "Apple Development: Person (ABCDE12345)"
  2) BBB "Developer ID Application: Example LLC (ABCDE12345)"
  3) CCC "Developer ID Installer: Example LLC (ABCDE12345)"
'''
        self.assertEqual(m.developer_identities(text),
                         ["Developer ID Application: Example LLC (ABCDE12345)"])

    def test_profile_matching_requires_bundle_team_and_systemextension_entitlement(self):
        m = module()
        base = {
            "Name": "Flow Probe App",
            "TeamIdentifier": ["ABCDE12345"],
            "Entitlements": {
                "application-identifier": "ABCDE12345." + m.APP_ID,
                "com.apple.developer.networking.networkextension":
                    ["app-proxy-provider-systemextension"]
            }
        }
        self.assertTrue(m.profile_matches(base, m.APP_ID, "ABCDE12345"))
        self.assertFalse(m.profile_matches(base, m.EXT_ID, "ABCDE12345"))
        self.assertFalse(m.profile_matches(base, m.APP_ID, "ZZZZZ99999"))
        broken = {**base, "Entitlements": {
            "application-identifier": "ABCDE12345." + m.APP_ID,
            "com.apple.developer.networking.networkextension": ["app-proxy-provider"]
        }}
        self.assertFalse(m.profile_matches(broken, m.APP_ID, "ABCDE12345"))

if __name__ == "__main__":
    unittest.main()
