# SPDX-License-Identifier: MIT
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).with_name('fixtures')
class RuntimeDeliveryTests(unittest.TestCase):
    def test_purpose_and_consumed_channel_lifetime(self):
        source = ROOT / 'Packages/ProviderConfiguration/Sources/ProviderConfiguration'
        with tempfile.TemporaryDirectory(prefix='vpnsplitter-run-delivery-') as d:
            exe = Path(d) / 'harness'
            p = subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                str(source / 'ManagedDeliveryProtocol.swift'), str(source / 'ManagedRunAuthorization.swift'),
                str(FIXTURES / 'DeliveryRuntimeDoubles.swift'), str(FIXTURES / 'DeliveryRuntimeHarness.swift'), '-o', str(exe)],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            p = subprocess.run([str(exe)], capture_output=True, text=True, timeout=10)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertIn('run-delivery=PASS scenarios=10', p.stdout)
            print(p.stdout.strip())
if __name__ == '__main__': unittest.main()
