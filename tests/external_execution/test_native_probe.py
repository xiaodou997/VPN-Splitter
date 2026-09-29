# SPDX-License-Identifier: MIT
"""Actual native Swift bridge/CLI code; C, topology and journal are explicit doubles.
The actual Darwin C adapter is separately exercised by test_native_route.py.
No real privileges, routing socket, system collection, journals or Apple SDK required.
"""
from pathlib import Path
import ast
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / 'Packages/ExternalExecution/Sources'

C_DOUBLE = r'''
#include "test_bridge.h"
#include <stdlib.h>
struct er_context { int query; uint32_t attempts; };
static int status, gets, adds, removes;
void test_status(int32_t value) { status=value; gets=adds=removes=0; }
int32_t test_gets(void) { return gets; }
int32_t test_adds(void) { return adds; }
int32_t test_removes(void) { return removes; }
er_context *er_open(void) { return calloc(1,sizeof(er_context)); }
er_context *er_open_query(void) { er_context *c=er_open(); if(c)c->query=1; return c; }
void er_close(er_context *c) { free(c); }
int32_t er_drain(er_context *c) { (void)c; return 1; }
int32_t er_owns(er_context *c,uint64_t t) { (void)c;(void)t;return 0; }
er_result er_probe(er_context *c,er_spec s) { (void)s; if(!c->query)abort(); gets+=status?1:2; return (er_result){status,0}; }
er_result er_add(er_context *c,er_spec s) { (void)s; if(c->query)abort(); adds++; if(status!=3)c->attempts++; return (er_result){status,status?0:1}; }
er_result er_remove(er_context *c,uint64_t t) { (void)t; if(c->query)abort(); removes++; return (er_result){1,0}; }
er_diagnostic er_get_diagnostic(const er_context *c) {
    er_diagnostic d={0}; d.stage=status?ER_STAGE_TARGET_GET:ER_STAGE_GATEWAY_GET;
    d.reason=status?ER_REASON_DECODE:ER_REASON_NONE; d.decode_field=status?2:0;
    d.mutation_attempts=c->attempts; return d;
}
double er_continuous_seconds(void) { return 100; }
void er_install_stop_handlers(void) { abort(); }
int32_t er_stop_requested(void) { abort(); }
int32_t er_console_confirm(void) { abort(); }
int32_t er_console_poll(void) { abort(); }
'''
SWIFT_DOUBLE = r'''
import Foundation
import CExternalRoute
public struct IPv4Address { public let rawValue: UInt32; public var description: String { "synthetic" } }
public struct IPv4CIDR {
    public let networkAddress = IPv4Address(rawValue: 0xc633642c)
    public let prefixLength = 32
    public func contains(_ address: IPv4Address) -> Bool { false }
}
public struct ExternalRoute { let destination = IPv4CIDR() }
public struct ExternalObservation { let routes: [ExternalRoute] = [] }
public struct ExternalSystemSnapshotReader { public func capture() throws -> ExternalObservation { ExternalObservation() } }
public enum ExternalLeaseFailure: String, Error { case consentRequired, observationFailed }
public enum ExternalError: String, Error { case readFailed }
public struct ExternalRouteParseDiagnostic: Error { let description = "test diagnostic"; let code = ExternalError.readFailed }
public struct ExternalLeaseRoute {
    public let destination = IPv4CIDR()
    public let gateway = IPv4Address(rawValue: 0xc0000201)
    public let interface = "physical"
}
public enum ExternalAddResult { case acknowledged(UInt64), rejected, uncertain }
public enum ExternalRemoveResult { case acknowledged, refused, uncertain }
public protocol ExternalRouteOperating: AnyObject {
    func observe() throws -> ExternalObservation
    func drainEvents() -> Bool
    func owns(_ token: UInt64) -> Bool
    func add(_ route: ExternalLeaseRoute) -> ExternalAddResult
    func remove(_ token: UInt64) -> ExternalRemoveResult
}
// Only fixed synthetic interfaces; no lookup in the host's actual interfaces.
func if_nametoindex(_ name: UnsafePointer<CChar>) -> UInt32 { String(cString:name) == "physical" ? 2 : 9 }
func getuid() -> UInt32 { 501 }
func geteuid() -> UInt32 { 501 }
func isatty(_ fd: Int32) -> Int32 { 0 }
let STDIN_FILENO: Int32 = 0, STDOUT_FILENO: Int32 = 1
struct Physical { let interface = "physical" }
struct Topology { let physical = Physical(); let tunnelInterface = "tunnel" }
enum Disposition: String { case wouldAdd }
struct Proposal { let destination = IPv4CIDR(); let gateway = IPv4Address(rawValue:0xc0000201); let interface = "physical"; let disposition = Disposition.wouldAdd }
struct Preview { let topology = Topology(); let proposals = [Proposal()] }
struct ExternalLeasePlan {
    let preview = Preview(); let additions: [ExternalLeaseRoute]
    static func prepare(rules: String, observation: ExternalObservation, uptime: TimeInterval, clock: TimeInterval) throws -> Self {
        .init(additions: rules == "empty" ? [] : [ExternalLeaseRoute()])
    }
}
// Any journal access or transaction construction from probe aborts the test.
struct ExternalLeaseFileJournal {
    static func foregroundHost() throws -> Self { fatalError("probe touched journal") }
    func auditCandidates() throws -> [ExternalLeaseRoute] { fatalError("audit not requested") }
    func clearAuditedAbsence(routes: [ExternalLeaseRoute], observation: ExternalObservation, uptime: TimeInterval) throws { fatalError("clear not requested") }
}
enum State: String { case active, closed }
enum PostObservation: String { case unchanged }
final class ExternalLeaseTransaction {
    let state = State.closed; let ownedCount = 0; let postObservation = PostObservation.unchanged
    let failure: ExternalLeaseFailure? = nil
    let snapshotChangeSummary: String? = nil
    let observationErrorCode: String? = nil
    init(plan:ExternalLeasePlan, driver:NativeExternalRouteDriver, journal:ExternalLeaseFileJournal,
         now:()->TimeInterval, cancelled:()->Bool) { fatalError("probe created transaction") }
    func start(consent:Bool) { fatalError("probe tried start") }
    func poll() { fatalError("probe tried poll") }
    func stop() { fatalError("probe tried stop") }
}
'''
SWIFT_MAIN = r'''
    static func usage() { fatalError("unexpected usage") }
    static func main() {
        let mode = CommandLine.arguments[1]
        switch mode {
        case "probe-pass", "probe-fail", "probe-empty":
            test_status(mode == "probe-fail" ? 2 : 0)
            let code = run(["probe", mode == "probe-empty" ? "empty" : "synthetic"])
            precondition(code == (mode == "probe-fail" ? 2 : 0))
            precondition(test_gets() == (mode == "probe-empty" ? 0 : mode == "probe-fail" ? 1 : 2))
            precondition(test_adds() == 0 && test_removes() == 0)
        case "bridge-results":
            for value: Int32 in [0, 1, 2, 3, 99] {
                test_status(value)
                let driver = try! NativeExternalRouteDriver(tunnel: "tunnel")
                switch driver.add(ExternalLeaseRoute()) {
                case .acknowledged(let token): precondition(value == 0 && token == 1)
                case .rejected: precondition(value == 1 || value == 3)
                case .uncertain: precondition(value == 2 || value == 99)
                }
                precondition(driver.diagnosticSummary.contains("mutation_attempts=\(value == 3 ? 0 : 1)"))
            }
        default: fatalError("unexpected test mode")
        }
        print("native-probe-harness=PASS model_bridge_cli=ACTUAL c_topology_journal=TEST_DOUBLES network=NOT_READ")
    }
}
'''


def actual_driver() -> str:
    text = (SOURCES / 'ExternalExecution/NativeRouteDriver.swift').read_text()
    for marker in ['#if os(macOS)\n', '#endif\n', 'import Darwin\n', 'import ExternalCore\n']:
        if text.count(marker) != 1:
            raise AssertionError('driver boundary changed; review test extraction')
        text = text.replace(marker, '')
    return text


def actual_cli_run() -> str:
    text = (SOURCES / 'ExternalLease/ExternalLeaseMain.swift').read_text()
    start = '    private static func run(_ arguments: [String]) -> Int32 {'
    end = '\n    #endif\n    private static func usage()'
    if text.count(start) != 1 or text.count(end) != 1:
        raise AssertionError('CLI boundary changed; review test extraction')
    return text[text.index(start):text.index(end)]


class NativeProbeTests(unittest.TestCase):
    def compile_and_run(self, optimization):
        with tempfile.TemporaryDirectory(prefix='external-native-probe-') as directory:
            work = Path(directory)
            include = SOURCES / 'CExternalRoute/include'
            shutil.copyfile(include / 'external_route.h', work / 'external_route.h')
            (work / 'test_bridge.h').write_text('''#include "external_route.h"
void test_status(int32_t);
int32_t test_gets(void);
int32_t test_adds(void);
int32_t test_removes(void);
''')
            (work / 'module.modulemap').write_text('module CExternalRoute { header "test_bridge.h" export * }\n')
            (work / 'double.c').write_text(C_DOUBLE)
            result = subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-c', str(work / 'double.c'), '-o', str(work / 'double.o')], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            (work / 'harness.swift').write_text(SWIFT_DOUBLE + actual_driver() + '\n@main struct Harness {\n' + actual_cli_run() + SWIFT_MAIN)
            result = subprocess.run(['swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors', optimization,
                '-parse-as-library', '-I', str(work), str(work / 'harness.swift'), str(work / 'double.o'), '-o', str(work / 'harness')], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for mode in ['probe-pass', 'probe-fail', 'probe-empty', 'bridge-results']:
                with self.subTest(mode=mode, optimization=optimization):
                    result = subprocess.run([str(work / 'harness'), mode], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn('native-probe-harness=PASS', result.stdout)
                    if mode.startswith('probe-'):
                        self.assertIn('network_settings=NOT_APPLIED', result.stdout)
                    if mode == 'probe-fail':
                        self.assertIn('stage=targetGET reason=decode', result.stdout)
                        self.assertIn('mutation_attempts=0', result.stdout)
                        self.assertNotIn('native_route_probe=PASS', result.stdout)

    def test_actual_native_swift_bridge_and_cli_debug(self):
        self.compile_and_run('-Onone')

    def test_actual_native_swift_bridge_and_cli_optimized(self):
        self.compile_and_run('-O')

    def test_mac_source_syntax_and_no_test_fixture_in_product(self):
        sources = [SOURCES / 'ExternalExecution/NativeRouteDriver.swift', SOURCES / 'ExternalLease/ExternalLeaseMain.swift']
        result = subprocess.run(['swiftc', '-frontend', '-parse', '-target', 'arm64-apple-macos26.0', *map(str,sources)], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for path in list((SOURCES / 'CExternalRoute').rglob('*')) + sources:
            if path.is_file():
                self.assertNotIn('test_bridge.h', path.read_text())
                self.assertNotIn('darwin_fixture.h', path.read_text())
        ast.parse(Path(__file__).read_text(), feature_version=(3, 9))

if __name__ == '__main__': unittest.main()
