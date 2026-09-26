# SPDX-License-Identifier: MIT
"""Executable native-host sequencing with explicit platform/engine doubles, not native acceptance."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).with_name('fixtures')

class RuntimeHostTests(unittest.TestCase):
    def test_actual_host_and_actual_controller(self):
        with tempfile.TemporaryDirectory(prefix='vpnsplitter-runtime-') as temp:
            work = Path(temp)
            def run(args):
                p = subprocess.run(args, capture_output=True, text=True, cwd=work, timeout=120)
                self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
                return p.stdout
            suffix = 'dylib' if sys.platform == 'darwin' else 'so'
            sources = ROOT / 'Packages/ProviderSession/Sources/ProviderSession'
            run(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-emit-library', '-emit-module',
                '-module-name', 'ProviderSession', str(sources / 'ProviderSession.swift'),
                str(sources / 'PacketFlowSettingsGate.swift'), '-o', str(work / ('libProviderSession.' + suffix))])
            host = (ROOT / 'integrations/wireguard/ManagedPacketFlowSession.swift').read_text()
            host = re.sub(r'^(?:@preconcurrency )?import (?!Foundation$|ProviderSession$)\w+\n', '', host, flags=re.M)
            (work / 'Host.swift').write_text(host)
            run(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                '-I', str(work), '-L', str(work), '-lProviderSession',
                str(ROOT / 'Packages/ProviderConfiguration/Sources/ProviderConfiguration/ManagedRunAuthorization.swift'),
                str(FIXTURES / 'NativeRuntimeDoubles.swift'), str(work / 'Host.swift'),
                str(FIXTURES / 'NativeRuntimeHarness.swift'), '-Xlinker', '-rpath', '-Xlinker', str(work),
                '-o', str(work / 'harness')])
            result = run([str(work / 'harness')])
            self.assertIn('runtime-host=PASS scenarios=6', result)
            print(result.strip())

if __name__ == '__main__': unittest.main()
