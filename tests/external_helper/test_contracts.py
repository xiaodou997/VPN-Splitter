# SPDX-License-Identifier: MIT
"""Source/manifest/Swift parse contracts, not native execution or signing evidence."""
import json
from pathlib import Path
import subprocess
import unittest
ROOT = Path(__file__).resolve().parents[2]

class HelperContracts(unittest.TestCase):
    def test_independent_local_package_and_real_helper_target(self):
        for package in ['ExternalControl', 'ExternalCore', 'ExternalExecution']:
            result = subprocess.run(['swift', 'package', '--package-path', str(ROOT / 'Packages' / package), 'dump-package'], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads(result.stdout)
            self.assertTrue(all('fileSystem' in dependency for dependency in manifest['dependencies']))
            if package == 'ExternalExecution':
                targets = {t['name']: t for t in manifest['targets']}
                self.assertIn('ExternalHelper', targets); self.assertIn('ExternalLease', targets)
            if package == 'ExternalControl': self.assertEqual(manifest['dependencies'], [])

    def test_authentication_authorization_and_no_arbitrary_privileged_surface(self):
        identity = (ROOT / 'Packages/ExternalControl/Sources/ExternalControl/ExternalControlIdentity.swift').read_text()
        client = (ROOT / 'Packages/ExternalControl/Sources/ExternalControl/ExternalHelperClient.swift').read_text()
        host = (ROOT / 'Packages/ExternalExecution/Sources/ExternalHelper/ExternalHelperMain.swift').read_text()
        lease = (ROOT / 'Packages/ExternalExecution/Sources/ExternalHelper/ExternalHelperLease.swift').read_text()
        for token in ['SecCodeCopySelf', 'SecCodeCheckValidity', 'kSecCodeInfoTeamIdentifier', 'kSecCodeInfoFlags']:
            self.assertIn(token, identity)
        self.assertIn('channel.setCodeSigningRequirement', client)
        self.assertIn('channel.effectiveUserIdentifier == 0', client)
        self.assertIn('channel.setCodeSigningRequirement', host)
        self.assertIn('channel.effectiveUserIdentifier', host)
        self.assertIn('SCDynamicStoreCopyConsoleUser', host)
        self.assertIn('#if EXTERNAL_HELPER_ROUTE_TRIAL', host)
        self.assertIn('await service.tick()', host)
        for token in ['ExternalLeasePlan.prepare', 'ExternalLeaseTransaction(', 'transaction.start(consent: true)', 'transaction.stop()', 'ExternalLeaseFileJournal.foregroundHost()']:
            self.assertIn(token, lease)
        before_start = lease[:lease.index('    func start()')]
        self.assertNotIn('foregroundHost()', before_start); self.assertNotIn('NativeExternalRouteDriver(', before_start)
        for token in ['AuthorizationExecuteWithPrivileges', 'NSAppleScript', '/bin/sh', '/sbin/route', 'clear-absent-marker', 'SecItem', 'processIdentifier']:
            self.assertNotIn(token, host + client + lease)
        self.assertIn('quiesced', client)

    def test_mac_native_sources_syntax_and_ui_wiring(self):
        sources = list((ROOT / 'Packages/ExternalControl/Sources').rglob('*.swift'))
        sources += list((ROOT / 'Packages/ExternalExecution/Sources/ExternalHelper').glob('*.swift'))
        sources += [ROOT / 'Packages/ExternalCore/Sources/ExternalPreview/ExternalHelperPanel.swift',
                    ROOT / 'Packages/ExternalCore/Sources/ExternalPreview/ExternalPreviewApp.swift']
        parsed = subprocess.run(['swiftc', '-frontend', '-parse', '-target', 'arm64-apple-macos26.0', *map(str, sources)], capture_output=True, text=True, timeout=30)
        self.assertEqual(parsed.returncode, 0, parsed.stdout + parsed.stderr)
        app = sources[-1].read_text(); panel = sources[-2].read_text()
        navigation = (ROOT / 'Packages/ExternalCore/Sources/ExternalPreview/ExternalNavigationView.swift').read_text()
        self.assertIn('ExternalHelperSessionPanel(helper: helper, profiles: profiles)', navigation)
        self.assertIn('ExternalRecoveryPanel(helper: helper)', navigation)
        self.assertIn('helper.invalidate()', app); self.assertIn('control?.confirmQuit()', app)
        self.assertIn('let disk = try await store.load()', panel)
        self.assertIn('func probeTransport()', panel)
        self.assertIn('测试 Helper 通信（只读）', panel)
        self.assertIn('disk == before', panel); self.assertIn('cleanupUnconfirmed = true', panel)
        self.assertIn('profile: selected.0, revision: selected.1, ticket: ticket', panel)
        self.assertNotIn('sudo ', panel)
if __name__ == '__main__': unittest.main()
