# SPDX-License-Identifier: MIT
"""Compile actual listener source, not just parse inactive macOS conditionals.

Foundation's XPC types and the broker are explicit doubles; NOT a native XPC test.
The non-Sendable connection must expose the old actor-crossing bug as a negative
control. Only the timeout duration is shortened in the executable test copy.
"""
from pathlib import Path
import platform
import sys
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).parent / 'fixtures'
SOURCE = ROOT / 'Packages/ProviderConfiguration/Sources/ProviderConfiguration/ManagedAuthenticatedXPC.swift'


def segment(source, start, end):
    if source.count(start) != 1 or source.count(end) != 1:
        raise AssertionError('Listener source anchors changed; review the extraction')
    first, last = source.index(start), source.index(end)
    if first >= last:
        raise AssertionError('Invalid listener source range')
    return source[first:last]


class XPCListenerTests(unittest.TestCase):
    def listener_source(self):
        source = SOURCE.read_text()
        liveness = segment(source, '// Lock protects only liveness', 'private final class ManagedXPCExport:')
        listener = segment(source, 'private final class ManagedXPCListener:', '/// Installed by the system-extension executable,')
        return liveness + listener

    def compile(self, source, execute=False):
        compiler = shutil.which('swiftc')
        self.assertIsNotNone(compiler, 'Swift compiler required; do not silently skip')
        with tempfile.TemporaryDirectory(prefix='vpn-xpc-listener-test-') as directory:
            root = Path(directory)
            path = root / 'ListenerTest.swift'
            path.write_text((FIXTURES / 'XPCListenerDoubles.swift').read_text() + '\n' + source
                            + ('\n' + (FIXTURES / 'XPCListenerHarness.swift').read_text() if execute else ''))
            command = [compiler, '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors', '-parse-as-library']
            if sys.platform == 'darwin':
                command += ['-target', platform.machine() + '-apple-macos26.0']
            # Region-isolation diagnostics require code generation, not parse/typecheck only.
            command += [str(path), '-o', str(root / 'listener')] if execute else ['-c', str(path), '-o', str(root / 'listener.o')]
            result = subprocess.run(command, capture_output=True, text=True, timeout=60)
            if execute:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                result = subprocess.run([str(root / 'listener')], capture_output=True, text=True, timeout=10)
            return result

    def test_legacy_connection_capture_is_rejected(self):
        source = self.listener_source()
        self.assertEqual(source.count('Task { @MainActor [weak self, broker] in'), 1)
        self.assertEqual(source.count('self?.end(id)'), 1)
        # Reintroduce precisely the original ownership mistake, without changing types.
        source = source.replace('Task { @MainActor [weak self, broker] in', 'Task { @MainActor [weak connection] in')
        source = source.replace('self?.end(id)', 'connection?.invalidate()')
        result = self.compile(source)
        self.assertNotEqual(result.returncode, 0, 'The double must catch the regression')
        self.assertIn("sending 'connection' risks causing data races", result.stderr)

    def test_id_based_expiry_compiles_and_preserves_active_run(self):
        source = self.listener_source()
        self.assertEqual(source.count('15_000_000_000'), 1)
        source = source.replace('15_000_000_000', '50_000_000')
        result = self.compile(source, execute=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('xpc-listener=PASS', result.stdout)
        self.assertIn('native_auth=NOT_TESTED', result.stdout)
        print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main()
