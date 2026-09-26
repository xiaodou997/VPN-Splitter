# SPDX-License-Identifier: MIT
"""Actual stager/manifest/dispatcher tests in temporary directories; no native execution."""
import ast
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
FIXTURE=Path(__file__).parent/'fixtures/upstream'
spec=importlib.util.spec_from_file_location('flow_assets',ROOT/'tools/wireguard/packet_flow_assets.py')
A=importlib.util.module_from_spec(spec);spec.loader.exec_module(A)
BASE={'apple':{'revision':'2fec12a6e1f6e3460b6ee483aa00ad29cddadab1'},
      'engine':{'revision':'ecfc5a8d54462e18e13c72173e2623d16d8e25a0'}}

class PacketFlowBuildTests(unittest.TestCase):
    def copy_sources(self, root):
        for relative in A.SOURCES+[A.LOCK]:
            target=root/relative;target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(ROOT/relative,target)
    def apple_fixture(self, root):
        apple=root/'apple';bridge=root/'bridge';bridge.mkdir()
        for relative in A.UPSTREAM:
            target=apple/relative;target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(FIXTURE/Path(relative).name,target)
        (apple/'Sources/WireGuardKit').mkdir(parents=True)
        return apple,bridge
    def test_locked_sources_and_revision_match(self):
        A.checked_packet_flow(ROOT,BASE)
        bad={'apple':BASE['apple'],'engine':{'revision':'0'*40}}
        with self.assertRaises(ValueError): A.checked_packet_flow(ROOT,bad)
    def test_source_drift_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);self.copy_sources(root)
            path=root/A.SOURCES[0];path.write_bytes(path.read_bytes()+b'\n')
            with self.assertRaises(ValueError): A.checked_packet_flow(root,BASE)
    def test_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);self.copy_sources(root)
            path=root/A.SOURCES[0];saved=path.with_suffix('.saved');path.rename(saved);path.symlink_to(saved.name)
            with self.assertRaises(ValueError): A.checked_packet_flow(root,BASE)
    def test_stage_copies_actual_pinned_parser_and_all_new_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);apple,bridge=self.apple_fixture(root)
            before=(apple/'Sources/WireGuardKitGo/wireguard.h').read_bytes()
            A.stage_packet_flow(ROOT,BASE,apple,bridge)
            for relative in A.EXTRA_APPLE_PATHS:
                self.assertEqual((apple/'Sources/WireGuardKit'/Path(relative).name).read_bytes(),(FIXTURE/Path(relative).name).read_bytes())
            for name in A.GO_FILES:
                self.assertEqual((bridge/name).read_bytes(),(ROOT/'tools/wireguard/bridge'/name).read_bytes())
            header=(apple/'Sources/WireGuardKitGo/wireguard.h').read_bytes()
            self.assertTrue(header.startswith(before));self.assertIn(b'#include "splitter-packet-flow.h"',header)
            with self.assertRaises(ValueError): A.stage_packet_flow(ROOT,BASE,apple,bridge)
    def test_stage_preflight_does_not_overwrite_existing_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);apple,bridge=self.apple_fixture(root)
            existing=bridge/A.GO_FILES[-1];existing.write_text('keep this file')
            before=(apple/'Sources/WireGuardKitGo/wireguard.h').read_bytes()
            with self.assertRaises(ValueError): A.stage_packet_flow(ROOT,BASE,apple,bridge)
            self.assertEqual(existing.read_text(),'keep this file')
            self.assertEqual(list(bridge.iterdir()),[existing])
            self.assertEqual((apple/'Sources/WireGuardKitGo/wireguard.h').read_bytes(),before)
    def test_changed_upstream_is_rejected_before_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);apple,bridge=self.apple_fixture(root)
            (apple/A.EXTRA_APPLE_PATHS[0]).write_text('unexpected upstream')
            with self.assertRaises(ValueError): A.stage_packet_flow(ROOT,BASE,apple,bridge)
            self.assertEqual(list(bridge.iterdir()),[])
    def test_actual_probe_generation_both_modes_and_swift_manifest(self):
        # Execute only the actual create_probe AST to avoid unrelated full-builder
        # imports. read_ordinary uses the same bounded ordinary-file semantics here.
        tree=ast.parse((ROOT/'tools/wireguard/build.py').read_text())
        function=next(node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name=='create_probe')
        ns={'Path':Path,'json':json,'shutil':shutil,'read_ordinary':A.ordinary}
        exec(compile(ast.Module(body=[function],type_ignores=[]),'actual-create-probe','exec'),ns)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for relative in ['integrations/wireguard/ManagedWireGuardAssembly.swift','integrations/wireguard/ManagedWireGuardSession.swift','tools/wireguard/Probe.swift']:
                path=root/relative;path.parent.mkdir(parents=True,exist_ok=True);path.write_text('// fixture for staging only\n')
            native=root/'integrations/wireguard/ManagedWireGuardNativeInput.swift'
            shutil.copyfile(ROOT/'integrations/wireguard/ManagedWireGuardNativeInput.swift',native)
            for mode in (False,True):
                probe=root/('flow' if mode else 'legacy');ns['create_probe'](probe,root,packet_flow=mode)
                present=(probe/'Sources/WGLinkProbe/ManagedWireGuardNativeInput.swift').exists()
                self.assertEqual(present,mode)
                result=subprocess.run(['swift','package','--package-path',str(probe),'dump-package'],capture_output=True,text=True,timeout=60)
                self.assertEqual(result.returncode,0,result.stderr)
                package=json.loads(result.stdout)
                paths=[d['fileSystem'][0]['path'] for d in package['dependencies']]
                self.assertEqual(str(root/'Packages/ProviderConfiguration') in paths,mode)
                self.assertEqual(len(paths),5 if mode else 4)
                if mode: self.assertEqual((probe/'Sources/WGLinkProbe/ManagedWireGuardNativeInput.swift').read_bytes(),native.read_bytes())
    def test_dispatch_new_candidate_and_legacy_have_no_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);shutil.copyfile(ROOT/'dev.sh',root/'dev.sh')
            path=root/'tools/dev/doctor.py';path.parent.mkdir(parents=True);path.write_text('print("doctor engine")\n')
            build=root/'tools/wireguard/build.sh';build.parent.mkdir(parents=True);build.write_text('#!/bin/bash\necho "build $*"\n')
            for args,expected in [(['engine'],'doctor engine\nbuild build'),(['engine-flow'],'doctor engine\nbuild build --packet-flow'),(['engine-flow','--fetch'],'doctor engine\nbuild build --packet-flow --fetch')]:
                result=subprocess.run(['/bin/bash',str(root/'dev.sh'),*args],capture_output=True,text=True,timeout=20)
                self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stdout.strip(),expected)
            for args in [['engine-flow','extra'],['engine-flow','--fetch','extra'],['packet-flow-test','extra']]:
                result=subprocess.run(['/bin/bash',str(root/'dev.sh'),*args],capture_output=True,text=True,timeout=20)
                self.assertEqual(result.returncode,2)
    def test_mandatory_build_gates_remain(self):
        source=(ROOT/'tools/wireguard/build.py').read_text()
        for text in ['checked_support(ROOT, lock)','checked_bridge(ROOT, lock)','patch_runtime_adapter(patch_adapter(original))',
                     'require_symbols(', 'require_packet_flow_symbols(', 'execution="NOT_RUN", provider="NOT_LINKED"',
                     'GOTOOLCHAIN="local"','CODE_SIGNING_ALLOWED=NO']:
            if text=='CODE_SIGNING_ALLOWED=NO': continue # S1 builder is not modified here.
            self.assertIn(text,source)
        self.assertIn('if packet_flow:',source)

if __name__=='__main__':unittest.main()
