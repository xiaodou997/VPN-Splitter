# SPDX-License-Identifier: MIT
import ast, json, subprocess, sys, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'Packages/ExternalFlow'

class ExternalFlowContracts(unittest.TestCase):
    def test_manifest_is_local_and_probe_only(self):
        package = json.loads(subprocess.check_output(
            ['swift', 'package', '--package-path', str(PACKAGE), 'dump-package'], text=True, timeout=30))
        deps = {Path(x['fileSystem'][0]['path']).resolve() for x in package['dependencies']}
        self.assertEqual(deps, {(ROOT / 'Packages/ExternalCore').resolve(), (ROOT / 'Packages/PolicyCore').resolve()})
        self.assertEqual({t['name'] for t in package['targets']},
                         {'ExternalFlowCore', 'ExternalFlowProvider', 'ExternalFlowCoreTests'})
        source = (PACKAGE / 'Sources/ExternalFlowProvider/ExternalTransparentProbeProvider.swift').read_text()
        for token in ['NETransparentProxyProvider', 'includedNetworkRules', 'sourceAppSigningIdentifier',
                      'remoteHostname', 'return false', 'probe-report-v1']:
            self.assertIn(token, source)
        for token in ['NWConnection(', '.open(withLocalEndpoint:', '.readData(', '.write(']:
            self.assertNotIn(token, source)

    def test_builder_never_installs_or_executes(self):
        path = ROOT / 'tools/external/flow-build.py'
        project = ROOT / 'tools/external/flow_project.py'
        ast.parse(path.read_text()); ast.parse(project.read_text())
        source = path.read_text() + project.read_text()
        for token in ['codesign', 'systemextensionsctl', 'SMAppService', '/usr/bin/open', 'sudo', 'launchctl']:
            self.assertNotIn(token, source)
        self.assertIn('wrapper.system-extension', (ROOT / 'tools/s1/generate-project.py').read_text())
        self.assertIn('com.apple.networkextension.app-proxy', project.read_text())
        self.assertIn('ExternalFlowProvider.ExternalTransparentProbeProvider', project.read_text())
        self.assertIn('CODE_SIGNING_ALLOWED=NO', path.read_text())
        if sys.platform != 'darwin':
            p = subprocess.run([sys.executable, str(path)], capture_output=True, text=True, timeout=10)
            self.assertEqual(p.returncode, 69)
            self.assertIn('execution=NOT_RUN', p.stderr)

    def test_provider_source_parses_for_mac(self):
        source = PACKAGE / 'Sources/ExternalFlowProvider/ExternalTransparentProbeProvider.swift'
        p = subprocess.run(['swiftc', '-frontend', '-parse', '-target', 'arm64-apple-macos26.0', str(source)],
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

if __name__ == '__main__':
    unittest.main()
