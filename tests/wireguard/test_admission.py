"""WG-INT-05 full pinned patch and runtime admission contracts; no native VPN."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/wireguard'))
import policy_hook as policy
import runtime_hook as runtime

ORIGINAL = ROOT / 'tests/fixtures/wireguard-build/WireGuardAdapter.swift.reference'
LOCK = json.loads((ROOT / 'third-party/wireguard-go/build-lock.json').read_text())


def stages():
    first = policy.patch_adapter(ORIGINAL.read_bytes())
    second = runtime.transform_runtime(first.decode())
    final = runtime.patch_runtime_adapter(first)
    return first, second, final


class AdmissionContracts(unittest.TestCase):
    def test_exact_complete_upstream_and_final_source_are_locked(self):
        self.assertEqual(policy.git_blob(ORIGINAL.read_bytes()), policy.ADAPTER_BLOB)
        first, _, final = stages()
        self.assertEqual(policy.git_blob(first), policy.PATCHED_ADAPTER_BLOB)
        self.assertEqual(policy.git_blob(final), runtime.RUNTIME_ADAPTER_BLOB)
        self.assertEqual(LOCK['runtime_adapter_blob'], runtime.RUNTIME_ADAPTER_BLOB)
        runtime.checked_support(ROOT, LOCK)

    def test_final_hash_rejects_an_altered_transform(self):
        first, _, _ = stages()
        with patch.object(runtime, 'transform_admission', return_value='altered'):
            with self.assertRaisesRegex(ValueError, 'ADMISSION_RESULT_CHANGED'):
                runtime.patch_runtime_adapter(first)

    def test_repeat_or_drift_cannot_fuzzy_apply(self):
        first, second, final = stages()
        with self.assertRaises(ValueError): runtime.patch_runtime_adapter(final)
        for value in (second.replace('private var requiresProviderReset = false', 'private var drift = false'),
                      second + '\n    /// Tunnel device file descriptor.\n', final.decode()):
            with self.subTest(prefix=value[:20]), self.assertRaises(ValueError):
                runtime.transform_admission(value)
        with self.assertRaises(ValueError): policy.patch_adapter(first)

    def test_review_patches_apply_in_order_to_the_full_source(self):
        if not shutil.which('git'): self.skipTest('git unavailable')
        expected = [policy.PATCHED_ADAPTER_BLOB, policy.git_blob(stages()[1].encode()), runtime.RUNTIME_ADAPTER_BLOB]
        names = ['0001-required-policy-settings.patch', '0002-settings-failure-guard.patch', '0004-runtime-admission.patch']
        with tempfile.TemporaryDirectory(prefix='wg admission ') as temporary:
            root = Path(temporary)
            target = root / 'Sources/WireGuardKit/WireGuardAdapter.swift'
            target.parent.mkdir(parents=True); target.write_bytes(ORIGINAL.read_bytes())
            for name, sha in zip(names, expected):
                path = ROOT / 'third-party/wireguard-apple/patches' / name
                subprocess.run(['git', 'apply', '--check', str(path)], cwd=root, check=True, capture_output=True)
                subprocess.run(['git', 'apply', str(path)], cwd=root, check=True, capture_output=True)
                self.assertEqual(policy.git_blob(target.read_bytes()), sha)
            again = subprocess.run(['git', 'apply', '--check', str(path)], cwd=root, capture_output=True)
            self.assertNotEqual(again.returncode, 0)
        self.assertEqual(policy.git_blob(path.read_bytes()), LOCK['admission_patch_blob'])

    def test_no_descriptor_scan_or_optional_identity_entry(self):
        source = stages()[2].decode()
        for item in ['for fd:', 'tunnelFileDescriptor', 'value(forKey:', 'fileDescriptor = 0', '.generateNetworkSettings()']:
            self.assertNotIn(item, source)
        self.assertIn('runtimeBinding: SplitterWireGuardBinding,', source)
        self.assertIn('tunnelDescriptorProvider: @escaping () throws -> SplitterTunnelDescriptorLease,', source)
        self.assertIn('lease.withFileDescriptor(for: runtimeBinding.providerInstance)', source)
        self.assertIn('defer { lease.close() }', source)

    def test_failed_post_start_admission_releases_unpublished_handle(self):
        source = stages()[2].decode()
        start = source.split('private func startWireGuardBackend')[1].split('private func makeSettingsGenerator')[0]
        self.assertLess(start.index('try checkAdmission()'), start.index('wgTurnOn'))
        self.assertIn('wgTurnOff(started)', start)
        self.assertLess(start.index('wgTurnOff(started)'), start.index('return started'))
        self.assertIn('markForProviderReset()', start)
        self.assertNotIn('setTunnelNetworkSettings(nil', source)

    def test_config_is_copied_and_rechecked_around_settings(self):
        source = stages()[2].decode()
        self.assertEqual(source.count('try self.setNetworkSettings(self.policyNetworkSettings(settingsGenerator))\n                try self.checkAdmission()'), 3)
        self.assertIn('expectedPeers.count == request.peers.count', source)
        self.assertIn('expected.allowedIPs == current.allowedIPs', source)
        self.assertIn('expectedInterface.addresses == request.interface.addresses', source)
        self.assertIn('try runtimeBinding.checkedCopy(matching: request)', source)
        make = source.split('private func makeSettingsGenerator')[1].split('/// Log DNS')[0]
        self.assertIn('tunnelConfiguration: approved', make)
        self.assertNotIn('tunnelConfiguration: tunnelConfiguration,', make)

    def test_stop_reset_and_path_events_fence_binding(self):
        source = stages()[2].decode()
        reset = source.split('private func markForProviderReset()')[1].split('private func checkedSetConfig')[0]
        self.assertIn('runtimeBinding.invalidate()', reset)
        self.assertIn('recordInterface(nil)', reset)
        stop = source.split('public func stop(')[1].split('public func update(')[0]
        self.assertIn('runtimeBinding.invalidate()', stop)
        path = source.split('private func didReceivePathUpdate')[1]
        self.assertLess(path.index('try checkAdmission()'), path.index('wgBumpSockets(handle)'))
        update = source.split('private func checkedSetConfig')[1].split('/// Resolve peers')[0]
        self.assertEqual(update.count('try checkAdmission()'), 2)

    def test_same_binding_source_runs_with_explicit_type_doubles(self):
        compiler = shutil.which('swiftc')
        if not compiler: self.skipTest('Swift compiler unavailable; not a native binding pass')
        harness = (ROOT / 'tests/wireguard/binding_harness.swift').read_text()
        harness = harness.replace('// <BINDING>', runtime.BINDING_SOURCE)
        with tempfile.TemporaryDirectory(prefix='wg binding ') as temporary:
            root = Path(temporary); main = root / 'main.swift'; main.write_text(harness)
            binary = root / 'harness'
            result = subprocess.run([compiler, '-swift-version', '5', '-warnings-as-errors',
                str(ROOT / runtime.SUPPORT_PATH), str(main), '-o', str(binary)], capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn('upstream_types=DOUBLES', run.stdout)

    def test_probe_requires_live_sources_and_never_launches(self):
        source = (ROOT / 'tools/wireguard/Probe.swift').read_text()
        for item in ['currentRevision: @escaping', 'descriptor: @escaping', 'current: @escaping', 'current: current()']:
            self.assertIn(item, source)
        for item in ['.start(', '.update(', '.stop(', 'setTunnelNetworkSettings(', 'SecItem', 'socket(', 'dup(']:
            self.assertNotIn(item, source)


if __name__ == '__main__':
    unittest.main()
