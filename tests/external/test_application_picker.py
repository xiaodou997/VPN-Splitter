# SPDX-License-Identifier: MIT
import subprocess, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / 'Packages/ExternalCore/Sources/ExternalPreview'

class ApplicationPickerContracts(unittest.TestCase):
    def test_catalog_is_read_only_and_persists_no_path(self):
        source = (UI / 'ExternalApplicationCatalog.swift').read_text()
        for token in ['/Applications', '/System/Applications', '.applicationDirectory',
                      'SecStaticCodeCreateWithPath', 'SecStaticCodeCheckValidity',
                      'kSecCodeInfoIdentifier', 'signingIdentifier']:
            self.assertIn(token, source)
        for token in ['UserDefaults', 'write(to:', 'FileHandle', 'removeItem', 'copyItem', 'moveItem',
                      'NSWorkspace.shared.open', 'URLSession']:
            self.assertNotIn(token, source)
        self.assertNotIn('path:', source.split('struct ExternalInstalledApplication')[1].split('}')[0])

    def test_rule_ui_uses_picker_and_shows_stable_identity(self):
        panel = (UI / 'ExternalProfilesPanel.swift').read_text()
        model = (UI / 'ExternalProfilesModel.swift').read_text()
        self.assertIn('ExternalApplicationPicker', panel)
        self.assertIn('applicationIdentifier', panel)
        self.assertIn('profiles.bindApplication', panel)
        self.assertIn('profile.rules[index].applicationIdentifier = nil', model)
        self.assertIn('applicationIdentifier = app.signingIdentifier', model)

    def test_mac_sources_parse(self):
        sources = [UI / 'ExternalApplicationCatalog.swift',
                   UI / 'ExternalProfilesModel.swift',
                   UI / 'ExternalProfilesPanel.swift']
        result = subprocess.run(['swiftc','-frontend','-parse','-target','arm64-apple-macos26.0',
                                 *map(str,sources)], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

if __name__ == '__main__':
    unittest.main()
