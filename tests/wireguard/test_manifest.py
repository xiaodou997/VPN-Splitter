"""Manifest regression: real SwiftPM evaluation, with explicit native-build stage doubles.

No protocol code, Go engine, Apple SDK object, VPN or network request is executed.
The fixture is the full pinned upstream Package.swift; license: COPYING.reference.
"""
from contextlib import ExitStack
from copy import deepcopy
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
import build as native
import policy_hook as hook

FIXTURE = ROOT / 'tests/fixtures/wireguard-build/Package.swift.reference'
REVIEW_PATCH = ROOT / 'third-party/wireguard-apple/patches/0005-manifest-tools-version.patch'
LOCK = json.loads(native.LOCK_PATH.read_text())


class ManifestTests(unittest.TestCase):
    def test_full_upstream_fixture_and_result_match_separate_hashes(self):
        self.assertEqual(hook.git_blob(FIXTURE.read_bytes()), LOCK['apple']['blobs']['Package.swift'])
        self.assertEqual(LOCK['apple']['blobs']['Package.swift'], hook.MANIFEST_BLOB)
        self.assertEqual(hook.git_blob(hook.patch_manifest(FIXTURE.read_bytes())), LOCK['patched_manifest_blob'])
        self.assertEqual(LOCK['patched_manifest_blob'], hook.PATCHED_MANIFEST_BLOB)

    def test_only_tools_version_line_changes_not_platforms_language_or_targets(self):
        original = FIXTURE.read_bytes()
        modified = hook.patch_manifest(original)
        self.assertEqual(modified.splitlines(keepends=True)[1:], original.splitlines(keepends=True)[1:])
        self.assertEqual(modified.splitlines()[0], b'// swift-tools-version:5.5')
        self.assertIn(b'.macOS(.v12)', modified)
        self.assertIn(b'.iOS(.v15)', modified)
        self.assertIn(b'.linkedLibrary("wg-go")', modified)
        self.assertNotIn(b'swiftLanguageModes', modified)

    def test_drift_missing_bytes_crlf_duplicate_header_and_repeat_are_rejected(self):
        original = FIXTURE.read_bytes()
        for value in [b'', b'\xff', original + b'\n', original.replace(b'\n', b'\r\n'),
                      original.replace(b'.v12', b'.v11'), original.splitlines(True)[0] + original,
                      hook.patch_manifest(original)]:
            with self.subTest(size=len(value)), self.assertRaisesRegex(ValueError, 'UPSTREAM_MANIFEST_CHANGED'):
                hook.patch_manifest(value)

    def test_result_hash_failure_cannot_silently_accept_different_transform(self):
        with patch.object(hook, 'PATCHED_MANIFEST_BLOB', '0' * 40):
            with self.assertRaisesRegex(ValueError, 'MANIFEST_RESULT_CHANGED'):
                hook.patch_manifest(FIXTURE.read_bytes())

    def test_review_patch_applies_to_full_original_and_repeated_apply_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='wg manifest patch ') as temp:
            root = Path(temp)
            (root / 'Package.swift').write_bytes(FIXTURE.read_bytes())
            commands = native.Commands(native.clean_environment())
            commands.git(['-C', str(root), 'apply', '--check', str(REVIEW_PATCH)])
            commands.git(['-C', str(root), 'apply', str(REVIEW_PATCH)])
            expected = hook.patch_manifest(FIXTURE.read_bytes())
            self.assertEqual((root / 'Package.swift').read_bytes(), expected)
            with self.assertRaises(native.BuildError):
                commands.git(['-C', str(root), 'apply', '--check', str(REVIEW_PATCH)])
            self.assertEqual((root / 'Package.swift').read_bytes(), expected)

    @unittest.skipUnless(shutil.which('swift'), 'SwiftPM unavailable; manifest evaluation NOT RUN')
    def test_real_swiftpm_reproduces_53_error_and_evaluates_55_without_building_engine(self):
        with tempfile.TemporaryDirectory(prefix='wg manifest evaluation ') as temp:
            manifest = Path(temp) / 'Package.swift'
            command = [shutil.which('swift'), 'package', '--package-path', temp, 'dump-package']
            manifest.write_bytes(FIXTURE.read_bytes())
            bad = subprocess.run(command, capture_output=True, text=True, timeout=60,
                                 env=native.clean_environment())
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn("'v12' is unavailable", bad.stderr)
            self.assertIn("'v15' is unavailable", bad.stderr)
            self.assertIn('introduced in PackageDescription 5.5', bad.stderr)
            manifest.write_bytes(hook.patch_manifest(FIXTURE.read_bytes()))
            good = subprocess.run(command, capture_output=True, text=True, timeout=60,
                                  env=native.clean_environment())
            self.assertEqual(good.returncode, 0, good.stderr)
            description = json.loads(good.stdout)
            self.assertEqual(description['toolsVersion']['_version'], '5.5.0')
            self.assertEqual({p['platformName']: p['version'] for p in description['platforms']},
                             {'macos': '12.0', 'ios': '15.0'})
            self.assertEqual([t['name'] for t in description['targets']],
                             ['WireGuardKit', 'WireGuardKitC', 'WireGuardKitGo'])
            self.assertEqual(description['dependencies'], [])
            self.assertFalse((Path(temp) / 'libwg-go.a').exists())

    def run_pipeline(self, root, content=None, lock=None, fetch=False, symlink=False, missing=False,
                     compile_error=False, export_error=False):
        """Only manifest transform/I/O are real. Other stages explicitly do not build an engine."""
        run = root / 'run'; run.mkdir()
        original = FIXTURE.read_bytes() if content is None else content
        original_cache = root / 'upstream-Package.swift'; original_cache.write_bytes(original)
        events = []
        def export(commands, repository, spec, target, paths):
            events.append('export')
            if export_error:
                raise native.BuildError('injected source verification failure')
            target.mkdir()
            if paths:
                folder = target / 'Sources/WireGuardKit'; folder.mkdir(parents=True)
                (folder / 'WireGuardAdapter.swift').write_bytes(b'EXPLICIT SYNTHETIC ADAPTER')
                if symlink:
                    (target / 'Package.swift').symlink_to(original_cache)
                elif not missing:
                    (target / 'Package.swift').write_bytes(original)
        def adapter(data):
            events.append('adapter')
            self.assertEqual((run / 'wireguard-apple/Package.swift').read_bytes(), hook.patch_manifest(FIXTURE.read_bytes()))
            return data
        def compile(commands, tools, path, project, allow_fetch):
            events.append('compile')
            self.assertEqual(allow_fetch, fetch)
            self.assertEqual(original_cache.read_bytes(), original)
            if compile_error:
                raise native.BuildError('injected native compilation failure')
            artifact = run / 'fake-artifact'; artifact.write_bytes(b'NOT A REAL ENGINE')
            return artifact
        with ExitStack() as stack:
            stack.enter_context(patch.object(native, 'checked_support', return_value=b'EXPLICIT SYNTHETIC SUPPORT'))
            stack.enter_context(patch.object(native, 'checked_bridge', return_value={}))
            stack.enter_context(patch.object(native, 'source_repository', return_value=root))
            stack.enter_context(patch.object(native, 'export_source', side_effect=export))
            stack.enter_context(patch.object(native, 'patch_adapter', side_effect=adapter))
            stack.enter_context(patch.object(native, 'patch_runtime_adapter', side_effect=lambda data: data))
            stack.enter_context(patch.object(native, 'compile_native', side_effect=compile))
            try:
                result = native.build(None, LOCK if lock is None else lock, {}, root, run, fetch)
                return result, events
            finally:
                self.assertEqual(original_cache.read_bytes(), original)
                if content is not None or symlink or missing or export_error or lock is not None:
                    self.assertNotIn('compile', events)
                    self.assertFalse((run / 'result.json').exists())

    def test_build_patches_before_adapter_and_compile_and_records_actual_blob(self):
        for fetch in [False, True]:
            with self.subTest(fetch=fetch), tempfile.TemporaryDirectory(prefix='wg stage ') as temp:
                result, events = self.run_pipeline(Path(temp), fetch=fetch)
                self.assertEqual(events, ['export', 'export', 'adapter', 'compile'])
                self.assertEqual(result['patched_manifest_blob'], LOCK['patched_manifest_blob'])
                self.assertEqual(result['execution'], 'NOT_RUN')
                self.assertEqual(result['runtime_approval'], 'NOT_GRANTED')
                self.assertEqual(result['provider'], 'NOT_LINKED')
                self.assertEqual(result['network_settings'], 'NOT_APPLIED')

    def test_bad_exported_manifest_stops_before_adapter_or_compilation(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError, 'UPSTREAM_MANIFEST_CHANGED'):
                self.run_pipeline(Path(temp), content=b'not the reviewed manifest')
            self.assertEqual((Path(temp) / 'run/wireguard-apple/Package.swift').read_bytes(),
                             b'not the reviewed manifest')

    def test_symlink_manifest_never_writes_through_to_cached_original(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(native.BuildError, 'MANIFEST_PATH'):
                self.run_pipeline(Path(temp), symlink=True)

    def test_missing_manifest_is_error_not_an_unpatched_fallback(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(FileNotFoundError):
                self.run_pipeline(Path(temp), missing=True)

    def test_inconsistent_output_lock_stops_before_write(self):
        lock = deepcopy(LOCK); lock['patched_manifest_blob'] = '0' * 40
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(native.BuildError, 'MANIFEST_LOCK'):
                self.run_pipeline(Path(temp), lock=lock)
            self.assertEqual((Path(temp) / 'run/wireguard-apple/Package.swift').read_bytes(), FIXTURE.read_bytes())

    def test_new_runs_patch_fresh_snapshots_without_touching_old_failure_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            first = root / 'first'; first.mkdir()
            second = root / 'second'; second.mkdir()
            self.run_pipeline(first)
            old_manifest = first / 'run/wireguard-apple/Package.swift'
            old_manifest.write_bytes(b'preserved failed-run contents')
            self.run_pipeline(second)
            self.assertEqual(old_manifest.read_bytes(), b'preserved failed-run contents')

    def test_later_compile_failure_is_not_manifest_or_whole_build_success(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(native.BuildError, 'native compilation failure'):
                self.run_pipeline(Path(temp), compile_error=True)
            self.assertFalse((Path(temp) / 'run/result.json').exists())

    def test_original_source_verification_failure_prevents_patching(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(native.BuildError, 'source verification failure'):
                self.run_pipeline(Path(temp), export_error=True)
            self.assertFalse((Path(temp) / 'run/wireguard-apple/Package.swift').exists())


if __name__ == '__main__':
    unittest.main()
