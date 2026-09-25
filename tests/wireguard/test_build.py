"""Build-plan/failure tests with explicit tool doubles; NOT native engine tests."""
from __future__ import annotations
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/wireguard'))
import build as native
import policy_hook
LOCK = json.loads((ROOT / 'third-party/wireguard-go/build-lock.json').read_text())

# Own synthetic Swift fixture; hashes are NOT substituted into production locks.
# Matching surrounding text exercises occurrence counts and preservation only.
ADAPTER = '''enum WireGuardAdapterError: Error {
    case setNetworkSettings(Error)
}
class WireGuardAdapter {
    private let logHandler: LogHandler
    public init(with packetTunnelProvider: NEPacketTunnelProvider, logHandler: @escaping LogHandler) {
        self.logHandler = logHandler
    }
    func start() { try self.setNetworkSettings(settingsGenerator.generateNetworkSettings()) }
    func update() { try self.setNetworkSettings(settingsGenerator.generateNetworkSettings()) }
    func resume() { try self.setNetworkSettings(settingsGenerator.generateNetworkSettings()) }
    func protocolSettings() { settingsGenerator.uapiConfiguration() }
    private func setNetworkSettings(_ networkSettings: NEPacketTunnelNetworkSettings) throws {
    }
}
'''


class RecordingCommands:
    """No subprocesses, downloads, Go, Swift compilation or native API calls."""
    def __init__(self, run: Path, failure: str = '', mutate_lock: bool = False):
        self.run_dir = run
        self.calls = []
        self.failure = failure
        self.mutate_lock = mutate_lock

    def run(self, args, cwd=None, timeout=120, extra=None):
        self.calls.append((list(args), cwd, extra))
        label = ' '.join(args)
        if self.failure and self.failure in label:
            raise native.BuildError('injected compiler failure')
        if args[1:3] == ['mod', 'download'] and self.mutate_lock:
            (cwd / 'go.sum').write_text('changed')
        if 'lipo' in args:
            return 'arm64'
        if 'nm' in args:
            return '\n'.join('0000000010 T ' + symbol for symbol in native.REQUIRED_SYMBOLS)
        if '--show-bin-path' in args:
            folder = self.run_dir / 'swift-build/debug'
            folder.mkdir(parents=True)
            (folder / 'WGLinkProbe').write_text('FAKE not executable')
            return str(folder)
        return ''

    def git(self, args, **kwargs):
        return self.run(['git'] + args, **kwargs)


class BuildTests(unittest.TestCase):
    def test_pinned_candidate_is_separate_from_reference(self):
        self.assertEqual(LOCK['schema'], 'wireguard-build-candidate-v1')
        for item in ('apple', 'engine'):
            native.validate_spec(LOCK[item])
        self.assertEqual(LOCK['apple']['blobs']['Sources/WireGuardKit/WireGuardAdapter.swift'], policy_hook.ADAPTER_BLOB)
        self.assertTrue(LOCK['open_gates'])
        self.assertIn('not a runtime or release approval', LOCK['scope'])

    def test_reviewed_patch_and_license_hashes(self):
        self.assertEqual(LOCK['patched_adapter_blob'], policy_hook.PATCHED_ADAPTER_BLOB)
        self.assertEqual(policy_hook.git_blob((ROOT / 'third-party/wireguard-go/LICENSE.reference').read_bytes()),
                         LOCK['engine']['blobs']['LICENSE'])
        diff = (ROOT / 'third-party/wireguard-apple/patches/0001-required-policy-settings.patch').read_text()
        self.assertEqual(diff.count('+                try self.setNetworkSettings(self.policyNetworkSettings(settingsGenerator))'), 3)
        self.assertIn('networkSettingsProvider: @escaping', diff)

    def test_mac_preflight_version_and_installed_go_only(self):
        class Preflight:
            def __init__(self, go_version='go1.26.8'):
                self.go_version = go_version
            def run(self, args):
                if '-productVersion' in args: return '26.0'
                if '--show-sdk-version' in args: return '26.0'
                if '--show-sdk-path' in args: return '/SDK with spaces'
                if args[-1] == 'GOVERSION': return self.go_version
                return 'synthetic tool information'
        with patch.object(native.platform, 'system', return_value='Darwin'), patch.object(native.platform, 'machine', return_value='arm64'):
            with patch.object(native.shutil, 'which', return_value='/installed go/bin/go'):
                self.assertEqual(native.preflight(Preflight(), LOCK)['go_version'], 'go1.26.8')
                with self.assertRaisesRegex(native.BuildError, 'E_GO'):
                    native.preflight(Preflight('go1.23.2'), LOCK)
            with patch.object(native.shutil, 'which', return_value=None):
                with self.assertRaisesRegex(native.BuildError, 'E_GO'):
                    native.preflight(Preflight(), LOCK)

    def test_unapproved_sources_and_floating_refs_are_rejected(self):
        for change in ({'url': 'file:///private'}, {'url': 'https://example.invalid/repo'},
                       {'revision': 'master'}, {'tree': 'latest'}):
            item = dict(LOCK['apple']); item.update(change)
            with self.assertRaises(native.BuildError): native.validate_spec(item)

    def test_actual_hash_required_before_patching(self):
        with self.assertRaisesRegex(ValueError, 'UPSTREAM_ADAPTER_CHANGED'):
            policy_hook.patch_adapter(ADAPTER.encode())
        with self.assertRaises(ValueError): policy_hook.patch_adapter(b'')

    def test_required_hook_has_no_default_and_covers_all_paths(self):
        result = policy_hook.transform_adapter(ADAPTER)
        self.assertEqual(result.count('self.policyNetworkSettings(settingsGenerator)'), 3)
        self.assertNotIn('.generateNetworkSettings()', result)
        self.assertIn('networkSettingsProvider: @escaping', result)
        self.assertIn('settingsGenerator.uapiConfiguration()', result)
        self.assertIn('WireGuardAdapterError.policyNetworkSettings(error)', result)
        self.assertIn('try networkSettingsProvider(generator.tunnelConfiguration)', result)
        self.assertNotIn('networkSettingsProvider: @escaping (TunnelConfiguration) throws -> NEPacketTunnelNetworkSettings =', result)

    def test_patch_refuses_drift_duplicate_anchors_and_repeat(self):
        for value in (ADAPTER.replace('func resume() { try self.setNetworkSettings(settingsGenerator.generateNetworkSettings()) }', ''),
                      ADAPTER + '\n    private let logHandler: LogHandler\n',
                      policy_hook.transform_adapter(ADAPTER)):
            with self.assertRaises(ValueError): policy_hook.transform_adapter(value)

    def test_no_remaining_generator_fallback_allowed(self):
        with self.assertRaisesRegex(ValueError, 'POLICY_FALLBACK'):
            policy_hook.transform_adapter(ADAPTER + '\nextra.generateNetworkSettings()')

    def test_environment_discards_user_overrides_but_verifies_tls_and_modules(self):
        with patch.dict(os.environ, {'GOFLAGS': '-mod=mod', 'GOTOOLCHAIN': 'auto', 'GIT_DIR': '/other',
                                    'GIT_SSL_NO_VERIFY': '1', 'CGO_CFLAGS': 'bad', 'GOWORK': '/other',
                                    'GOSUMDB': 'off', 'DYLD_INSERT_LIBRARIES': '/other'}):
            env = native.clean_environment()
        self.assertEqual(env['GOSUMDB'], 'sum.golang.org')
        self.assertEqual(env['GOPROXY'], 'off')
        self.assertEqual(env['GOTOOLCHAIN'], 'local')
        self.assertEqual(env['GOWORK'], 'off')
        for key in ['GOFLAGS', 'GIT_DIR', 'GIT_SSL_NO_VERIFY', 'CGO_CFLAGS', 'DYLD_INSERT_LIBRARIES']:
            self.assertNotIn(key, env)

    def test_platform_rejected_before_commands(self):
        fake = RecordingCommands(Path('/unused'))
        with patch.object(native.platform, 'system', return_value='Linux'):
            with self.assertRaisesRegex(native.BuildError, 'E_PLATFORM'):
                native.preflight(fake, LOCK)
        self.assertEqual(fake.calls, [])

    def test_cli_linux_does_not_create_build_directories(self):
        if sys.platform != 'linux': self.skipTest('Linux-only rejection check')
        output = ROOT / '.local/wireguard-engine'
        before = output.exists()
        result = subprocess.run(['/bin/bash', str(ROOT / 'tools/wireguard/build.sh'), 'build', '--fetch'],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('E_PLATFORM', result.stderr)
        self.assertNotIn('PASS', result.stdout)
        self.assertEqual(output.exists(), before)

    def test_command_failure_and_timeout_are_errors(self):
        commands = native.Commands(native.clean_environment())
        with self.assertRaises(native.BuildError):
            commands.run([sys.executable, '-c', 'raise SystemExit(7)'])
        with self.assertRaises(native.BuildError):
            commands.run([sys.executable, '-c', 'import time; time.sleep(3)'], timeout=0.02)

    def test_locked_build_does_not_allow_second_writer(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'build.lock'
            with native.build_lock(path):
                with self.assertRaisesRegex(native.BuildError, 'E_BUSY'):
                    with native.build_lock(path): pass
            self.assertTrue(path.exists())
            with native.build_lock(path): pass

    def test_cache_absence_without_fetch_does_not_run_git(self):
        with tempfile.TemporaryDirectory() as temporary:
            fake = RecordingCommands(Path(temporary))
            with self.assertRaisesRegex(native.BuildError, 'E_CACHE'):
                native.source_repository(fake, Path(temporary), 'apple', LOCK['apple'], False)
            self.assertEqual(fake.calls, [])

    def test_cache_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            (cache / ('apple-' + LOCK['apple']['revision'] + '.git')).symlink_to('/does/not/exist')
            with self.assertRaisesRegex(native.BuildError, 'symlink'):
                native.source_repository(RecordingCommands(cache), cache, 'apple', LOCK['apple'], True)

    def test_verify_tree_mismatch_precedes_archive(self):
        class WrongTree(RecordingCommands):
            def git(self, args, **kwargs):
                self.calls.append(args); return '0' * 40
        fake = WrongTree(Path('/unused'))
        with self.assertRaisesRegex(native.BuildError, 'tree mismatch'):
            native.verify_repository(fake, Path('/unused'), LOCK['apple'])
        self.assertEqual(len(fake.calls), 1)

    def archive(self, path, entries):
        with tarfile.open(path, 'w') as archive:
            for name, kind, value in entries:
                item = tarfile.TarInfo(name); item.type = kind
                if kind == tarfile.REGTYPE:
                    data = value.encode(); item.size = len(data)
                    archive.addfile(item, io.BytesIO(data))
                else:
                    item.linkname = value; archive.addfile(item)

    def test_archive_regular_files_and_spaces(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); archive = root / 'source.tar'
            self.archive(archive, [('folder/a b.swift', tarfile.REGTYPE, 'source')])
            native.unpack(archive, root / 'out')
            self.assertEqual((root / 'out/folder/a b.swift').read_text(), 'source')

    def test_archive_rejects_traversal_links_and_duplicate_paths_before_write(self):
        for name, kind, value in [('../outside', tarfile.REGTYPE, 'bad'), ('/abs', tarfile.REGTYPE, 'bad'),
                                  ('.git/config', tarfile.REGTYPE, 'bad'), ('alias', tarfile.SYMTYPE, '../target'),
                                  ('hard', tarfile.LNKTYPE, 'first'), ('dev', tarfile.CHRTYPE, '')]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); archive = root / 'source.tar'
                self.archive(archive, [('first', tarfile.REGTYPE, 'keep'), (name, kind, value)])
                with self.assertRaises(native.BuildError): native.unpack(archive, root / 'out')
                self.assertFalse((root / 'out').exists())
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); archive = root / 'source.tar'
            self.archive(archive, [('a/b', tarfile.REGTYPE, 'one'), ('a//b', tarfile.REGTYPE, 'two')])
            with self.assertRaises(native.BuildError): native.unpack(archive, root / 'out')
            self.assertFalse((root / 'out').exists())

    def test_real_git_export_checks_complete_file_inventory(self):
        with tempfile.TemporaryDirectory(prefix='git archive test ') as temporary:
            root = Path(temporary); repository = root / 'repo'; commands = native.Commands(native.clean_environment())
            commands.git(['init', str(repository)])
            (repository / 'source.swift').write_text('synthetic source\n')
            (repository / 'folder').mkdir()
            (repository / 'folder/data').write_bytes(b'data')
            commands.git(['-C', str(repository), 'add', '.'])
            commands.git(['-C', str(repository), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                          'commit', '-m', 'synthetic archive'])
            revision = commands.git(['-C', str(repository), 'rev-parse', 'HEAD'])
            tree = commands.git(['-C', str(repository), 'rev-parse', 'HEAD^{tree}'])
            spec = dict(revision=revision, tree=tree,
                        blobs={'source.swift': policy_hook.git_blob(b'synthetic source\n')})
            native.verify_repository(commands, repository / '.git', spec)
            native.export_source(commands, repository / '.git', spec, root / 'out')
            self.assertEqual((root / 'out/folder/data').read_bytes(), b'data')
            # A cache-specific export-ignore must not silently strip a locked file.
            (repository / '.git/info/attributes').write_text('folder/data export-ignore\n')
            with self.assertRaisesRegex(native.BuildError, 'SOURCE_FILE_SET'):
                native.export_source(commands, repository / '.git', spec, root / 'ignored')

    def test_source_tree_inventory_rejects_gitlinks_and_symlinks(self):
        for mode, kind in [('120000', 'blob'), ('160000', 'commit')]:
            with self.assertRaises(native.BuildError): native.tree_files(f'{mode} {kind} ' + 'a' * 40 + '\titem\0')
        self.assertEqual(native.tree_files('100644 blob ' + 'b' * 40 + '\ta b\0'), {'a b': 'b' * 40})

    def test_symbols_must_be_defined_not_merely_referenced(self):
        native.require_symbols('\n'.join('0000010 T ' + symbol for symbol in native.REQUIRED_SYMBOLS))
        with self.assertRaises(native.BuildError):
            native.require_symbols('\n'.join(' U ' + symbol for symbol in native.REQUIRED_SYMBOLS))
        with self.assertRaises(native.BuildError): native.require_symbols('00001 T _wgVersion')

    def fixture_run(self, root):
        (root / 'wireguard-go').mkdir()
        (root / 'wireguard-go/go.mod').write_text('locked mod')
        (root / 'wireguard-go/go.sum').write_text('locked sum')
        bridge = root / 'wireguard-apple/Sources/WireGuardKitGo'; bridge.mkdir(parents=True)
        (bridge / 'api-apple.go').write_bytes((ROOT / 'tests/fixtures/wireguard-build/api-apple.go.reference').read_bytes())
        return dict(go='/test tools/go', swift='/test tools/swift', sdk='/test sdk', clang='/test tools/clang')

    def test_compile_sequence_and_no_executable_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary); tools = self.fixture_run(run); fake = RecordingCommands(run)
            artifact = native.compile_native(fake, tools, run, ROOT, True)
            calls = [args for args, _, _ in fake.calls]
            self.assertEqual(calls[0], [tools['go'], 'test', '-race', '-count=1', '-timeout=60s',
                                        'lifecycle.go', 'lifecycle_test.go'])
            self.assertEqual(calls[1], [tools['go'], 'mod', 'download'])
            self.assertEqual(calls[2], [tools['go'], 'mod', 'verify'])
            self.assertIn('-mod=readonly', calls[3])
            self.assertIn('-buildmode=c-archive', calls[3])
            self.assertEqual(fake.calls[1][2], {'GOPROXY': 'https://proxy.golang.org'})
            self.assertIn('-force_load', next(args for args in calls if args[0] == tools['swift']))
            self.assertFalse(any(args[0] == str(artifact) for args in calls))
            self.assertFalse(any('Makefile' in ' '.join(args) for args in calls))
            self.assertTrue(artifact.is_file())  # Explicit fake bytes, not executable.

    def test_offline_build_never_downloads(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary); fake = RecordingCommands(run)
            native.compile_native(fake, self.fixture_run(run), run, ROOT, False)
            self.assertFalse(any(args[1:3] == ['mod', 'download'] for args, _, _ in fake.calls))
            self.assertFalse(any(extra and 'GOPROXY' in extra for _, _, extra in fake.calls))

    def test_go_failure_prevents_swift_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary); fake = RecordingCommands(run, failure='-buildmode=c-archive')
            with self.assertRaises(native.BuildError):
                native.compile_native(fake, self.fixture_run(run), run, ROOT, False)
            self.assertFalse(any(args[0].endswith('/swift') for args, _, _ in fake.calls))

    def test_swift_failure_never_returns_success_or_runs_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary); fake = RecordingCommands(run, failure='--scratch-path')
            with self.assertRaises(native.BuildError):
                native.compile_native(fake, self.fixture_run(run), run, ROOT, False)
            self.assertFalse((run / 'result.json').exists())

    def test_dependency_lock_mutation_prevents_compilation(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary); fake = RecordingCommands(run, mutate_lock=True)
            with self.assertRaisesRegex(native.BuildError, 'MODULE_LOCK_CHANGED'):
                native.compile_native(fake, self.fixture_run(run), run, ROOT, True)
            self.assertEqual(len(fake.calls), 3)

    def test_probe_manifest_and_source_are_isolated(self):
        with tempfile.TemporaryDirectory(prefix='wg path with spaces ') as temporary:
            probe = Path(temporary) / 'probe'
            native.create_probe(probe, ROOT)
            manifest = (probe / 'Package.swift').read_text()
            self.assertNotIn('.package(url:', manifest)
            self.assertIn('ManagedSettingsApple', manifest)
            text = (probe / 'Sources/WGLinkProbe/main.swift').read_text()
            self.assertIn('networkSettingsProvider:', text)
            self.assertIn('makeForInspection', text)
            for forbidden in ['.start(', '.update(', 'setTunnelNetworkSettings(', 'NETunnelProviderManager', 'SecItem', 'URLSession']:
                self.assertNotIn(forbidden, text)

    def test_original_entrypoints_do_not_depend_on_engine_build(self):
        # Scope guarantee is complemented by the final Git file-change comparison.
        text = (ROOT / 'tools/wireguard/build.py').read_text()
        self.assertNotIn('codesign', text)
        self.assertNotIn('sudo ', text)
        self.assertNotIn('rsync', text)
        self.assertNotIn('rmtree', text)
        self.assertNotIn('shell=True', text)
        self.assertIn('artifact_execution=NOT_RUN', text)
        self.assertIn('provider=NOT_LINKED', text)


if __name__ == '__main__':
    unittest.main()
