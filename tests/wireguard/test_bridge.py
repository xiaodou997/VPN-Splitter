"""WG-INT-04 staging/C-ABI contracts. Compiler commands below are explicit doubles."""
from pathlib import Path
import copy
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/wireguard'))
import bridge_assets as bridge
import build as native
import policy_hook
import test_build as fixtures

LOCK = json.loads(native.LOCK_PATH.read_text())
REFERENCE = ROOT / 'tests/fixtures/wireguard-build/api-apple.go.reference'


class BridgeContracts(unittest.TestCase):
    def test_assets_and_pinned_darwin_ownership_are_checked(self):
        source = bridge.checked_bridge(ROOT, LOCK)
        self.assertEqual(set(source), bridge.BRIDGE_FILES)
        self.assertEqual(policy_hook.git_blob(REFERENCE.read_bytes()), bridge.UPSTREAM_BRIDGE_BLOB)
        self.assertEqual(LOCK['engine']['blobs']['tun/tun_darwin.go'], '341afe3c5998051514cf57e2dd7efb24f0c3f9f6')
        self.assertEqual(LOCK['go_toolchains'], ['go1.26.8', 'go1.27.1'])

    def copy_assets(self, root):
        relatives = [bridge.BRIDGE_DIRECTORY + '/' + name for name in bridge.BRIDGE_FILES]
        relatives += ['tools/wireguard/bridge_assets.py', bridge.PATCH_PATH]
        for relative in relatives:
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, target)
        return relatives

    def test_asset_installer_and_review_drift_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for relative in self.copy_assets(root):
                self.copy_assets(root)
                (root / relative).write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError, 'E_WG_BRIDGE_'):
                    bridge.checked_bridge(root, LOCK)

    def test_symlink_file_and_parent_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); self.copy_assets(root)
            target = root / bridge.BRIDGE_DIRECTORY / 'lifecycle.go'
            target.unlink(); target.symlink_to(ROOT / bridge.BRIDGE_DIRECTORY / 'lifecycle.go')
            with self.assertRaisesRegex(ValueError, 'SYMLINK'):
                bridge.checked_bridge(root, LOCK)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); (root / 'tools').symlink_to(ROOT / 'tools', target_is_directory=True)
            with self.assertRaisesRegex(ValueError, 'SYMLINK'):
                bridge.checked_bridge(root, LOCK)

    def test_allowlist_and_engine_revision_cannot_drift(self):
        lock = copy.deepcopy(LOCK); lock['bridge']['files']['../bad.go'] = '0' * 40
        with self.assertRaisesRegex(ValueError, 'FILE_SET'): bridge.checked_bridge(ROOT, lock)
        lock = copy.deepcopy(LOCK); lock['engine']['revision'] = '0' * 40
        with self.assertRaisesRegex(ValueError, 'ENGINE_IDENTITY'): bridge.checked_bridge(ROOT, lock)

    def test_wrong_upstream_and_existing_destination_are_not_overwritten(self):
        sources = bridge.checked_bridge(ROOT, LOCK)
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'bridge'
            for source in [b'changed', sources['api-apple.go']]:
                with self.assertRaisesRegex(ValueError, 'BASE_CHANGED'):
                    bridge.stage_bridge(sources, source, target)
                self.assertFalse(target.exists())
            target.mkdir(); (target / 'keep').write_bytes(b'keep')
            with self.assertRaises(FileExistsError):
                bridge.stage_bridge(sources, REFERENCE.read_bytes(), target)
            self.assertEqual((target / 'keep').read_bytes(), b'keep')

    def test_exact_owned_bytes_enter_staged_build_and_no_extra_files(self):
        sources = bridge.checked_bridge(ROOT, LOCK)
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'bridge'
            bridge.stage_bridge(sources, REFERENCE.read_bytes(), target)
            self.assertEqual({p.name: p.read_bytes() for p in target.iterdir()}, sources)

    def test_review_diff_independently_applies_to_full_upstream(self):
        # Real git apply against the full official file, not a substitute fixture.
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            target = root / 'Sources/WireGuardKitGo/api-apple.go'
            target.parent.mkdir(parents=True); target.write_bytes(REFERENCE.read_bytes())
            diff = str(ROOT / bridge.PATCH_PATH)
            subprocess.run(['git', 'apply', '--check', diff], cwd=root, check=True, capture_output=True)
            subprocess.run(['git', 'apply', diff], cwd=root, check=True, capture_output=True)
            self.assertEqual(target.read_bytes(), bridge.checked_bridge(ROOT, LOCK)['api-apple.go'])
            result = subprocess.run(['git', 'apply', '--check', diff], cwd=root, capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_go_test_failure_prevents_module_download_and_native_compilation(self):
        with tempfile.TemporaryDirectory() as temp:
            run = Path(temp)
            tools = fixtures.BuildTests().fixture_run(run)
            fake = fixtures.RecordingCommands(run, failure='test -race')
            with self.assertRaises(native.BuildError):
                native.compile_native(fake, tools, run, ROOT, True)
            self.assertEqual(len(fake.calls), 1)
            self.assertEqual(fake.calls[0][0][1:3], ['test', '-race'])
            self.assertFalse((run / 'result.json').exists())

    def test_asset_failure_precedes_all_public_downloads(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(native, 'checked_bridge', side_effect=ValueError('asset drift')), \
                 patch.object(native, 'source_repository') as fetch, patch.object(native, 'compile_native') as compile:
                with self.assertRaises(ValueError): native.build(None, LOCK, {}, Path(temp), Path(temp), True)
                fetch.assert_not_called(); compile.assert_not_called()

    def test_c_entrypoints_still_match_upstream_but_raw_logging_is_disabled(self):
        source = bridge.checked_bridge(ROOT, LOCK)['api-apple.go'].decode()
        exports = set(re.findall(r'^//export (\w+)', source, flags=re.MULTILINE))
        original = set(re.findall(r'^//export (\w+)', REFERENCE.read_text(), flags=re.MULTILINE))
        self.assertEqual(exports, original)
        self.assertEqual({'_' + name for name in exports}, native.REQUIRED_SYMBOLS)
        for forbidden in ['signal.Notify(', 'runtime.Stack(', 'C.callLogger(', 'fmt.Printf(', 'log.Printf(']:
            self.assertNotIn(forbidden, source)
        self.assertIn('Verbosef: device.DiscardLogf, Errorf: device.DiscardLogf', source)
        self.assertIn('C.GoStringN(settings, C.int(n))', source)
        self.assertIn('return C.CString(settings)', source)  # raw private ABI, not diagnostics

    def test_descriptor_handoff_has_no_second_raw_close(self):
        source = bridge.checked_bridge(ROOT, LOCK)['api-apple.go'].decode()
        factory = source.split('func createBridgeDevice', 1)[1].split('//export wgSetLogger', 1)[0]
        before, after = factory.split('tun.CreateTUNFromFile(file, 0)', 1)
        self.assertIn('unix.Dup(int(tunFd))', before)
        self.assertIn('unix.Close(dupFD)', before)
        self.assertNotIn('unix.Close(', after)
        self.assertNotIn('file.Close(', after)
        self.assertIn('device.NewDevice(tunDevice', after)


if __name__ == '__main__':
    unittest.main()
