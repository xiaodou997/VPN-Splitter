"""C-header regression using real Clang and fixed upstream headers, not Apple SDK proof.

The compile-stage wiring test executes the unchanged AST body of compile_native
with an explicit bridge-stage stop double. It does not compile Go or link Swift.
"""
from __future__ import annotations
import ast
import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/wireguard'))
import c_header_hook as hook
from policy_hook import git_blob

FIXTURE = ROOT / 'tests/fixtures/wireguard-build/WireGuardKitC'
LOCK = json.loads((ROOT / 'third-party/wireguard-go/build-lock.json').read_text())
PATCH = ROOT / 'third-party/wireguard-apple/patches/0006-c-header-system-types.patch'
HASHES = {
    'WireGuardKitC.h': hook.HEADER_BLOB,
    'key.h': '5353ade48ceb07f93f79a0a2f9e09d77d9feeb87',
    'x25519.h': '7d8440dd3d4e16359d80b3128c32f4efa0e4eab0',
    'module.modulemap': '26b45bf35c5f4b424e962a2fc447efd00024a1fd',
}


class CHeaderTests(unittest.TestCase):
    def source(self):
        return (FIXTURE / 'WireGuardKitC.h').read_bytes()

    def stage(self, root):
        header = root / hook.HEADER_PATH
        header.parent.mkdir(parents=True)
        header.write_bytes(self.source())
        return header

    def test_complete_upstream_fixture_hashes_and_lock(self):
        for name, expected in HASHES.items():
            self.assertEqual(git_blob((FIXTURE / name).read_bytes()), expected)
        self.assertEqual(LOCK['apple']['blobs'][hook.HEADER_PATH], hook.HEADER_BLOB)
        self.assertEqual(LOCK['patched_c_header_blob'], hook.PATCHED_HEADER_BLOB)

    def test_only_public_include_is_added_and_structs_remain_identical(self):
        result = hook.patch_c_header(self.source())
        self.assertEqual(result.replace(b'#include <sys/types.h>\n\n', b'', 1), self.source())
        self.assertEqual(git_blob(result), hook.PATCHED_HEADER_BLOB)
        self.assertEqual(result.count(b'#include <sys/types.h>'), 1)
        self.assertNotIn(b'typedef ', result)
        self.assertNotIn(b'sys/_types/', result)

    def test_drift_and_repeat_are_rejected(self):
        for data in [b'', self.source() + b'\n', self.source().replace(b'96', b'95'),
                     self.source().replace(b'\n', b'\r\n'), hook.patch_c_header(self.source())]:
            with self.subTest(data=data[:30]), self.assertRaisesRegex(ValueError, 'UPSTREAM_C_HEADER_CHANGED'):
                hook.patch_c_header(data)

    def test_output_hash_is_enforced(self):
        with patch.object(hook, 'PATCHED_HEADER_BLOB', '0' * 40):
            with self.assertRaisesRegex(ValueError, 'RESULT_CHANGED'):
                hook.patch_c_header(self.source())

    def test_staging_changes_snapshot_not_cache_and_new_runs_work(self):
        with tempfile.TemporaryDirectory(prefix='wg header space ') as temp:
            root = Path(temp)
            cache = root / 'cache.h'; cache.write_bytes(self.source())
            for run in ('first', 'second'):
                apple = root / run
                header = self.stage(apple)
                self.assertEqual(hook.prepare_c_header(apple, LOCK), hook.PATCHED_HEADER_BLOB)
                self.assertEqual(header.read_bytes(), hook.patch_c_header(self.source()))
            self.assertEqual(cache.read_bytes(), self.source())

    def test_wrong_locks_and_unknown_bytes_preserve_file(self):
        with tempfile.TemporaryDirectory() as temp:
            apple = Path(temp); header = self.stage(apple)
            for field in ('source', 'result'):
                lock = copy.deepcopy(LOCK)
                if field == 'source': lock['apple']['blobs'][hook.HEADER_PATH] = '0' * 40
                else: lock['patched_c_header_blob'] = '0' * 40
                with self.assertRaisesRegex(ValueError, 'HEADER_LOCK'):
                    hook.prepare_c_header(apple, lock)
                self.assertEqual(header.read_bytes(), self.source())
            header.write_bytes(b'local edit')
            with self.assertRaisesRegex(ValueError, 'UPSTREAM_C_HEADER_CHANGED'):
                hook.prepare_c_header(apple, LOCK)
            self.assertEqual(header.read_bytes(), b'local edit')

    def test_symlink_file_and_parent_are_rejected(self):
        for parent in (False, True):
            with self.subTest(parent=parent), tempfile.TemporaryDirectory() as temp:
                root = Path(temp); target = root / 'original'; header = self.stage(target)
                apple = root / 'snapshot'; apple.mkdir()
                if parent:
                    (apple / 'Sources').symlink_to(target / 'Sources', target_is_directory=True)
                else:
                    dest = apple / hook.HEADER_PATH; dest.parent.mkdir(parents=True)
                    dest.symlink_to(header)
                with self.assertRaisesRegex(ValueError, 'HEADER_PATH'):
                    hook.prepare_c_header(apple, LOCK)
                self.assertEqual(header.read_bytes(), self.source())

    def test_missing_file_is_explicit_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError, 'HEADER_PATH'):
                hook.prepare_c_header(Path(temp), LOCK)

    def test_review_patch_applies_to_exact_upstream_independently(self):
        with tempfile.TemporaryDirectory() as temp:
            apple = Path(temp); header = self.stage(apple)
            for args in (['--check'], []):
                subprocess.run(['git', 'apply'] + args + [str(PATCH)], cwd=apple,
                               check=True, capture_output=True, timeout=30)
            self.assertEqual(header.read_bytes(), hook.patch_c_header(self.source()))
            result = subprocess.run(['git', 'apply', '--check', str(PATCH)], cwd=apple,
                                    capture_output=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)

    def compile_fixture(self, module, patched):
        clang = shutil.which('clang')
        if not clang: self.skipTest('Clang unavailable; header compilation NOT RUN')
        with tempfile.TemporaryDirectory(prefix='wg module ') as temp:
            root = Path(temp); inc = root / 'include'; shutil.copytree(FIXTURE, inc)
            if patched: (inc / 'WireGuardKitC.h').write_bytes(hook.patch_c_header(self.source()))
            source = root / ('probe.m' if module else 'probe.c')
            source.write_text(('@import WireGuardKitC;\n' if module else '#include "WireGuardKitC.h"\n') +
                '#include <stddef.h>\n'
                '_Static_assert(sizeof(struct ctl_info) == 100, "ctl_info size");\n'
                '_Static_assert(sizeof(struct sockaddr_ctl) == 32, "sockaddr_ctl size");\n'
                '_Static_assert(offsetof(struct ctl_info, ctl_name) == 4, "ctl name offset");\n'
                '_Static_assert(offsetof(struct sockaddr_ctl, sc_id) == 4, "id offset");\n'
                '_Static_assert(offsetof(struct sockaddr_ctl, sc_unit) == 8, "unit offset");\n'
                '_Static_assert(offsetof(struct sockaddr_ctl, sc_reserved) == 12, "reserved offset");\n')
            args = [clang, '-std=gnu11', '-Werror', '-fsyntax-only', '-I', str(inc)]
            if module:
                args += ['-fmodules', '-fmodules-cache-path=' + str(root / 'cache'),
                         '-fmodule-map-file=' + str(inc / 'module.modulemap')]
            return subprocess.run(args + [str(source)], capture_output=True, text=True, timeout=60)

    def test_fixed_header_compiles_standalone_with_layout_checks(self):
        result = self.compile_fixture(module=False, patched=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_fixed_real_clang_module_compiles_with_layout_checks(self):
        result = self.compile_fixture(module=True, patched=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(sys.platform == 'linux', 'Negative reproduction uses Linux headers, not SDK 27')
    def test_unpatched_standalone_and_module_expose_missing_types(self):
        for module in (False, True):
            with self.subTest(module=module):
                result = self.compile_fixture(module=module, patched=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('u_int32_t', result.stderr)

    def compile_stage(self, bridge_stop):
        # Exact current function body, not a replacement implementation. Only
        # the pre-existing downstream bridge stage is doubled; no native claim.
        tree = ast.parse((ROOT / 'tools/wireguard/build.py').read_text())
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef)
                        and node.name == 'compile_native')
        module = ast.Module(body=[function], type_ignores=[])
        namespace = dict(Commands=object, Path=Path, json=json,
                         prepare_c_header=hook.prepare_c_header, checked_bridge=bridge_stop)
        exec(compile(module, 'build.py::compile_native', 'exec'), namespace)
        return namespace['compile_native']

    def test_compile_stage_patches_header_before_any_tool_or_bridge(self):
        class StageReached(Exception): pass
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); run = root / 'run'; run.mkdir()
            engine = run / 'wireguard-go'; engine.mkdir()
            for name in ('go.mod', 'go.sum'): (engine / name).write_text('unchanged')
            header = self.stage(run / 'wireguard-apple')
            lockfile = root / 'third-party/wireguard-go/build-lock.json'
            lockfile.parent.mkdir(parents=True); lockfile.write_text(json.dumps(LOCK))
            stop = Mock(side_effect=StageReached)
            command = Mock()
            function = self.compile_stage(stop)
            with self.assertRaises(StageReached): function(command, {}, run, root, True)
            self.assertEqual(header.read_bytes(), hook.patch_c_header(self.source()))
            stop.assert_called_once(); command.run.assert_not_called()
            stop.reset_mock(); header.write_bytes(b'unknown')
            with self.assertRaisesRegex(ValueError, 'UPSTREAM_C_HEADER_CHANGED'):
                function(command, {}, run, root, True)
            stop.assert_not_called(); command.run.assert_not_called()
            self.assertEqual(header.read_bytes(), b'unknown')

    def test_build_records_hash_without_disabling_modules(self):
        text = (ROOT / 'tools/wireguard/build.py').read_text()
        self.assertIn('patched_c_header_blob=lock["patched_c_header_blob"]', text)
        self.assertIn('from c_header_hook import prepare_c_header', text)
        for forbidden in ('-fno-modules', '-disable-explicit-module-build', 'CLANG_ALLOW_NON_MODULAR'):
            self.assertNotIn(forbidden, text)


if __name__ == '__main__':
    unittest.main()
