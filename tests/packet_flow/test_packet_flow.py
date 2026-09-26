# SPDX-License-Identifier: MIT
"""Offline only. Native frameworks, authentication and the WireGuard engine are NOT exercised."""
import ast
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = Path(__file__).parent / 'fixtures'
TOOLS = ROOT / 'tools/wireguard'
spec = importlib.util.spec_from_file_location('packet_flow_assets', TOOLS / 'packet_flow_assets.py')
ASSETS = importlib.util.module_from_spec(spec); spec.loader.exec_module(ASSETS)

class PacketFlowTests(unittest.TestCase):
    def run_checked(self, args, cwd=None, env=None, timeout=120):
        started = time.monotonic()
        label = Path(args[0]).name
        print("packet-flow-step=START " + label, flush=True)
        result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
        print("packet-flow-step=END " + label + " seconds=" + str(round(time.monotonic() - started, 2)), flush=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def fixture_engine(self, directory):
        root = Path(directory)
        (root / 'go.mod').write_text('module golang.zx2c4.com/wireguard\n\ngo 1.22\n')
        for name in ('tun', 'conn', 'device', 'splitterbridge'):
            (root / name).mkdir()
        shutil.copyfile(FIXTURE / 'upstream/tun.go', root / 'tun/tun.go')
        for name in ('conn', 'device'):
            shutil.copyfile(FIXTURE / ('go/' + name + '.go'), root / name / (name + '.go'))
        bridge = root / 'splitterbridge'
        for name in ASSETS.GO_FILES:
            shutil.copyfile(TOOLS / 'bridge' / name, bridge / name)
        for name in ('lifecycle-double.go', 'packet-flow-tun_test.go'):
            shutil.copyfile(FIXTURE / 'go' / name, bridge / name)
        return root

    def go_environment(self):
        env = dict(os.environ)
        env.update(GOTOOLCHAIN='local', GOPROXY='off', GOWORK='off', GOENV='off', CGO_ENABLED='1')
        return env

    def test_upstream_fixture_bytes(self):
        expected = {'tun.go': '336d642251f91a80e30eeb0c74d8afa15393b884',
                    'TunnelConfiguration+WgQuickConfig.swift': '86af010c69c5f2dc59a3585386ad394af846705f',
                    'String+ArrayConversion.swift': '97984f82ef0cfb5d19f20cd5be387260691ab61a'}
        for name, digest in expected.items():
            self.assertEqual(ASSETS.blob((FIXTURE / 'upstream' / name).read_bytes()), digest)

    def test_go_queues_and_real_tun_interface_race(self):
        self.assertIsNotNone(shutil.which('go'), 'Go is required; tests must not silently skip')
        with tempfile.TemporaryDirectory(prefix='vpn-flow-go-') as directory:
            root = self.fixture_engine(directory)
            output = self.run_checked(['go', 'test', '-race', '-count=1', '-timeout=30s', '-v', './splitterbridge'], cwd=root, env=self.go_environment())
            self.assertEqual(output.count('--- PASS: TestFlow'), 18)
            print(output.strip())

    def test_swift_c_go_packet_pump_and_conversion(self):
        self.assertIsNotNone(shutil.which('swiftc'))
        with tempfile.TemporaryDirectory(prefix='vpn-flow-native-double-') as directory:
            root = self.fixture_engine(directory)
            self.run_checked(['go', 'build', '-buildmode=c-archive', '-o', str(root / 'libflow.a'), './splitterbridge'], cwd=root, env=self.go_environment())
            cmodule = root / 'WireGuardKitGo'; cmodule.mkdir()
            shutil.copyfile(TOOLS / 'native/splitter-packet-flow.h', cmodule / 'splitter-packet-flow.h')
            (cmodule / 'module.modulemap').write_text('module WireGuardKitGo { header "splitter-packet-flow.h" export * }\n')
            suffix = 'dylib' if sys.platform == 'darwin' else 'so'
            def module(name, files, dependencies=(), archive=False):
                args = ['swiftc', '-swift-version', '6', '-warnings-as-errors', '-D', 'SWIFT_PACKAGE',
                        '-emit-library', '-emit-module', '-module-name', name, '-I', str(root), '-L', str(root)]
                args += ['-l' + dep for dep in dependencies]
                args += [str(file) for file in files]
                if archive: args += [str(root / 'libflow.a'), '-Xlinker', '-lpthread', '-Xlinker', '-ldl', '-Xlinker', '-lm'] if sys.platform != 'darwin' else [str(root / 'libflow.a')]
                args += ['-o', str(root / ('lib' + name + '.' + suffix))]
                self.run_checked(args, cwd=root)
            module('Network', [FIXTURE / 'Network.swift'])
            module('NetworkExtension', [FIXTURE / 'NetworkExtension.swift'])
            module('PolicyCore', [FIXTURE / 'PolicyCore.swift'])
            module('ProviderConfiguration', [FIXTURE / 'ProviderConfiguration.swift'], ['PolicyCore'])
            module('WireGuardKit', [FIXTURE / 'WireGuardModels.swift',
                   FIXTURE / 'upstream/TunnelConfiguration+WgQuickConfig.swift', FIXTURE / 'upstream/String+ArrayConversion.swift',
                   TOOLS / 'native/SplitterNativeConfiguration.swift', TOOLS / 'native/SplitterPacketFlowBackend.swift'],
                   ['Network', 'NetworkExtension'], archive=True)
            executable = root / 'flow-harness'
            self.run_checked(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                '-I', str(root), '-L', str(root), '-lWireGuardKit', '-lNetwork', '-lNetworkExtension', '-lPolicyCore', '-lProviderConfiguration',
                str(ROOT / 'integrations/wireguard/ManagedWireGuardNativeInput.swift'), str(FIXTURE / 'PacketFlowHarness.swift'), '-o', str(executable)], cwd=root)
            env = dict(os.environ); env['DYLD_LIBRARY_PATH' if sys.platform == 'darwin' else 'LD_LIBRARY_PATH'] = str(root)
            output = self.run_checked([str(executable)], env=env, timeout=30)
            self.assertIn('packet-flow-harness=PASS scenarios=19', output)
            self.assertIn('network=NOT_APPLIED', output)
            print(output.strip())

    def test_native_source_does_not_guess_tunnel_or_apply_settings(self):
        source = (TOOLS / 'native/SplitterPacketFlowBackend.swift').read_text()
        for forbidden in ('getutun', 'getsockopt(', 'socket(', 'value(forKey:', 'setTunnelNetworkSettings(', 'generateNetworkSettings()', 'print(', 'NSLog('):
            # Exclude comments describing the prohibited upstream generator call.
            code = '\n'.join(line for line in source.splitlines() if not line.strip().startswith('///') and not line.strip().startswith('//'))
            self.assertNotIn(forbidden, code)
        for required in ('provider.packetFlow', 'flow.readPackets', 'flow.writePackets', 'wgTurnOnPacketFlow', 'closing.wait()'):
            self.assertIn(required, source)
        api = (TOOLS / 'bridge/packet-flow-api.go').read_text()
        self.assertIn('device.NewDevice(flow, conn.NewStdNetBind(), logger)', api)
        self.assertIn('flow.Close()', api)
        self.assertIn('packetFlows.stopping', api)

    def test_symbols_need_definitions(self):
        defined = '\n'.join('0001 T ' + name for name in ASSETS.FLOW_SYMBOLS)
        ASSETS.require_packet_flow_symbols(defined)
        for invalid in ['', '\n'.join(' U ' + name for name in ASSETS.FLOW_SYMBOLS), defined.splitlines()[0]]:
            with self.assertRaises(ValueError): ASSETS.require_packet_flow_symbols(invalid)

if __name__ == '__main__': unittest.main()
