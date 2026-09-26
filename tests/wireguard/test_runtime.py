"""WG-INT-03 transform/copy contracts, not native Adapter or network validation."""
from pathlib import Path
import json
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/wireguard'))
import build as native
import policy_hook
import runtime_hook as hook
LOCK = json.loads(native.LOCK_PATH.read_text())


def fixture():
    # Deliberately synthetic (not a compilable upstream substitute). Exact snippets
    # exercise guards/occurrence counts; tests never change production input hashes.
    text = '    case policyNetworkSettings(Error)\n    private var state: State = .stopped\n'
    for signature in ['start(tunnelConfiguration: TunnelConfiguration, completionHandler: @escaping (WireGuardAdapterError?) -> Void)',
                      'update(tunnelConfiguration: TunnelConfiguration, completionHandler: @escaping (WireGuardAdapterError?) -> Void)',
                      'stop(completionHandler: @escaping (WireGuardAdapterError?) -> Void)']:
        text += '    public func ' + signature + ' {\n        workQueue.async {\n        }\n    }\n'
    text += ('    /// This method ensures that the call to `setTunnelNetworkSettings` does not time out, as in\n'
             '    /// certain scenarios the completion handler given to it may not be invoked by the system.\n')
    text += hook.OLD_SETTINGS
    text += ('                    wgSetConfig(handle, wgConfig)\n'
             '                wgSetConfig(handle, wgConfig)\n'
             '    private func didReceivePathUpdate(path: Network.NWPath) {\n}\n'
             '            throw WireGuardAdapterError.cannotLocateTunnelFileDescriptor\n'
             '            throw WireGuardAdapterError.startWireGuardBackend(handle)\n')
    return text


class RuntimePatchTests(unittest.TestCase):
    def test_whole_original_and_policy_hash_guards_are_preserved(self):
        self.assertEqual(LOCK['patched_adapter_blob'], policy_hook.PATCHED_ADAPTER_BLOB)
        with self.assertRaisesRegex(ValueError, 'UPSTREAM_ADAPTER_CHANGED'):
            policy_hook.patch_adapter(fixture().encode())
        with self.assertRaisesRegex(ValueError, 'RUNTIME_INPUT_CHANGED'):
            hook.patch_runtime_adapter(fixture().encode())

    def test_completion_gates_protocol_and_missing_provider_is_error(self):
        text = hook.transform_runtime(fixture())
        self.assertIn('guard let provider = packetTunnelProvider', text)
        self.assertIn('case .timedOut:\n            markForProviderReset()', text)
        self.assertIn('case .failure(let error):\n            markForProviderReset()', text)
        self.assertIn('throw WireGuardAdapterError.networkSettingsTimedOut', text)
        self.assertNotIn('NSCondition', text)
        self.assertNotIn('proceeding anyway', text)
        callback = text.split('provider.setTunnelNetworkSettings(networkSettings) { error in')[1].split('}', 1)[0]
        self.assertNotIn('self', callback)
        self.assertIn('completion.complete(error: error)', callback)

    def test_quarantine_is_sticky_for_start_update_stop_and_path_events(self):
        text = hook.transform_runtime(fixture())
        self.assertEqual(text.count('guard !self.requiresProviderReset else'), 3)
        self.assertIn('guard !requiresProviderReset else { return }', text)
        self.assertEqual(text.count('requiresProviderReset = false'), 1)  # initialization only
        method = text.split('private func markForProviderReset()')[1].split('private func checkedSetConfig')[0]
        self.assertIn('networkMonitor?.cancel()', method)
        self.assertIn('wgTurnOff(handle)', method)
        self.assertIn('state = .stopped', method)
        self.assertNotIn('setTunnelNetworkSettings', method)  # no speculative rollback

    def test_updates_check_bridge_return_in_both_platform_paths(self):
        text = hook.transform_runtime(fixture())
        self.assertEqual(text.count('= wgSetConfig('), 1)
        self.assertIn('guard result == 0 else', text)
        self.assertIn('updateWireGuardBackend(result)', text)
        self.assertEqual(text.count('checkedSetConfig(handle: handle, configuration: wgConfig)'), 2)

    def test_repeat_drift_and_extra_fallback_are_rejected(self):
        for text in [fixture().replace('case policyNetworkSettings(Error)', 'case drift'),
                     fixture() + hook.OLD_SETTINGS, hook.transform_runtime(fixture()),
                     fixture() + '\nextra.generateNetworkSettings()']:
            with self.subTest(text=text[:60]), self.assertRaises(ValueError):
                hook.transform_runtime(text)

    def copy_support(self, root):
        for relative in [hook.SUPPORT_PATH, 'tools/wireguard/runtime_hook.py']:
            target = root / relative; target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, target)

    def test_tested_support_and_transform_source_must_match_lock(self):
        self.assertEqual(hook.checked_support(ROOT, LOCK), (ROOT / hook.SUPPORT_PATH).read_bytes())
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); self.copy_support(root)
            (root / hook.SUPPORT_PATH).write_text('drift')
            with self.assertRaisesRegex(ValueError, 'SUPPORT_CHANGED'): hook.checked_support(root, LOCK)
            self.copy_support(root)
            (root / 'tools/wireguard/runtime_hook.py').write_text('drift')
            with self.assertRaisesRegex(ValueError, 'HOOK_CHANGED'): hook.checked_support(root, LOCK)

    def test_symlink_support_is_not_accepted_even_with_identical_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); self.copy_support(root)
            target = root / hook.SUPPORT_PATH; target.unlink()
            target.symlink_to(ROOT / hook.SUPPORT_PATH)
            with self.assertRaisesRegex(ValueError, 'SUPPORT_CHANGED'): hook.checked_support(root, LOCK)

    def test_invalid_support_blocks_before_fetch_or_compilation(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(native, 'checked_support', side_effect=ValueError('support changed')), \
                 patch.object(native, 'source_repository') as fetch, patch.object(native, 'compile_native') as compile:
                with self.assertRaises(ValueError):
                    native.build(None, LOCK, {}, Path(temp), Path(temp), True)
                fetch.assert_not_called(); compile.assert_not_called()

    def test_build_copy_and_patch_order_with_explicit_stage_doubles(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); run = root / 'run'; run.mkdir()
            calls = []
            def export(commands, repository, spec, target, paths):
                target.mkdir(parents=True, exist_ok=True)
                if paths:
                    f = target / 'Sources/WireGuardKit/WireGuardAdapter.swift'
                    f.parent.mkdir(parents=True); f.write_bytes(b'FAKE SOURCE')
                    shutil.copyfile(ROOT / 'tests/fixtures/wireguard-build/Package.swift.reference', target / 'Package.swift')
            def policy(data): calls.append(('policy', data)); return b'FAKE POLICY'
            def runtime(data): calls.append(('runtime', data)); return b'FAKE GUARDED'
            def compile(commands, tools, path, project, fetch):
                folder = path / 'wireguard-apple/Sources/WireGuardKit'
                self.assertEqual((folder / 'SplitterSettingsCompletion.swift').read_bytes(), hook.checked_support(ROOT, LOCK))
                self.assertEqual((folder / 'WireGuardAdapter.swift').read_bytes(), b'FAKE GUARDED')
                binary = path / 'fake'; binary.write_bytes(b'NOT A REAL ENGINE'); return binary
            with patch.object(native, 'source_repository', return_value=root), patch.object(native, 'export_source', side_effect=export), \
                 patch.object(native, 'patch_adapter', side_effect=policy), patch.object(native, 'patch_runtime_adapter', side_effect=runtime), \
                 patch.object(native, 'compile_native', side_effect=compile):
                result = native.build(None, LOCK, {}, root, run, False)
            self.assertEqual(calls, [('policy', b'FAKE SOURCE'), ('runtime', b'FAKE POLICY')])
            self.assertEqual(result['settings_completion_blob'], LOCK['settings_completion_blob'])
            self.assertEqual(result['patched_manifest_blob'], LOCK['patched_manifest_blob'])
            self.assertEqual(result['execution'], 'NOT_RUN')
            self.assertEqual(result['runtime_approval'], 'NOT_GRANTED')


if __name__ == '__main__':
    unittest.main()
