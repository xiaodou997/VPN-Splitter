# SPDX-License-Identifier: MIT
import subprocess, unittest, platform, tempfile, plistlib, os, stat
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

    @unittest.skipUnless(platform.system() == 'Darwin', 'native Foundation/Security test')
    def test_native_candidate_discovery_includes_app_links_without_following_other_links(self):
        source = (UI / 'ExternalApplicationCatalog.swift').read_text().split('@MainActor')[0]
        source = source.replace('#if os(macOS)', '').replace('import SwiftUI', '')
        source += r"""
@main struct CatalogHarness {
    static func main() {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let names = ExternalApplicationCatalog.candidateURLs(in: root).map { $0.lastPathComponent }.sorted()
        precondition(names == ["AppAlias.app", "Plain.app", "Tool.app"], "wrong discovery boundary")
        print("native_candidate_discovery=PASS")
    }
}
"""
        with tempfile.TemporaryDirectory(prefix='external-app-discovery-') as directory:
            root = Path(directory); apps = root / 'Applications'; apps.mkdir()
            for app in [apps / 'Plain.app', apps / 'Utilities/Tool.app', root / 'Elsewhere/Linked.app',
                        root / 'Outside/Hidden.app', apps / '.Hidden.app', apps / 'Plain.app/Contents/Nested.app']:
                (app / 'Contents').mkdir(parents=True, exist_ok=True)
                (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundlePackageType': 'APPL'}))
            (apps / 'AppAlias.app').symlink_to(root / 'Elsewhere/Linked.app', target_is_directory=True)
            os.chflags(apps / 'AppAlias.app', stat.UF_HIDDEN, follow_symlinks=False)
            (apps / '.HiddenAlias.app').symlink_to(root / 'Elsewhere/Linked.app', target_is_directory=True)
            (apps / 'FolderAlias').symlink_to(root / 'Outside', target_is_directory=True)
            swift = root / 'Harness.swift'; binary = root / 'catalog-test'; swift.write_text(source)
            built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors',
                '-parse-as-library', str(swift), '-o', str(binary)], capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stderr)
            ran = subprocess.run([str(binary), str(apps)], capture_output=True, text=True, timeout=10)
            self.assertEqual(ran.returncode, 0, ran.stderr)
            self.assertIn('native_candidate_discovery=PASS', ran.stdout)

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
