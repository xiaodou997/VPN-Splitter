# SPDX-License-Identifier: MIT
"""Actual Helper UI model + actual native client. All UI, disk, XPC, signing and
system service providers are explicit doubles; no real dialogs or network IO.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_client import ROOT, SOURCE, FAKES
MODELS = r'''
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<T> { var wrappedValue: T }
@MainActor final class NSAlert {
    enum Response { case alertFirstButtonReturn, alertSecondButtonReturn, alertThirdButtonReturn }
    var messageText = "", informativeText = ""
    func addButton(withTitle: String) {}
    func runModal() -> Response { .alertFirstButtonReturn }
}
enum ExternalProfileError: String, Error { case staleRevision }
struct SavedProfile: Equatable, Sendable { var id = UUID(); var enabledRulesText = "198.51.100.7/32" }
struct Workspace: Equatable, Sendable { var selected: SavedProfile? = SavedProfile(); var revision: UUID? = UUID() }
struct Editor { var mustReload = false; var workspace: Workspace }
@MainActor final class ExternalProfilesModel {
    var busy = false, hasUnsavedChanges = false
    var changeID = UUID()
    var editor = Editor(workspace: Disk.shared.read())
}
final class Disk: @unchecked Sendable {
    static let shared = Disk()
    let lock = NSLock()
    private var value = Workspace()
    func read() -> Workspace { lock.lock(); defer { lock.unlock() }; return value }
    func change() { lock.lock(); value.revision = UUID(); lock.unlock() }
}
actor ExternalProfileStore {
    static func applicationStore() throws -> ExternalProfileStore { ExternalProfileStore() }
    func load() async throws -> Workspace { Disk.shared.read() }
}
'''
HARNESS = r'''
@main @MainActor struct PanelHarness {
    static func check(_ ok: Bool) { precondition(ok, "panel contract failed") }
    static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<2000 { if predicate() { return }; try await Task.sleep(for: .milliseconds(1)) }
        fatalError("panel condition timeout")
    }
    static func main() async throws {
        let fixture = MockState.shared
        let profiles = ExternalProfilesModel()
        let helper = ExternalHelperModel()
        check(fixture.opened == 0 && fixture.sent == 0)
        let scenario = CommandLine.arguments[1]
        if scenario == "dirty" {
            profiles.hasUnsavedChanges = true
            helper.prepare(profiles); try await wait { !helper.busy }
            check(fixture.opened == 0 && helper.message.contains("staleSelection"))
        } else {
            helper.prepare(profiles); try await wait { !helper.busy }
            check(helper.response?.result.state == .prepared && fixture.sent == 2 && !helper.canApply)
            helper.confirmed = true; check(helper.canApply)
            switch scenario {
            case "apply-stop":
                helper.apply(profiles); try await wait { !helper.busy }
                check(helper.response?.result.state == .active && helper.cleanupUnconfirmed)
                helper.stop(); try await wait { !helper.busy }
                check(helper.response?.result.state == .closed && !helper.cleanupUnconfirmed)
            case "disk-changed":
                Disk.shared.change(); helper.apply(profiles); try await wait { !helper.busy }
                check(fixture.sent == 2 && helper.message.contains("staleSelection") && !helper.cleanupUnconfirmed)
            case "cancel-pending":
                fixture.mode = 2; helper.apply(profiles)
                try await wait { fixture.getSent() == 3 }
                helper.stop(); try await wait { !helper.busy }
                check(helper.cleanupUnconfirmed && helper.response == nil && !helper.canApply)
            case "edit-invalidates":
                helper.invalidate(); helper.apply(profiles)
                check(fixture.sent == 2 && helper.response == nil && !helper.canApply)
            case "recovery":
                fixture.mode = 5; helper.apply(profiles); try await wait { !helper.busy }
                check(helper.response?.result.state == .recoveryRequired && helper.cleanupUnconfirmed)
                helper.prepare(profiles); check(fixture.sent == 3)
            default: fatalError("unknown fixture")
            }
        }
        helper.invalidate()
        print("helper-panel=PASS model_client=ACTUAL platform_disk_transport=TEST_DOUBLES network=NOT_READ")
    }
}
'''
class HelperPanelTests(unittest.TestCase):
    def run_mode(self, optimization):
        panel = (ROOT / 'Packages/ExternalCore/Sources/ExternalPreview/ExternalHelperPanel.swift').read_text()
        self.assertEqual(panel.count('struct ExternalHelperPanel: View'), 1)
        self.assertIn('struct ExternalHelperSessionPanel: View', panel)
        self.assertIn('struct ExternalRecoveryPanel: View', panel)
        self.assertIn('struct ExternalHelperSettingsPanel: View', panel)
        model = panel.split('struct ExternalHelperSessionPanel: View')[0]
        client = (SOURCE / 'ExternalHelperClient.swift').read_text()
        for token in ['#if os(macOS)', '#endif', 'import SwiftUI', 'import AppKit', 'import ExternalCore', 'import ExternalControl', 'import ServiceManagement', 'import Darwin']:
            model = model.replace(token, ''); client = client.replace(token, '')
        fake = FAKES.replace('if request.action == .prepare', 'if request.action == .apply { state.active = true; result = .init(mode == 5 ? .recoveryRequired : .active) }\n        if request.action == .prepare', 1)
        source = (SOURCE / 'ExternalControlWire.swift').read_text() + (SOURCE / 'ExternalControlIdentity.swift').read_text().split('#if os(macOS)')[0]
        with tempfile.TemporaryDirectory(prefix='external-helper-panel-') as directory:
            root = Path(directory); file = root / 'Harness.swift'; binary = root / 'test-panel'
            file.write_text(source + fake + MODELS + client + model + HARNESS)
            compiled = subprocess.run(['swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
                optimization, '-parse-as-library', str(file), '-o', str(binary)], capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            for scenario in ['dirty', 'apply-stop', 'disk-changed', 'cancel-pending', 'edit-invalidates', 'recovery']:
                with self.subTest(scenario=scenario):
                    run = subprocess.run([str(binary), scenario], capture_output=True, text=True, timeout=10)
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                    self.assertIn('helper-panel=PASS', run.stdout)
    def test_actual_panel_debug(self): self.run_mode('-Onone')
    def test_actual_panel_optimized(self): self.run_mode('-O')
if __name__ == '__main__': unittest.main()
