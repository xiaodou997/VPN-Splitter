# SPDX-License-Identifier: MIT
"""Compile the real profile/store/editor and actual app model; modal dialogs are doubles.
No native network collection, Helper, real user files, GUI window or route writes.
The isolated module intentionally includes only the new document sources plus real IPv4.
"""
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / 'Packages/ExternalCore/Sources/ExternalCore'
UI = ROOT / 'Packages/ExternalCore/Sources/ExternalPreview'
IPV4 = ROOT / 'Packages/PolicyCore/Sources/PolicyCore/IPv4.swift'

PREAMBLE = r'''
import Foundation
import ExternalCore
#if os(macOS)
import SwiftUI
#else
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
#endif
// Deliberate dialog substitute on every OS: never show NSAlert from offline tests.
@MainActor final class NSAlert {
    enum Reply { case alertFirstButtonReturn, alertSecondButtonReturn }
    static var reply: Reply = .alertFirstButtonReturn
    static var shown = 0
    var messageText = ""
    var informativeText = ""
    func addButton(withTitle: String) {}
    func runModal() -> Reply { Self.shown += 1; return Self.reply }
}
'''

HARNESS = r'''
@main @MainActor struct ProfileAppHarness {
    static func require(_ value: Bool, _ message: String) {
        if !value { fatalError(message) }
    }
    static func settled(_ model: ExternalProfilesModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.busy {
            require(ContinuousClock.now < deadline, "local transaction timed out")
            try await Task.sleep(for:.milliseconds(2))
        }
    }
    static func saved(_ model: ExternalProfilesModel, name: String) async throws {
        model.newProfile(); model.editName(name); model.batchText = "192.0.2.7\n198.51.100.9"
        model.addBatch(); model.save(); try await settled(model)
        require(!model.hasUnsavedChanges && model.editor.workspace.selected != nil, "save did not complete")
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("profile-app-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = ExternalProfileStore(directory:root.appendingPathComponent("store"))
        let model = ExternalProfilesModel(store:store)
        require(model.busy, "initial local load not started")
        require(!model.confirmDiscard(), "quit allowed during file transaction")
        try await settled(model)
        require(model.editor.loaded && model.editor.workspace.profiles.isEmpty, "initial load failed")
        switch CommandLine.arguments[1] {
        case "roundtrip":
            try await saved(model,name:"roundtrip")
            let id = model.editor.draft!.rules[0].id
            model.editRule(id,enabled:false); model.moveRule(id,by:1); model.save(); try await settled(model)
            let reopened = ExternalProfilesModel(store:store); try await settled(reopened)
            require(reopened.editor.draft == model.editor.draft,"reopen did not preserve selection/order/toggle")
            require(reopened.enabledRules == "198.51.100.9/32","disabled item entered preview")
        case "discard-and-pending-input":
            try await saved(model,name:"original")
            model.editName("keep unsaved"); model.reload()
            require(model.editor.draft?.name == "keep unsaved" && model.hasUnsavedChanges,"cancel discarded edits")
            model.batchText = "203.0.113.7"; model.save()
            require(model.hasUnsavedChanges && model.batchText == "203.0.113.7", "save dropped pending input")
            NSAlert.reply = .alertSecondButtonReturn; model.reload(); try await settled(model)
            require(model.editor.draft?.name == "original" && !model.hasUnsavedChanges,"explicit discard/reload failed")
        case "stale-save":
            try await saved(model,name:"initial")
            let other = ExternalProfilesModel(store:store); try await settled(other)
            other.editName("other change")
            model.editName("new disk value"); model.save(); try await settled(model)
            other.save(); try await settled(other)
            require(other.editor.mustReload && !other.canSave,"stale save accepted automatically")
            require(other.editor.draft?.name == "other change" && other.hasUnsavedChanges,"stale save lost draft")
            let disk = try await store.load(); require(disk.selected?.name == "new disk value","new disk data overwritten")
        case "delete-and-selection":
            try await saved(model,name:"first"); let first = model.editor.draft!.id
            try await saved(model,name:"second")
            model.deleteSelected(); require(model.editor.workspace.profiles.count == 2,"cancelled delete proceeded")
            NSAlert.reply = .alertSecondButtonReturn; model.deleteSelected(); try await settled(model)
            require(model.editor.workspace.profiles.count == 1 && model.editor.draft == nil,"delete auto-selected another profile")
            model.select(first); try await settled(model)
            require(model.editor.draft?.id == first,"selection not persisted")
            model.duplicate(); require(model.hasUnsavedChanges && model.editor.draft?.id != first,"duplicate reuses saved identity")
        case "invalid-batch-and-rule":
            model.newProfile(); model.editName("draft")
            model.batchText = "192.0.2.7\ninvalid"; model.addBatch()
            require(model.editor.draft!.rules.isEmpty,"invalid batch partially committed")
            model.batchText = "192.0.2.7"; model.addBatch()
            let id = model.editor.draft!.rules[0].id
            model.editRule(id,text:"invalid",enabled:false); model.save()
            require(model.hasUnsavedChanges && model.editor.workspace.profiles.isEmpty,"invalid disabled rule saved")
            require(model.enabledRules.isEmpty,"invalid rules presented for preview")
        default: fatalError("unknown scenario")
        }
        print("external-profiles-app=PASS documents_model_store=ACTUAL dialogs=TEST_DOUBLES network=NOT_READ")
    }
}
'''


def actual_model() -> str:
    text = (UI / 'ExternalProfilesModel.swift').read_text()
    start = '@MainActor\nfinal class ExternalProfilesModel:'
    end = '\n/// Covers Dock/menu/keyboard quit;'
    if text.count(start) != 1 or text.count(end) != 1:
        raise AssertionError('model boundary changed')
    return text[text.index(start):text.index(end)]


class ProfileAppTests(unittest.TestCase):
    def test_ui_bindings_and_separate_storage_boundary(self):
        model = (UI / 'ExternalProfilesModel.swift').read_text()
        panel = (UI / 'ExternalProfilesPanel.swift').read_text()
        app = (UI / 'ExternalPreviewApp.swift').read_text()
        navigation = (UI / 'ExternalNavigationView.swift').read_text()
        for token in ['profiles.select(', 'profiles.save()', 'profiles.addBatch()', 'profiles.moveRule(', 'profiles.deleteSelected()']:
            self.assertIn(token,panel)
        combined = app + navigation
        for token in ['ExternalProfilesPanel(profiles: profiles)', 'model.cancel(); helper.invalidate(); model.rules = profiles.enabledRules',
                      'profiles.hasUnsavedChanges', 'ExternalTerminationDelegate.shouldTerminate']:
            self.assertIn(token,combined)
        self.assertIn('CommandMenu("规则")', app)
        self.assertIn('case .rules:', navigation)
        for token in ['ExternalSystemSnapshotReader', 'NativeExternalRouteDriver', 'sudo', 'NSXPCConnection', 'UserDefaults', 'SecItem']:
            self.assertNotIn(token,model)
        self.assertIn('expectedRevision: before.workspace.revision',model)
        self.assertIn('editor.failed(failure)',model)
        parsed = subprocess.run(['swiftc','-frontend','-parse','-target','arm64-apple-macos26.0',str(UI/'ExternalProfilesModel.swift'),str(UI/'ExternalProfilesPanel.swift'),str(UI/'ExternalNavigationView.swift'),str(UI/'ExternalPreviewApp.swift')],capture_output=True,text=True,timeout=30)
        self.assertEqual(parsed.returncode,0,parsed.stdout+parsed.stderr)

    def compile_run(self, optimization):
        with tempfile.TemporaryDirectory(prefix='profiles-compile-') as temp:
            p = Path(temp)
            native = ['-target',platform.machine()+'-apple-macos26.0'] if sys.platform == 'darwin' else []
            common = ['swiftc','-swift-version','6','-strict-concurrency=complete','-warnings-as-errors',optimization] + native
            ext = '.dylib' if sys.platform == 'darwin' else '.so'
            def run(args,timeout=60):
                result = subprocess.run(args,capture_output=True,text=True,timeout=timeout)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                return result
            run(common+['-emit-library','-emit-module','-module-name','PolicyCore',str(IPV4),'-emit-module-path',str(p/'PolicyCore.swiftmodule'),'-o',str(p/('libPolicyCore'+ext))])
            sources = [CORE/'ExternalProfiles.swift',CORE/'ExternalProfileStore.swift']
            run(common+['-emit-library','-emit-module','-module-name','ExternalCore','-I',temp,'-L',temp,'-lPolicyCore',*map(str,sources),'-emit-module-path',str(p/'ExternalCore.swiftmodule'),'-o',str(p/('libExternalCore'+ext))])
            (p/'main.swift').write_text(PREAMBLE+'\n'+actual_model()+'\n'+HARNESS)
            run(common+['-parse-as-library','-I',temp,'-L',temp,'-lExternalCore','-lPolicyCore','-Xlinker','-rpath','-Xlinker',temp,str(p/'main.swift'),'-o',str(p/'harness')])
            for scenario in ['roundtrip','discard-and-pending-input','stale-save','delete-and-selection','invalid-batch-and-rule']:
                with self.subTest(scenario=scenario):
                    result = run([str(p/'harness'),scenario],timeout=15)
                    self.assertIn('external-profiles-app=PASS',result.stdout)

    def test_actual_document_model_debug(self):
        self.compile_run('-Onone')

    def test_actual_document_model_optimized(self):
        self.compile_run('-O')


if __name__ == '__main__':
    unittest.main()
