# SPDX-License-Identifier: MIT
"""Actual Swift parser/error renderer with synthetic tables; no native network reads."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / 'Packages/ExternalCore/Sources/ExternalCore'
CLI = ROOT / 'Packages/ExternalExecution/Sources/ExternalLease/ExternalLeaseMain.swift'
UI = ROOT / 'Packages/ExternalCore/Sources/ExternalPreview/ExternalPreviewApp.swift'


class RouteParserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='external-route-parser-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.binaries = []
        suffix = '.dylib' if sys.platform == 'darwin' else '.so'
        for optimization in ['-Onone', '-O']:
            folder = Path(cls.temp.name) / optimization[1:]
            folder.mkdir()
            flags = ['swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors', optimization]
            links = ['-I', str(folder), '-L', str(folder), '-Xlinker', '-rpath', '-Xlinker', str(folder)]
            def module(name, sources, dependencies):
                cls.run_command(flags + ['-emit-library', '-emit-module', '-module-name', name,
                    '-emit-module-path', str(folder / (name + '.swiftmodule')), *links, *dependencies,
                    *map(str, sources), '-o', str(folder / ('lib' + name + suffix))])
            # Only the actual address model is needed; no fake PolicyCore types or parser.
            module('PolicyCore', [ROOT / 'Packages/PolicyCore/Sources/PolicyCore/IPv4.swift'], [])
            module('ExternalCore', [CORE / 'ExternalObservation.swift', CORE / 'ExternalRouteParseDiagnostic.swift'], ['-lPolicyCore'])
            executable = folder / 'route-parser-test'
            cls.run_command(flags + links + ['-lPolicyCore', '-lExternalCore', str(Path(__file__).parent / 'fixtures/RouteParserHarness.swift'), '-o', str(executable)])
            # Execute the exact CLI catch block, with only an unrelated error enum stub.
            body = CLI.read_text().rsplit('        } catch {\n', 1)[1].split('\n        }\n    }', 1)[0]
            source = folder / 'ErrorRenderer.swift'
            source.write_text('import Foundation\nimport ExternalCore\n'
                'enum ExternalLeaseFailure: String, Error { case consentRequired }\n'
                'func report(_ error: Error, command: String) -> Int32 {\n' + body + '\n}\n'
                'do { _ = try ExternalRouteTable.parseDiagnosing(Data("bad".utf8)) }\n'
                'catch { let result = report(error, command: CommandLine.arguments[1]); precondition(result == 2) }\n')
            renderer = folder / 'error-renderer-test'
            cls.run_command(flags + links + ['-lPolicyCore', '-lExternalCore', str(source), '-o', str(renderer)])
            cls.binaries.append((executable, renderer, folder))

    @staticmethod
    def run_command(args, env=None):
        result = subprocess.run(args, text=True, capture_output=True, timeout=45, env=env)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result.stdout

    def scenario(self, name):
        for executable, _, folder in self.binaries:
            with self.subTest(optimization=folder.name):
                output = self.run_command([str(executable), name])
                self.assertIn('route-parser=PASS source=ACTUAL input=SYNTHETIC network=NOT_READ', output)

    def test_expired_routes_are_retained_and_never_usable(self):
        self.scenario('expiry')

    def test_countdowns_do_not_drift_but_expiry_transition_does(self):
        self.scenario('identity')

    def test_older_columns_and_crlf_line_numbers(self):
        self.scenario('columns')

    def test_invalid_fields_reject_whole_table_with_positions(self):
        self.scenario('invalid')

    def test_limits_and_invalid_encoding_fail_closed(self):
        self.scenario('limits')

    def test_legacy_address_rules_errors_and_redaction(self):
        self.scenario('legacy')

    def test_actual_cli_error_renderer_never_claims_apply_was_read_only(self):
        for _, renderer, folder in self.binaries:
            for command in ['inspect', 'apply', 'audit', 'clear-absent-marker']:
                with self.subTest(optimization=folder.name, command=command):
                    output = self.run_command([str(renderer), command])
                    self.assertIn('route_parse_schema=external-route-parse-v1 code=malformedRoutes line=1 field=columns columns=1', output)
                    self.assertIn('External operation stopped: malformedRoutes.', output)
                    self.assertEqual('network_settings=NOT_APPLIED' in output, command == 'inspect')
                    self.assertNotIn('unavailable', output)

    def test_native_clients_preserve_bounded_diagnostics(self):
        reader = (CORE / 'ExternalSystemSnapshot.swift').read_text()
        self.assertEqual(reader.count('ExternalRouteTable.parseDiagnosing(readRoutes())'), 2)
        self.assertIn('catch let error as ExternalRouteParseDiagnostic { throw error }', reader)
        self.assertIn('process.arguments = ["-rn", "-f", "inet"]', reader)
        self.assertIn('message = diagnostic.message', UI.read_text())
        self.assertNotIn('print(', reader)
        self.assertNotIn('write(to:', reader)
        sources = [CORE / 'ExternalObservation.swift', CORE / 'ExternalRouteParseDiagnostic.swift',
                   CORE / 'ExternalSystemSnapshot.swift', CLI, UI]
        self.run_command(['swiftc', '-frontend', '-parse', '-target', 'arm64-apple-macos26.0', *map(str, sources)])


if __name__ == '__main__':
    unittest.main()
